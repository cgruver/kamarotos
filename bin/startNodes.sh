#!/bin/bash

. ${OKD_LAB_PATH}/bin/labctx.env

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
BOOTSTRAP=false
MASTER=false
WORKER=false
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
      BOOTSTRAP=true
      shift
    ;;
    -m|--master)
      MASTER=true
      shift
    ;;
    -w|--worker)
      WORKER=true
      shift
    ;;
    *)
        # put usage here:
    ;;
  esac
done

function startNode() {
  local kvm_host=${1}
  local host_name=${2}
  ${SSH} root@${kvm_host}.${DOMAIN} "virsh start ${host_name}"
}

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
    INDEX=${i}
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

SUB_DOMAIN=$(yq e ".sub-domain-configs.[${INDEX}].name" ${CONFIG_FILE})
CLUSTER_CONFIG=$(yq e ".sub-domain-configs.[${INDEX}].cluster-config-file" ${CONFIG_FILE})
CLUSTER_NAME=$(yq e ".cluster.name" ${CLUSTER_CONFIG})
DOMAIN="${SUB_DOMAIN}.${LAB_DOMAIN}"
WORK_DIR=${OKD_LAB_PATH}/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}

if [[ ${BOOTSTRAP} == "true" ]]
then
  host_name="$(yq e ".cluster.name" ${CLUSTER_CONFIG})-bootstrap"

  if [[ $(yq e ".bootstrap.metal" ${CLUSTER_CONFIG}) == "true" ]]
  then
    memory=$(yq e ".bootstrap.node-spec.memory" ${CLUSTER_CONFIG})
    cpu=$(yq e ".bootstrap.node-spec.cpu" ${CLUSTER_CONFIG})
    root_vol=$(yq e ".bootstrap.node-spec.root_vol" ${CLUSTER_CONFIG})
    bridge_dev=$(yq e ".bootstrap.bridge-dev" ${CLUSTER_CONFIG})

    mkdir -p ${WORK_DIR}/bootstrap
    qemu-img create -f qcow2 ${WORK_DIR}/bootstrap/bootstrap-node.qcow2 ${root_vol}G
    qemu-system-x86_64 -accel accel=hvf -m ${memory}M -smp ${cpu} -display none -nographic -drive file=${WORK_DIR}/bootstrap/bootstrap-node.qcow2,if=none,id=disk1  -device ide-hd,bus=ide.0,drive=disk1,id=sata0-0-0,bootindex=1 -boot n -netdev vde,id=nic0,sock=/var/run/vde.bridged.${bridge_dev}.ctl -device virtio-net-pci,netdev=nic0,mac=52:54:00:a1:b2:c3
  else
    kvm_host=$(yq e ".bootstrap.kvm-host" ${CLUSTER_CONFIG})
    startNode ${kvm_host} ${host_name}
  fi
fi

if [[ ${MASTER} == "true" ]]
then
  if [[ $(yq e ".control-plane.metal" ${CLUSTER_CONFIG}) == "true" ]]
  then
    echo "This script will not auto start bare-metal nodes.  Please power them on manually."
  else
    for i in 0 1 2
    do
      kvm_host=$(yq e ".control-plane.okd-hosts.[${i}].kvm-host" ${CLUSTER_CONFIG})
      host_name=$(yq e ".control-plane.okd-hosts.[${i}].name" ${CLUSTER_CONFIG})
      startNode ${kvm_host} ${host_name}
      echo "Pause for 15 seconds to stagger node start up."
      sleep 15
    done
  fi
fi

if [[ ${WORKER} == "true" ]]
then
  let NODE_COUNT=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let i=0
  while [[ i -lt ${NODE_COUNT} ]]
  do
    host_name=$(yq e ".compute-nodes.[${i}].name" ${CLUSTER_CONFIG})
    if [[ $(yq e ".compute-nodes.[${i}].metal" ${CLUSTER_CONFIG}) == "true" ]]
    then
      echo "This script will not auto start a bare-metal node.  Please power on ${host_name} manually."
    else
      kvm_host=$(yq e ".compute-nodes.[${i}].kvm-host" ${CLUSTER_CONFIG})  
      startNode ${kvm_host} ${host_name}
      echo "Pause for 15 seconds to stagger node start up."
      sleep 15
    fi
    i=$(( ${i} + 1 ))
  done
fi
