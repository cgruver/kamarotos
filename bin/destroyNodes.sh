#!/bin/bash
. ${OKD_LAB_PATH}/bin/labctx.env

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
RESET_LB=false
DELETE_BOOTSTRAP=false
DELETE_CLUSTER=false
DELETE_WORKER=false
DELETE_KVM_HOST=false
W_HOST_NAME=""
W_HOST_INDEX=""
K_HOST_INDEX=""
M_HOST_INDEX=""
let NODE_COUNT=0
SNO="false"

CONFIG_FILE=${LAB_CONFIG_FILE}

for i in "$@"
do
  case $i in
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      shift
    ;;
    -d=*|--domain=*)
      SUB_DOMAIN="${i#*=}"
      shift
    ;;
    -b|--bootstrap)
      DELETE_BOOTSTRAP=true
      shift
    ;;
    -w=*|--worker=*)
      DELETE_WORKER=true
      W_HOST_NAME="${i#*=}"
      shift
    ;;
    -r|--reset)
      RESET_LB=true
      DELETE_CLUSTER=true
      DELETE_WORKER=true
      W_HOST_NAME="all"
      shift
    ;;
    -k=*|--kvm-host=*)
      DELETE_KVM_HOST=true
      K_HOST_NAME="${i#*=}"
      shift
    ;;
    -m=*|--master=*)
      M_HOST_NAME="${i#*=}"
      shift
    ;;
    *)
      # put usage here:
    ;;
  esac
done

# Destroy the VM
function deleteNodeVm() {
  local host_name=${1}
  local kvm_host=${2}

  ${SSH} root@${kvm_host}.${DOMAIN} "virsh destroy ${host_name}"
  ${SSH} root@${kvm_host}.${DOMAIN} "virsh undefine ${host_name}"
  ${SSH} root@${kvm_host}.${DOMAIN} "virsh pool-destroy ${host_name}"
  ${SSH} root@${kvm_host}.${DOMAIN} "virsh pool-undefine ${host_name}"
  ${SSH} root@${kvm_host}.${DOMAIN} "rm -rf /VirtualMachines/${host_name}"
}

# Destroy a physical host:
function destroyMetal() {
  local user=${1}
  local hostname=${2}
  local boot_dev=${3}
  local ceph_dev=${4}

  if [[ ${ceph_dev} != "na" ]] && [[ ${ceph_dev} != "" ]]
  then
    ${SSH} -o ConnectTimeout=5 ${user}@${hostname}.${DOMAIN} "sudo wipefs -a -f /dev/${ceph_dev} && sudo dd if=/dev/zero of=/dev/${ceph_dev} bs=4096 count=1"
  fi
  ${SSH} -o ConnectTimeout=5 ${user}@${hostname}.${DOMAIN} "sudo wipefs -a -f /dev/${boot_dev} && sudo dd if=/dev/zero of=/dev/${boot_dev} bs=4096 count=1 && sudo poweroff"
}

# Remove the iPXE boot files
function deletePxeConfig() {
  local mac_addr=${1}
  
  ${SSH} root@${ROUTER} "rm -f /data/tftpboot/ipxe/${mac_addr//:/-}.ipxe"
  ${SSH} root@${BASTION_HOST} "rm -f /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}/${mac_addr//:/-}.ign"
}

# Remove DNS Records
function deleteDns() {
  local key=${1}
  ${SSH} root@${ROUTER} "cat /etc/bind/db.${DOMAIN} | grep -v ${key} > /tmp/db.${DOMAIN} && cp /tmp/db.${DOMAIN} /etc/bind/db.${DOMAIN}"
  ${SSH} root@${ROUTER} "cat /etc/bind/db.${NET_PREFIX_ARPA} | grep -v ${key} > /tmp/db.${NET_PREFIX_ARPA} && cp /tmp/db.${NET_PREFIX_ARPA} /etc/bind/db.${NET_PREFIX_ARPA}"
}

# Validate options and set vars
function validateAndSetVars() {
  if [[ -z ${SUB_DOMAIN} ]]
  then
    labctx
  fi
  DONE=false
  DOMAIN_COUNT=$(yq e ".sub-domain-configs" ${CONFIG_FILE} | yq e 'length' -)
  let i=0
  while [[ i -lt ${DOMAIN_COUNT} ]]
  do
    domain_name=$(yq e ".sub-domain-configs.[${i}].name" ${CONFIG_FILE})
    if [[ ${domain_name} == ${SUB_DOMAIN} ]]
    then
      D_INDEX=${i}
      DONE=true
      break
    fi
    i=$(( ${i} + 1 ))
  done
  if [[ ${DONE} == "false" ]]
  then
    echo "Domain Entry Not Found In Config File."
    exit 1
  fi

  EDGE_ROUTER=$(yq e ".router" ${CONFIG_FILE})
  LAB_DOMAIN=$(yq e ".domain" ${CONFIG_FILE})
  BASTION_HOST=$(yq e ".bastion-ip" ${CONFIG_FILE})
  SUB_DOMAIN=$(yq e ".sub-domain-configs.[${D_INDEX}].name" ${CONFIG_FILE})
  ROUTER=$(yq e ".sub-domain-configs.[${D_INDEX}].router-ip" ${CONFIG_FILE})
  NETWORK=$(yq e ".sub-domain-configs.[${D_INDEX}].network" ${CONFIG_FILE})
  CLUSTER_CONFIG=$(yq e ".sub-domain-configs.[${D_INDEX}].cluster-config-file" ${CONFIG_FILE})
  DOMAIN="${SUB_DOMAIN}.${LAB_DOMAIN}"
  CLUSTER_NAME=$(yq e ".cluster.name" ${CLUSTER_CONFIG})
  WORK_DIR=${OKD_LAB_PATH}/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}

  CP_COUNT=$(yq e ".control-plane.okd-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
  if [[ ${CP_COUNT} == "1" ]]
  then
    SNO="true"
    RESET_LB="false"
  fi

  if [[ ${DELETE_WORKER} == "true" ]] && [[ ${W_HOST_NAME} != "all" ]]
  then
    if [[ ${W_HOST_NAME} == "" ]]
    then
      echo "-w | --worker must have a value"
      exit 1
    fi
    let i=0
    DONE=false
    let NODE_COUNT=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
    while [[ i -lt ${NODE_COUNT} ]]
    do
      host_name=$(yq e ".compute-nodes.[${i}].name" ${CLUSTER_CONFIG})
      if [[ ${host_name} == ${W_HOST_NAME} ]]
      then
        W_HOST_INDEX=${i}
        DONE=true
        break;
      fi
      i=$(( ${i} + 1 ))
    done
    if [[ ${W_HOST_INDEX} == "" ]]
    then
      echo "Host: ${W_HOST_NAME} not found in config file."
      exit 1
    fi
  fi

  if [[ ${DELETE_KVM_HOST} == "true" ]] && [[ ${K_HOST_NAME} != "all" ]]
  then
    if [[ ${K_HOST_NAME} == "" ]]
    then
      echo "-w | --worker must have a value"
      exit 1
    fi
    let i=0
    DONE=false
    let NODE_COUNT=$(yq e ".kvm-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
    while [[ i -lt ${NODE_COUNT} ]]
    do
      host_name=$(yq e ".kvm-hosts.[${i}].host-name" ${CLUSTER_CONFIG})
      if [[ ${host_name} == ${K_HOST_NAME} ]]
      then
        K_HOST_INDEX=${i}
        DONE=true
        break;
      fi
      i=$(( ${i} + 1 ))
    done
    if [[ ${K_HOST_INDEX} == "" ]]
    then
      echo "Host: ${K_HOST_NAME} not found in config file."
      exit 1
    fi
  fi
}

function deleteBootstrap() {
  #Delete Bootstrap
  if [[ $(yq e ".bootstrap.metal" ${CLUSTER_CONFIG}) == "true" ]]
  then
    kill $(ps -ef | grep qemu | grep bootstrap | awk '{print $2}')
    rm -rf ${WORK_DIR}/bootstrap
  else
    host_name="${CLUSTER_NAME}-bootstrap"
    kvm_host=$(yq e ".bootstrap.kvm-host" ${CLUSTER_CONFIG})
    deleteNodeVm ${host_name} ${kvm_host}
  fi
  deletePxeConfig $(yq e ".bootstrap.mac-addr" ${CLUSTER_CONFIG})
  deleteDns ${CLUSTER_NAME}-${DOMAIN}-bs
  if [[ ${SNO} == "false" ]]
  then
    ${SSH} root@${ROUTER} "cat /etc/haproxy-${CLUSTER_NAME}.cfg | grep -v bootstrap > /etc/haproxy-${CLUSTER_NAME}.no-bootstrap && \
    mv /etc/haproxy-${CLUSTER_NAME}.no-bootstrap /etc/haproxy-${CLUSTER_NAME}.cfg && \
    /etc/init.d/haproxy-${CLUSTER_NAME} stop ; \
    /etc/init.d/haproxy-${CLUSTER_NAME} start"
  fi
}

function deleteWorker() {
  local index=${1}

  host_name=$(yq e ".compute-nodes.[${index}].name" ${CLUSTER_CONFIG})
  mac_addr=$(yq e ".control-plane.okd-hosts.[${index}].mac-addr" ${CLUSTER_CONFIG})
  if [[ $(yq e ".compute-nodes.[${index}].metal" ${CLUSTER_CONFIG})  == "true" ]]
  then
    boot_dev=$(yq e ".compute-nodes.[${index}].boot-dev" ${CLUSTER_CONFIG})
    ceph_dev=$(yq e ".compute-nodes.[${index}].ceph.ceph-dev" ${CLUSTER_CONFIG})
    destroyMetal core ${host_name} ${boot_dev} ${ceph_dev}
  else
    kvm_host=$(yq e ".compute-nodes.[${index}].kvm-host" ${CLUSTER_CONFIG})
    deleteNodeVm ${host_name} ${kvm_host}
  fi
  deleteDns ${host_name}-${DOMAIN}
  deletePxeConfig ${mac_addr}
}

function deleteKvmHost() {
  local index=${1}

  mac_addr=$(yq e ".kvm-hosts.[${index}].mac-addr" ${CLUSTER_CONFIG})
  host_name=$(yq e ".kvm-hosts.[${index}].host-name" ${CLUSTER_CONFIG})
  boot_dev=$(yq e ".kvm-hosts.[${index}].disks.disk1" ${CLUSTER_CONFIG})
  destroyMetal root ${host_name} ${boot_dev} na
  deletePxeConfig ${mac_addr}
  deleteDns ${host_name}-${DOMAIN}-kvm
}

function deleteCluster() {
  #Delete Control Plane Nodes:
  metal=$(yq e ".control-plane.metal" ${CLUSTER_CONFIG})
  if [[ ${SNO} == "true" ]]
  then
    mac_addr=$(yq e ".control-plane.okd-hosts.[${i}].mac-addr" ${CLUSTER_CONFIG})
    host_name=$(yq e ".control-plane.okd-hosts.[0].name" ${CLUSTER_CONFIG})
    if [[ ${metal} == "true" ]]
    then
      install_dev=$(yq e ".control-plane.okd-hosts.[0].sno-install-dev" ${CLUSTER_CONFIG})
      destroyMetal core ${host_name} ${install_dev}
    else
      kvm_host=$(yq e ".control-plane.okd-hosts.[0].kvm-host" ${CLUSTER_CONFIG})
      deleteNodeVm ${host_name} ${kvm_host}
    fi
    deletePxeConfig ${mac_addr}
  else
    for i in 0 1 2
    do
      mac_addr=$(yq e ".control-plane.okd-hosts.[${i}].mac-addr" ${CLUSTER_CONFIG})
      host_name=$(yq e ".control-plane.okd-hosts.[${i}].name" ${CLUSTER_CONFIG})
      if [[ ${metal} == "true" ]]
      then
        boot_dev=$(yq e ".control-plane.okd-hosts.[${i}].boot-dev" ${CLUSTER_CONFIG})
        destroyMetal core ${host_name} ${boot_dev}
      else
        kvm_host=$(yq e ".control-plane.okd-hosts.[${i}].kvm-host" ${CLUSTER_CONFIG})
        deleteNodeVm ${host_name} ${kvm_host}
      fi
      deletePxeConfig ${mac_addr}
    done
    fi
  deleteDns ${CLUSTER_NAME}-${DOMAIN}-cp
}

validateAndSetVars

IFS=. read -r i1 i2 i3 i4 << EOF
${NETWORK}
EOF
NET_PREFIX_ARPA=${i3}.${i2}.${i1}

if [[ ${DELETE_BOOTSTRAP} == "true" ]]
then
  deleteBootstrap
fi

if [[ ${DELETE_WORKER} == "true" ]]
then
  if [[ ${W_HOST_NAME} == "all" ]] # Delete all Nodes
  then
    let j=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
    let i=0
    while [[ i -lt ${j} ]]
    do
      deleteWorker ${i}
      i=$(( ${i} + 1 ))
    done
  else
    deleteWorker ${W_HOST_INDEX}
  fi
fi

if [[ ${DELETE_CLUSTER} == "true" ]]
then
  deleteCluster
fi

if [[ ${RESET_LB} == "true" ]]
then
  ${SSH} root@${ROUTER} "/etc/init.d/haproxy-${CLUSTER_NAME} stop ; \
    /etc/init.d/haproxy-${CLUSTER_NAME} disable ; \
    rm -f /etc/init.d/haproxy-${CLUSTER_NAME} ; \
    rm -f /etc/haproxy-${CLUSTER_NAME}.cfg ; \
    uci delete network.${CLUSTER_NAME}_lb ; \
    uci commit ; \
    /etc/init.d/network reload"
fi

if [[ ${DELETE_KVM_HOST} == "true" ]]
then
    if [[ ${K_HOST_NAME} == "all" ]] # Delete all Nodes
  then
    let j=$(yq e ".kvm-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
    let i=0
    while [[ i -lt ${j} ]]
    do
      deleteKvmHost ${i}
      i=$(( ${i} + 1 ))
    done
  else
    deleteKvmHost ${K_HOST_INDEX}
  fi
fi

${SSH} root@${ROUTER} "/etc/init.d/named stop && sleep 2 && /etc/init.d/named start && sleep 2"
${SSH} root@${EDGE_ROUTER} "/etc/init.d/named stop && sleep 2 && /etc/init.d/named start"