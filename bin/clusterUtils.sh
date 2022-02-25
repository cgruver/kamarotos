function createInstallConfig() {

  local install_dev=${1}
  PULL_SECRET_TXT=$(cat ${PULL_SECRET})

if [[ ${BIP} == "true" ]]
then
read -r -d '' SNO_BIP << EOF
BootstrapInPlace:
  InstallationDisk: "--copy-network /dev/${install_dev}"
EOF
fi

cat << EOF > ${WORK_DIR}/install-config-upi.yaml
apiVersion: v1
baseDomain: ${DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
networking:
  networkType: OVNKubernetes
  clusterNetwork:
  - cidr: ${CLUSTER_CIDR}
    hostPrefix: 23 
  serviceNetwork: 
  - ${SERVICE_CIDR}
compute:
- name: worker
  replicas: 0
controlPlane:
  name: master
  replicas: ${CP_REPLICAS}
platform:
  none: {}
pullSecret: '${PULL_SECRET_TXT}'
sshKey: ${SSH_KEY}
additionalTrustBundle: |
${NEXUS_CERT}
imageContentSources:
- mirrors:
  - ${PROXY_REGISTRY}/okd
  source: quay.io/openshift/okd
- mirrors:
  - ${PROXY_REGISTRY}/okd
  source: quay.io/openshift/okd-content
${SNO_BIP}
EOF
}

function startWorker() {
  let node_count=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    host_name=$(yq e ".compute-nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    if [[ $(yq e ".compute-nodes.[${node_index}].metal" ${CLUSTER_CONFIG}) == "true" ]]
    then
      echo "This script will not auto start a bare-metal node.  Please power on ${host_name} manually."
    else
      kvm_host=$(yq e ".compute-nodes.[${node_index}].kvm-host" ${CLUSTER_CONFIG})  
      startNode ${kvm_host} ${host_name}
      echo "Pause for 15 seconds to stagger node start up."
      sleep 15
    fi
    node_index=$(( ${node_index} + 1 ))
  done
}

function stopWorkers() {
  setKubeConfig
  let node_count=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)

  # Cordon Compute Nodes
  cordonNode

  # Drain & Shutdown Compute Nodes
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    host_name=$(yq e ".compute-nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    oc adm drain ${host_name}.${DOMAIN} --ignore-daemonsets --force --grace-period=20 --delete-emptydir-data
    ${SSH} -o ConnectTimeout=5 core@${host_name}.${DOMAIN} "sudo systemctl poweroff"
    node_index=$(( ${node_index} + 1 ))
  done
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

function cordonNode() {
  setKubeConfig
  let node_count=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    host_name=$(yq e ".compute-nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    oc adm cordon ${host_name}.${DOMAIN}
    node_index=$(( ${node_index} + 1 ))
  done
}

function unCordonNode() {
  setKubeConfig
  let node_count=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    host_name=$(yq e ".compute-nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    oc adm uncordon ${host_name}.${DOMAIN}
    node_index=$(( ${node_index} + 1 ))
  done
}

function stopCluster() {
  PAUSE=60
  node_count=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  if [[ ${node_count} -gt 0 ]]
  then
    stopWorkers
    let pause=${PAUSE}
    while [ ${pause} -gt 0 ]; do
    echo -ne "Giving Compute Nodes Time to Shutdown: ${pause}\033[0K\r"
    sleep 1
    : $((pause--))
    done
  fi
  stopControlPlane
}

function addUser() {
  setKubeConfig
  for i in "$@"
  do
    case $i in
      -a|--admin)
        ADMIN_USER="true"
      ;;
      -i|--init)
        OAUTH_INIT="true"
      ;;
      -u=*)
        USER="${i#*=}"
      ;;
      *)
        # catch all
      ;;
    esac
  done
  PASSWD_FILE=${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}/htpasswd
  if [[ ! -d ${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN} ]]
  then
    mkdir -p ${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}
  fi
  if [[ ! -f  ${PASSWD_FILE} ]]
  then
    touch ${PASSWD_FILE}
  fi
  if [[ -z ${USER} ]]
  then
    echo "Usage: cluster.sh --add-user [ -a | --admin ] -u=user-name-to-add"
    exit 1
  fi
  htpasswd -B ${PASSWD_FILE} ${USER}
  oc create -n openshift-config secret generic okd-htpasswd-secret --from-file=htpasswd=${PASSWD_FILE} -o yaml --dry-run='client' | oc apply -f -
  if [[ ${ADMIN_USER} == "true" ]]
  then
    oc adm policy add-cluster-role-to-user cluster-admin ${USER}
  fi
  if [[ ${OAUTH_INIT} == "true" ]]
  then
    oc patch oauth cluster --type merge --patch '{"spec":{"identityProviders":[{"name":"okd_htpasswd_idp","mappingMethod":"claim","type":"HTPasswd","htpasswd":{"fileData":{"name":"okd-htpasswd-secret"}}}]}}'
  fi
}

function setKubeConfig() {
  export KUBECONFIG=${KUBE_INIT_CONFIG}
}

function approveCsr() {
    oc --kubeconfig=${KUBE_INIT_CONFIG} get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs oc adm certificate approve
}

function pullSecret() {
  NEXUS_PWD="true"
  NEXUS_PWD_CHK="false"

  echo "Enter the Nexus user for the pull secret:"
  read NEXUS_USER
  while [[ ${NEXUS_PWD} != ${NEXUS_PWD_CHK} ]]
  do
    echo "Enter the password for the pull secret:"
    read -s NEXUS_PWD
    echo "Re-Enter the password for the pull secret:"
    read -s NEXUS_PWD_CHK
  done
  NEXUS_SECRET=$(echo -n "${NEXUS_USER}:${NEXUS_PWD}" | base64) 
  echo -n "{\"auths\": {\"fake\": {\"auth\": \"Zm9vOmJhcgo=\"},\"nexus.${LAB_DOMAIN}:5001\": {\"auth\": \"${NEXUS_SECRET}\"}}}" > ${PULL_SECRET}
  NEXUS_PWD=""
  NEXUS_PWD_CHK=""
}

function gitSecret() {

  for i in "$@"
  do
    case $i in
      -n=*)
        NAMESPACE="${i#*=}"
      ;;
      *)
        # catch all
      ;;
    esac
  done

  GIT_PWD="true"
  GIT_PWD_CHK="false"

  echo "Enter the Git Server user ID:"
  read GIT_USER
  while [[ ${GIT_PWD} != ${GIT_PWD_CHK} ]]
  do
    echo "Enter the password for the pull secret:"
    read -s GIT_PWD
    echo "Re-Enter the password for the pull secret:"
    read -s GIT_PWD_CHK
  done

cat << EOF | oc apply -n ${NAMESPACE} -f -
apiVersion: v1
kind: Secret
metadata:
    name: git-secret
    annotations:
      tekton.dev/git-0: ${GIT_SERVER}
type: kubernetes.io/basic-auth
data:
  username: $(echo -n ${GIT_USER} | base64)
  password: $(echo -n ${GIT_PWD} | base64)
EOF

  oc --kubeconfig=${KUBE_INIT_CONFIG} patch sa pipeline --type json --patch '[{"op": "add", "path": "/secrets/-", "value": {"name":"git-secret"}}]' -n ${NAMESPACE}
}

function getOkdRelease() {
  OKD_RELEASE=$(curl https://github.com/openshift/okd/releases/latest | cut -d"/" -f8 | cut -d\" -f1)
  echo ${OKD_RELEASE}
  yq e ".cluster.release = \"${OKD_RELEASE}\"" -i ${CLUSTER_CONFIG}
}

function ocLogin() {
  oc login -u admin https://api.${CLUSTER_NAME}.${SUB_DOMAIN}.${LAB_DOMAIN}:6443
}

function ocConsole() {
  SYS_ARCH=$(uname)
  if [[ ${SYS_ARCH} == "Darwin" ]]
  then
    # open -a Safari $(oc whoami --show-console)
    open -a Safari https://console-openshift-console.apps.${CLUSTER_NAME}.${SUB_DOMAIN}.${LAB_DOMAIN}
  else
    echo "Unsupported OS: This function currently supports Darwin OS only"
  fi
}

function configInfraNodes() {
  setKubeConfig
  for node_index in 0 1 2
  do
    oc label nodes ${CLUSTER_NAME}-master-${node_index}.${SUB_DOMAIN}.${LAB_DOMAIN} node-role.kubernetes.io/infra=""
  done
  oc patch scheduler cluster --patch '{"spec":{"mastersSchedulable":false}}' --type=merge
  oc patch -n openshift-ingress-operator ingresscontroller default --patch '{"spec":{"nodePlacement":{"nodeSelector":{"matchLabels":{"node-role.kubernetes.io/infra":""}},"tolerations":[{"key":"node.kubernetes.io/unschedulable","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/master","effect":"NoSchedule"}]}}}' --type=merge
  for node_index in $(oc get pods -n openshift-ingress-canary | grep -v NAME | cut -d" " -f1)
  do
    oc delete pod ${node_index} -n openshift-ingress-canary
  done

  oc patch configs.imageregistry.operator.openshift.io cluster --patch '{"spec":{"nodeSelector":{"node-role.kubernetes.io/infra":""},"tolerations":[{"key":"node.kubernetes.io/unschedulable","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/master","effect":"NoSchedule"}]}}' --type=merge

cat << EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    prometheusOperator:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Equal"
        value: ""
        effect: "NoSchedule"
    prometheusK8s:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Equal"
        value: ""
        effect: "NoSchedule"
    alertmanagerMain:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Equal"
        value: ""
        effect: "NoSchedule"
    kubeStateMetrics:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Equal"
        value: ""
        effect: "NoSchedule"
    grafana:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Equal"
        value: ""
        effect: "NoSchedule"
    telemeterClient:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Equal"
        value: ""
        effect: "NoSchedule"
    k8sPrometheusAdapter:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Equal"
        value: ""
        effect: "NoSchedule"
    openshiftStateMetrics:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Equal"
        value: ""
        effect: "NoSchedule"
    thanosQuerier:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Equal"
        value: ""
        effect: "NoSchedule"
EOF
}

function mirrorOkdRelease() {
  rm -rf ${OKD_LAB_PATH}/lab-config/work-dir
  mkdir -p ${OKD_LAB_PATH}/lab-config/work-dir
  mkdir -p ${OKD_LAB_PATH}/lab-config/release-sigs
  oc adm -a ${PULL_SECRET} release mirror --from=${OKD_REGISTRY}:${OKD_RELEASE} --to=${LOCAL_REGISTRY}/okd --to-release-image=${LOCAL_REGISTRY}/okd:${OKD_RELEASE} --release-image-signature-to-dir=${OKD_LAB_PATH}/lab-config/work-dir

  SIG_FILE=$(ls ${OKD_LAB_PATH}/lab-config/work-dir)
  mv ${OKD_LAB_PATH}/lab-config/work-dir/${SIG_FILE} ${OKD_LAB_PATH}/lab-config/release-sigs/${OKD_RELEASE}-sig.yaml
  rm -rf ${OKD_LAB_PATH}/lab-config/work-dir
}

function deleteControlPlane() {
  #Delete Control Plane Nodes:
  RESET_LB="true"
  CP_COUNT=$(yq e ".control-plane.okd-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
  if [[ ${CP_COUNT} == "1" ]]
  then
    SNO="true"
    RESET_LB="false"
  fi
  metal=$(yq e ".control-plane.metal" ${CLUSTER_CONFIG})
  if [[ ${SNO} == "true" ]]
  then
    mac_addr=$(yq e ".control-plane.okd-hosts.[0].mac-addr" ${CLUSTER_CONFIG})
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
    for node_index in 0 1 2
    do
      mac_addr=$(yq e ".control-plane.okd-hosts.[${node_index}].mac-addr" ${CLUSTER_CONFIG})
      host_name=$(yq e ".control-plane.okd-hosts.[${node_index}].name" ${CLUSTER_CONFIG})
      if [[ ${metal} == "true" ]]
      then
        boot_dev=$(yq e ".control-plane.okd-hosts.[${node_index}].boot-dev" ${CLUSTER_CONFIG})
        destroyMetal core ${host_name} ${boot_dev}
      else
        kvm_host=$(yq e ".control-plane.okd-hosts.[${node_index}].kvm-host" ${CLUSTER_CONFIG})
        deleteNodeVm ${host_name} ${kvm_host}
      fi
      deletePxeConfig ${mac_addr}
    done
  fi
  if [[ ${RESET_LB} == "true" ]]
  then
    ${SSH} root@${DOMAIN_ROUTER} "/etc/init.d/haproxy-${CLUSTER_NAME} stop ; \
      /etc/init.d/haproxy-${CLUSTER_NAME} disable ; \
      rm -f /etc/init.d/haproxy-${CLUSTER_NAME} ; \
      rm -f /etc/haproxy-${CLUSTER_NAME}.cfg ; \
      uci delete network.${CLUSTER_NAME}_lb ; \
      uci commit ; \
      /etc/init.d/network reload"
    fi
  deleteDns ${CLUSTER_NAME}-${DOMAIN}-cp
}

function createLbConfig() {

local cp_0=$(yq e ".control-plane.okd-hosts.[0].ip-addr" ${CLUSTER_CONFIG})
local cp_1=$(yq e ".control-plane.okd-hosts.[1].ip-addr" ${CLUSTER_CONFIG})
local cp_2=$(yq e ".control-plane.okd-hosts.[2].ip-addr" ${CLUSTER_CONFIG})
local bs=$(yq e ".bootstrap.ip-addr" ${CLUSTER_CONFIG})
local haproxy_ip=$(yq e ".cluster.ingress-ip-addr" ${CLUSTER_CONFIG})

cat << EOF > ${WORK_DIR}/haproxy-${CLUSTER_NAME}.init
#!/bin/sh /etc/rc.common
# Copyright (C) 2009-2010 OpenWrt.org

START=99
STOP=80

SERVICE_USE_PID=1
EXTRA_COMMANDS="check"

HAPROXY_BIN="/usr/sbin/haproxy"
HAPROXY_CONFIG="/etc/haproxy-${CLUSTER_NAME}.cfg"
HAPROXY_PID="/var/run/haproxy-${CLUSTER_NAME}.pid"

start() {
	service_start \$HAPROXY_BIN -q -D -f "\$HAPROXY_CONFIG" -p "\$HAPROXY_PID"
}

stop() {
	kill -9 \$(cat \$HAPROXY_PID)
	service_stop \$HAPROXY_BIN
}

reload() {
	\$HAPROXY_BIN -D -q -f \$HAPROXY_CONFIG -p \$HAPROXY_PID -sf \$(cat \$HAPROXY_PID)
}

check() {
        \$HAPROXY_BIN -c -q -V -f \$HAPROXY_CONFIG
}
EOF

cat << EOF > ${WORK_DIR}/haproxy-${CLUSTER_NAME}.cfg
global

    log         127.0.0.1 local2

    chroot      /data/haproxy
    pidfile     /var/run/haproxy.pid
    maxconn     50000
    user        haproxy
    group       haproxy
    daemon

    stats socket /data/haproxy/stats

defaults
    mode                    http
    log                     global
    option                  dontlognull
    option                  redispatch
    retries                 3
    timeout http-request    10s
    timeout queue           1m
    timeout connect         10s
    timeout client          10m
    timeout server          10m
    timeout http-keep-alive 10s
    timeout check           10s
    maxconn                 50000

listen okd4-api 
    bind ${haproxy_ip}:6443
    balance roundrobin
    option                  tcplog
    mode tcp
    option tcpka
    option tcp-check
    server okd4-bootstrap ${bs}:6443 check weight 1
    server okd4-master-0 ${cp_0}:6443 check weight 1
    server okd4-master-1 ${cp_1}:6443 check weight 1
    server okd4-master-2 ${cp_2}:6443 check weight 1

listen okd4-mc 
    bind ${haproxy_ip}:22623
    balance roundrobin
    option                  tcplog
    mode tcp
    option tcpka
    server okd4-bootstrap ${bs}:22623 check weight 1
    server okd4-master-0 ${cp_0}:22623 check weight 1
    server okd4-master-1 ${cp_1}:22623 check weight 1
    server okd4-master-2 ${cp_2}:22623 check weight 1

listen okd4-apps 
    bind ${haproxy_ip}:80
    balance source
    option                  tcplog
    mode tcp
    option tcpka
    server okd4-master-0 ${cp_0}:80 check weight 1
    server okd4-master-1 ${cp_1}:80 check weight 1
    server okd4-master-2 ${cp_2}:80 check weight 1

listen okd4-apps-ssl 
    bind ${haproxy_ip}:443
    balance source
    option                  tcplog
    mode tcp
    option tcpka
    option tcp-check
    server okd4-master-0 ${cp_0}:443 check weight 1
    server okd4-master-1 ${cp_1}:443 check weight 1
    server okd4-master-2 ${cp_2}:443 check weight 1
EOF

${SCP} ${WORK_DIR}/haproxy-${CLUSTER_NAME}.cfg root@${DOMAIN_ROUTER}:/etc/haproxy-${CLUSTER_NAME}.cfg
${SCP} ${WORK_DIR}/haproxy-${CLUSTER_NAME}.init root@${DOMAIN_ROUTER}:/etc/init.d/haproxy-${CLUSTER_NAME}
${SSH} root@${DOMAIN_ROUTER} "uci set network.${CLUSTER_NAME}_lb=interface ; \
  uci set network.${CLUSTER_NAME}_lb.ifname=\"@lan\" ; \
  uci set network.${CLUSTER_NAME}_lb.proto=static ; \
  uci set network.${CLUSTER_NAME}_lb.hostname=${CLUSTER_NAME}-lb.${DOMAIN} ; \
  uci set network.${CLUSTER_NAME}_lb.ipaddr=${haproxy_ip}/${DOMAIN_NETMASK} ; \
  uci commit ; \
  /etc/init.d/network reload ; \
  sleep 2 ; \
  chmod 644 /etc/haproxy-${CLUSTER_NAME}.cfg ; \
  chmod 750 /etc/init.d/haproxy-${CLUSTER_NAME} ; \
  /etc/init.d/haproxy-${CLUSTER_NAME} enable ; \
  /etc/init.d/haproxy-${CLUSTER_NAME} start"
}

function startNode() {
  local kvm_host=${1}
  local host_name=${2}
  ${SSH} root@${kvm_host}.${DOMAIN} "virsh start ${host_name}"
}

function startBootstrap() {
  host_name="$(yq e ".cluster.name" ${CLUSTER_CONFIG})-bootstrap"

  if [[ $(yq e ".bootstrap.metal" ${CLUSTER_CONFIG}) == "true" ]]
  then
    memory=$(yq e ".bootstrap.node-spec.memory" ${CLUSTER_CONFIG})
    cpu=$(yq e ".bootstrap.node-spec.cpu" ${CLUSTER_CONFIG})
    root_vol=$(yq e ".bootstrap.node-spec.root_vol" ${CLUSTER_CONFIG})
    bridge_dev=$(yq e ".bootstrap.bridge-dev" ${CLUSTER_CONFIG})
    WORK_DIR=${OKD_LAB_PATH}/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}
    mkdir -p ${WORK_DIR}/bootstrap
    qemu-img create -f qcow2 ${WORK_DIR}/bootstrap/bootstrap-node.qcow2 ${root_vol}G
    qemu-system-x86_64 -accel accel=hvf -m ${memory}M -smp ${cpu} -display none -nographic -drive file=${WORK_DIR}/bootstrap/bootstrap-node.qcow2,if=none,id=disk1  -device ide-hd,bus=ide.0,drive=disk1,id=sata0-0-0,bootindex=1 -boot n -netdev vde,id=nic0,sock=/var/run/vde.bridged.${bridge_dev}.ctl -device virtio-net-pci,netdev=nic0,mac=52:54:00:a1:b2:c3
  else
    kvm_host=$(yq e ".bootstrap.kvm-host" ${CLUSTER_CONFIG})
    startNode ${kvm_host} ${host_name}
  fi
}

function startControlPlane() {
  if [[ $(yq e ".control-plane.metal" ${CLUSTER_CONFIG}) == "true" ]]
  then
    echo "This script will not auto start bare-metal nodes.  Please power them on manually."
  else
    for node_index in 0 1 2
    do
      kvm_host=$(yq e ".control-plane.okd-hosts.[${node_index}].kvm-host" ${CLUSTER_CONFIG})
      host_name=$(yq e ".control-plane.okd-hosts.[${node_index}].name" ${CLUSTER_CONFIG})
      startNode ${kvm_host} ${host_name}
      echo "Pause for 15 seconds to stagger node start up."
      sleep 15
    done
  fi
}

function stopControlPlane() {
  let node_count=$(yq e ".control-plane.okd-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ ${node_index} -lt ${node_count} ]]
  do
    host_name=$(yq e ".control-plane.okd-hosts.[${node_index}].name" ${CLUSTER_CONFIG})
    ${SSH} -o ConnectTimeout=5 core@${host_name}.${DOMAIN} "sudo systemctl poweroff"
    node_index=$(( ${node_index} + 1 ))
  done
}

function deployCluster() {
  WORK_DIR=${OKD_LAB_PATH}/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}
  rm -rf ${WORK_DIR}
  mkdir -p ${WORK_DIR}/ipxe-work-dir/ignition
  mkdir ${WORK_DIR}/dns-work-dir
  mkdir ${WORK_DIR}/okd-install-dir
  CP_REPLICAS="3"
  SNO_BIP=""
  SNO="false"
  BIP="false"
  if [[ -d ${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN} ]]
  then
    rm -rf ${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}
  fi
  mkdir -p ${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}
  SSH_KEY=$(cat ${OKD_LAB_PATH}/ssh_key.pub)
  NEXUS_CERT=$(openssl s_client -showcerts -connect ${PROXY_REGISTRY} </dev/null 2>/dev/null|openssl x509 -outform PEM | while read line; do echo "  ${line}"; done)
  CP_REPLICAS=$(yq e ".control-plane.okd-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
  if [[ ${CP_REPLICAS} == "1" ]]
  then
    SNO="true"
  elif [[ ${CP_REPLICAS} != "3" ]]
  then
    echo "There must be 3 host entries for the control plane for a full cluster, or 1 entry for a Single Node cluster."
    exit 1
  fi

  # Create and deploy ignition files single-node-ignition-config
  

  if [[ $(yq e ". | has(\"bootstrap\")" ${CLUSTER_CONFIG}) == "false" ]]
  then
    BIP="true"
  fi

  if [[ ${BIP} == "false" ]] # Create Bootstrap Node
  then
    # Create ignition files
    createInstallConfig "null"
    cp ${WORK_DIR}/install-config-upi.yaml ${WORK_DIR}/okd-install-dir/install-config.yaml
    openshift-install --dir=${WORK_DIR}/okd-install-dir create ignition-configs
    cp ${WORK_DIR}/okd-install-dir/*.ign ${WORK_DIR}/ipxe-work-dir/
    # Create Bootstrap Node:
    host_name=${CLUSTER_NAME}-bootstrap
    yq e ".bootstrap.name = \"${host_name}\"" -i ${CLUSTER_CONFIG}
    bs_ip_addr=$(yq e ".bootstrap.ip-addr" ${CLUSTER_CONFIG})
    boot_dev=sda
    platform=qemu
    if [[ $(yq e ".bootstrap.metal" ${CLUSTER_CONFIG}) == "false" ]]
    then
      kvm_host=$(yq e ".bootstrap.kvm-host" ${CLUSTER_CONFIG})
      memory=$(yq e ".bootstrap.node-spec.memory" ${CLUSTER_CONFIG})
      cpu=$(yq e ".bootstrap.node-spec.cpu" ${CLUSTER_CONFIG})
      root_vol=$(yq e ".bootstrap.node-spec.root_vol" ${CLUSTER_CONFIG})
      createOkdVmNode ${bs_ip_addr} ${host_name} ${kvm_host} bootstrap ${memory} ${cpu} ${root_vol} 0 ".bootstrap.mac-addr"
    fi
    # Create the ignition and iPXE boot files
    mac_addr=$(yq e ".bootstrap.mac-addr" ${CLUSTER_CONFIG})
    configOkdNode ${bs_ip_addr} ${host_name}.${DOMAIN} ${mac_addr} bootstrap
    createPxeFile ${mac_addr} ${platform} ${boot_dev}
  fi

  #Create Control Plane Nodes:
  metal=$(yq e ".control-plane.metal" ${CLUSTER_CONFIG})
  if [[ ${metal} == "true" ]]
  then
    platform=metal
  else
    platform=qemu
  fi

  if [[ ${SNO} == "true" ]]
  then
    ip_addr=$(yq e ".control-plane.okd-hosts.[0].ip-addr" ${CLUSTER_CONFIG})
    host_name=${CLUSTER_NAME}-node
    yq e ".control-plane.okd-hosts.[0].name = \"${host_name}\"" -i ${CLUSTER_CONFIG}
    if [[ ${metal} == "false" ]]
    then
      memory=$(yq e ".control-plane.node-spec.memory" ${CLUSTER_CONFIG})
      cpu=$(yq e ".control-plane.node-spec.cpu" ${CLUSTER_CONFIG})
      root_vol=$(yq e ".control-plane.node-spec.root_vol" ${CLUSTER_CONFIG})
      kvm_host=$(yq e ".control-plane.okd-hosts.[0].kvm-host" ${CLUSTER_CONFIG})
      # Create the VM
      createOkdVmNode ${ip_addr} ${host_name} ${kvm_host} sno ${memory} ${cpu} ${root_vol} 0 ".control-plane.okd-hosts.[0].mac-addr"
    fi
    # Create the ignition and iPXE boot files
    mac_addr=$(yq e ".control-plane.okd-hosts.[0].mac-addr" ${CLUSTER_CONFIG})
    install_dev=$(yq e ".control-plane.okd-hosts.[0].sno-install-dev" ${CLUSTER_CONFIG})
    boot_dev=$(yq e ".control-plane.okd-hosts.[0].boot-dev" ${CLUSTER_CONFIG})
    if [[ ${BIP} == "true" ]]
    then
      createInstallConfig ${install_dev}
      cp ${WORK_DIR}/install-config-upi.yaml ${WORK_DIR}/okd-install-dir/install-config.yaml
      openshift-install --dir=${WORK_DIR}/okd-install-dir create single-node-ignition-config
      cp ${WORK_DIR}/okd-install-dir/bootstrap-in-place-for-live-iso.ign ${WORK_DIR}/ipxe-work-dir/sno.ign
      configOkdNode ${ip_addr} ${host_name}.${DOMAIN} ${mac_addr} sno
      createSnoBipDNS ${host_name} ${ip_addr}
    else
      configOkdNode ${ip_addr} ${host_name}.${DOMAIN} ${mac_addr} master
      createSnoDNS ${host_name} ${ip_addr} ${bs_ip_addr}
    fi
    createPxeFile ${mac_addr} ${platform} ${boot_dev}
  else
    # Create DNS Entries:
    ingress_ip=$(yq e ".cluster.ingress-ip-addr" ${CLUSTER_CONFIG})
    echo "${CLUSTER_NAME}-bootstrap.${DOMAIN}.  IN      A      ${bs_ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-bs" >> ${WORK_DIR}/dns-work-dir/forward.zone
    echo "*.apps.${CLUSTER_NAME}.${DOMAIN}.     IN      A      ${ingress_ip} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
    echo "api.${CLUSTER_NAME}.${DOMAIN}.        IN      A      ${ingress_ip} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
    echo "api-int.${CLUSTER_NAME}.${DOMAIN}.    IN      A      ${ingress_ip} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
    bs_o4=$(echo ${bs_ip_addr} | cut -d"." -f4)
    echo "${bs_o4}    IN      PTR     ${CLUSTER_NAME}-bootstrap.${DOMAIN}.   ; ${CLUSTER_NAME}-${DOMAIN}-bs" >> ${WORK_DIR}/dns-work-dir/reverse.zone
    for node_index in 0 1 2
    do
      ip_addr=$(yq e ".control-plane.okd-hosts.[${node_index}].ip-addr" ${CLUSTER_CONFIG})
      host_name=${CLUSTER_NAME}-master-${node_index}
      yq e ".control-plane.okd-hosts.[${node_index}].name = \"${host_name}\"" -i ${CLUSTER_CONFIG}
      if [[ ${metal} == "true" ]]
      then
        boot_dev=$(yq e ".control-plane.okd-hosts.[${node_index}].boot-dev" ${CLUSTER_CONFIG})
      else
        memory=$(yq e ".control-plane.node-spec.memory" ${CLUSTER_CONFIG})
        cpu=$(yq e ".control-plane.node-spec.cpu" ${CLUSTER_CONFIG})
        root_vol=$(yq e ".control-plane.node-spec.root_vol" ${CLUSTER_CONFIG})
        kvm_host=$(yq e ".control-plane.okd-hosts.[${node_index}].kvm-host" ${CLUSTER_CONFIG})
        boot_dev="sda"
        # Create the VM
        createOkdVmNode ${ip_addr} ${host_name} ${kvm_host} master ${memory} ${cpu} ${root_vol} 0 ".control-plane.okd-hosts.[${node_index}].mac-addr"
      fi
      # Create the ignition and iPXE boot files
      mac_addr=$(yq e ".control-plane.okd-hosts.[${node_index}].mac-addr" ${CLUSTER_CONFIG})
      configOkdNode ${ip_addr} ${host_name}.${DOMAIN} ${mac_addr} master
      createPxeFile ${mac_addr} ${platform} ${boot_dev}
      # Create control plane node DNS Records:
      echo "${host_name}.${DOMAIN}.   IN      A      ${ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
      echo "etcd-${node_index}.${DOMAIN}.          IN      A      ${ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
      o4=$(echo ${ip_addr} | cut -d"." -f4)
      echo "${o4}    IN      PTR     ${host_name}.${DOMAIN}.  ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/reverse.zone
    done
    # Create DNS SRV Records:
    for node_index in 0 1 2
    do
      echo "_etcd-server-ssl._tcp.${CLUSTER_NAME}.${DOMAIN}    86400     IN    SRV     0    10    2380    etcd-${node_index}.${CLUSTER_NAME}.${DOMAIN}. ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
    done
    # Create The HA-Proxy Load Balancer
    createLbConfig
  fi

  KERNEL_URL=$(openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.kernel.location')
  INITRD_URL=$(openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.initramfs.location')
  ROOTFS_URL=$(openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.rootfs.location')

  ${SSH} root@${BASTION_HOST} "if [[ ! -d /usr/local/www/install/fcos/${OKD_RELEASE} ]] ; \
    then mkdir -p /usr/local/www/install/fcos/${OKD_RELEASE} ; \
    curl -o /usr/local/www/install/fcos/${OKD_RELEASE}/vmlinuz ${KERNEL_URL} ; \
    curl -o /usr/local/www/install/fcos/${OKD_RELEASE}/initrd ${INITRD_URL} ; \
    curl -o /usr/local/www/install/fcos/${OKD_RELEASE}/rootfs.img ${ROOTFS_URL} ; \
    fi"

  cp ${WORK_DIR}/okd-install-dir/auth/kubeconfig ${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}/
  chmod 400 ${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}/kubeconfig
  prepNodeFiles
}

function deployWorkers() {
  WORK_DIR=${OKD_LAB_PATH}/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}
  rm -rf ${WORK_DIR}
  mkdir -p ${WORK_DIR}/ipxe-work-dir/ignition
  mkdir -p ${WORK_DIR}/dns-work-dir
  setKubeConfig
  oc extract -n openshift-machine-api secret/worker-user-data --keys=userData --to=- > ${WORK_DIR}/ipxe-work-dir/worker.ign
  let node_count=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    host_name=${CLUSTER_NAME}-worker-${node_index}
    yq e ".compute-nodes.[${node_index}].name = \"${host_name}\"" -i ${CLUSTER_CONFIG}
    ip_addr=$(yq e ".compute-nodes.[${node_index}].ip-addr" ${CLUSTER_CONFIG})
    if [[ $(yq e ".compute-nodes.[${node_index}].metal" ${CLUSTER_CONFIG}) == "true" ]]
    then
      platform=metal
      boot_dev=$(yq e ".compute-nodes.[${node_index}].boot-dev" ${CLUSTER_CONFIG})
    else
      platform=qemu
      boot_dev="sda"
      memory=$(yq e ".compute-nodes.[${node_index}].node-spec.memory" ${CLUSTER_CONFIG})
      cpu=$(yq e ".compute-nodes.[${node_index}].node-spec.cpu" ${CLUSTER_CONFIG})
      root_vol=$(yq e ".compute-nodes.[${node_index}].node-spec.root_vol" ${CLUSTER_CONFIG})
      ceph_vol=$(yq e ".compute-nodes.[${node_index}].node-spec.ceph_vol" ${CLUSTER_CONFIG})
      kvm_host=$(yq e ".compute-nodes.[${node_index}].kvm-host" ${CLUSTER_CONFIG})
      # Create the VM
      createOkdVmNode ${ip_addr} ${host_name} ${kvm_host} worker ${memory} ${cpu} ${root_vol} ${ceph_vol} ".compute-nodes.[${node_index}].mac-addr"
    fi
    # Create the ignition and iPXE boot files
    mac_addr=$(yq e ".compute-nodes.[${node_index}].mac-addr" ${CLUSTER_CONFIG})
    configOkdNode ${ip_addr} ${host_name}.${DOMAIN} ${mac_addr} worker
    createPxeFile ${mac_addr} ${platform} ${boot_dev}
    # Create DNS entries
    echo "${host_name}.${DOMAIN}.   IN      A      ${ip_addr} ; ${host_name}-${DOMAIN}-wk" >> ${WORK_DIR}/dns-work-dir/forward.zone
    o4=$(echo ${ip_addr} | cut -d"." -f4)
    echo "${o4}    IN      PTR     ${host_name}.${DOMAIN}. ; ${host_name}-${DOMAIN}-wk" >> ${WORK_DIR}/dns-work-dir/reverse.zone
    node_index=$(( ${node_index} + 1 ))
  done
  prepNodeFiles
}
