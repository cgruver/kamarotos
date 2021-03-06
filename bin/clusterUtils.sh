function createInstallConfig() {

  local install_dev=${1}
  PULL_SECRET_TXT=$(cat ${PULL_SECRET})

if [[ ${BIP} == "true" ]]
then
read -r -d '' SNO_BIP << EOF
BootstrapInPlace:
  InstallationDisk: "--copy-network ${install_dev}"
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
      if [[ ${node_index} -gt 0 ]]
      then
        pause 15 "Pause to stagger node start up"
      fi
      kvm_host=$(yq e ".compute-nodes.[${node_index}].kvm-host" ${CLUSTER_CONFIG})  
      startNode ${kvm_host} ${host_name}
    fi
    node_index=$(( ${node_index} + 1 ))
  done
}

function stopWorkers() {
  
  let node_count=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)

  # Cordon Compute Nodes
  cordonNode

  # Drain & Shutdown Compute Nodes
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    host_name=$(yq e ".compute-nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    ${OC} adm drain ${host_name}.${DOMAIN} --ignore-daemonsets --force --grace-period=20 --delete-emptydir-data
    ${SSH} -o ConnectTimeout=5 core@${host_name}.${DOMAIN} "sudo systemctl poweroff"
    node_index=$(( ${node_index} + 1 ))
  done
}

function deleteWorker() {
  local index=${1}
  local p_cmd=${2}

  host_name=$(yq e ".compute-nodes.[${index}].name" ${CLUSTER_CONFIG})
  mac_addr=$(yq e ".control-plane.okd-hosts.[${index}].mac-addr" ${CLUSTER_CONFIG})
  if [[ $(yq e ".compute-nodes.[${index}].metal" ${CLUSTER_CONFIG})  == "true" ]]
  then
    boot_dev=$(yq e ".compute-nodes.[${index}].boot-dev" ${CLUSTER_CONFIG})
    ceph_dev=$(yq e ".compute-nodes.[${index}].ceph.ceph-dev" ${CLUSTER_CONFIG})
    destroyMetal core ${host_name} ${boot_dev} "/dev/${ceph_dev}" ${p_cmd}
  else
    kvm_host=$(yq e ".compute-nodes.[${index}].kvm-host" ${CLUSTER_CONFIG})
    deleteNodeVm ${host_name} ${kvm_host}
  fi
  deleteDns ${host_name}-${DOMAIN}
  deletePxeConfig ${mac_addr}
}

function cordonNode() {
  
  let node_count=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    host_name=$(yq e ".compute-nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    ${OC} adm cordon ${host_name}.${DOMAIN}
    node_index=$(( ${node_index} + 1 ))
  done
}

function unCordonNode() {
  
  let node_count=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    host_name=$(yq e ".compute-nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    ${OC} adm uncordon ${host_name}.${DOMAIN}
    node_index=$(( ${node_index} + 1 ))
  done
}

function stopCluster() {
  ${OC} patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Removed"}}'
  node_count=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  if [[ ${node_count} -gt 0 ]]
  then
    stopWorkers
    pause 60 "Giving Compute Nodes Time to Shutdown"
  fi
  stopControlPlane
}

function addUser() {
  
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
    echo "Usage: labcli --user [ -a | --admin ] -u=user-name-to-add"
    exit 1
  fi
  htpasswd -B ${PASSWD_FILE} ${USER}
  ${OC} create -n openshift-config secret generic okd-htpasswd-secret --from-file=htpasswd=${PASSWD_FILE} -o yaml --dry-run='client' | ${OC} apply -f -
  if [[ ${ADMIN_USER} == "true" ]]
  then
    ${OC} adm policy add-cluster-role-to-user cluster-admin ${USER}
  fi
  if [[ ${OAUTH_INIT} == "true" ]]
  then
    ${OC} patch oauth cluster --type merge --patch '{"spec":{"identityProviders":[{"name":"okd_htpasswd_idp","mappingMethod":"claim","type":"HTPasswd","htpasswd":{"fileData":{"name":"okd-htpasswd-secret"}}}]}}'
    ${OC} delete secrets kubeadmin -n kube-system
  fi
}

function setKubeConfig() {
  export KUBECONFIG=${KUBE_INIT_CONFIG}
}

function approveCsr() {
    ${OC} get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs ${OC} adm certificate approve
}

function pullSecret() {
  NEXUS_PWD="true"
  NEXUS_PWD_CHK="false"

  if [[ ! -d ${OKD_LAB_PATH}/pull-secrets ]]
  then
    mkdir -p ${OKD_LAB_PATH}/pull-secrets
  fi
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

cat << EOF | ${OC} apply -n ${NAMESPACE} -f -
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

  ${OC} patch sa pipeline --type json --patch '[{"op": "add", "path": "/secrets/-", "value": {"name":"git-secret"}}]' -n ${NAMESPACE}
}

function getOkdRelease() {
  OKD_RELEASE=$(basename $(curl -Ls -o /dev/null -w %{url_effective} https://github.com/openshift/okd/releases/latest))
  echo ${OKD_RELEASE}
  yq e ".cluster.release = \"${OKD_RELEASE}\"" -i ${CLUSTER_CONFIG}
}

function ocLogin() {
  for i in "$@"
  do
    case $i in
      -a)
        LOGIN_ALL="true"
      ;;
    esac
  done
  if [[ ${LOGIN_ALL} == "true" ]]
  then
    DOMAIN_COUNT=$(yq e ".sub-domain-configs" ${LAB_CONFIG_FILE} | yq e 'length' -)
    let DOMAIN_INDEX=0
    while [[ ${DOMAIN_INDEX} -lt ${DOMAIN_COUNT} ]]
    do
      labctx $(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].name" ${LAB_CONFIG_FILE})
      oc login -u admin https://api.${CLUSTER_NAME}.${SUB_DOMAIN}.${LAB_DOMAIN}:6443
      DOMAIN_INDEX=$(( ${DOMAIN_INDEX} + 1 ))
    done
  else
    oc login -u admin https://api.${CLUSTER_NAME}.${SUB_DOMAIN}.${LAB_DOMAIN}:6443
  fi
}

function ocConsole() {

  CONSOLE_ALL="false"
  SYS_ARCH=$(uname)
  if [[ ${SYS_ARCH} != "Darwin" ]]
  then
    echo "Unsupported OS: This function currently supports Darwin OS only"
    exit 1
  fi

  for i in "$@"
  do
    case $i in
      -a)
        CONSOLE_ALL="true"
      ;;
    esac
  done

  if [[ ${CONSOLE_ALL} == "true" ]]
  then
    DOMAIN_COUNT=$(yq e ".sub-domain-configs" ${LAB_CONFIG_FILE} | yq e 'length' -)
    let DOMAIN_INDEX=0
    while [[ ${DOMAIN_INDEX} -lt ${DOMAIN_COUNT} ]]
    do
      labctx $(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].name" ${LAB_CONFIG_FILE})
      open -a Safari https://console-openshift-console.apps.${CLUSTER_NAME}.${SUB_DOMAIN}.${LAB_DOMAIN}
      DOMAIN_INDEX=$(( ${DOMAIN_INDEX} + 1 ))
    done
  else
    open -a Safari https://console-openshift-console.apps.${CLUSTER_NAME}.${SUB_DOMAIN}.${LAB_DOMAIN}
  fi
}

function configInfraNodes() {
  
  for node_index in 0 1 2
  do
    ${OC} label nodes ${CLUSTER_NAME}-master-${node_index}.${SUB_DOMAIN}.${LAB_DOMAIN} node-role.kubernetes.io/infra=""
  done
  ${OC} patch scheduler cluster --patch '{"spec":{"mastersSchedulable":false}}' --type=merge
  ${OC} patch -n openshift-ingress-operator ingresscontroller default --patch '{"spec":{"nodePlacement":{"nodeSelector":{"matchLabels":{"node-role.kubernetes.io/infra":""}},"tolerations":[{"key":"node.kubernetes.io/unschedulable","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/master","effect":"NoSchedule"}]}}}' --type=merge
  for node_index in $(${OC} get pods -n openshift-ingress-canary | grep -v NAME | cut -d" " -f1)
  do
    ${OC} delete pod ${node_index} -n openshift-ingress-canary
  done

  ${OC} patch configs.imageregistry.operator.openshift.io cluster --patch '{"spec":{"nodeSelector":{"node-role.kubernetes.io/infra":""},"tolerations":[{"key":"node.kubernetes.io/unschedulable","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/master","effect":"NoSchedule"}]}}' --type=merge

cat << EOF | ${OC} apply -f -
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
  local p_cmd=${1}
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
      destroyMetal core ${host_name} ${install_dev} na ${p_cmd}
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
        destroyMetal core ${host_name} ${boot_dev} na ${p_cmd}
      else
        kvm_host=$(yq e ".control-plane.okd-hosts.[${node_index}].kvm-host" ${CLUSTER_CONFIG})
        deleteNodeVm ${host_name} ${kvm_host}
      fi
      deletePxeConfig ${mac_addr}
    done
  fi
  if [[ ${RESET_LB} == "true" ]]
  then
    INTERFACE=$(echo "${CLUSTER_NAME//-/_}" | tr "[:upper:]" "[:lower:]")
    ${SSH} root@${DOMAIN_ROUTER} "/etc/init.d/haproxy-${CLUSTER_NAME} stop ; \
      /etc/init.d/haproxy-${CLUSTER_NAME} disable ; \
      rm -f /etc/init.d/haproxy-${CLUSTER_NAME} ; \
      rm -f /etc/haproxy-${CLUSTER_NAME}.cfg ; \
      uci delete network.${INTERFACE}_lb ; \
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

INTERFACE=$(echo "${CLUSTER_NAME//-/_}" | tr "[:upper:]" "[:lower:]")
${SSH} root@${DOMAIN_ROUTER} "uci set network.${INTERFACE}_lb=interface ; \
  uci set network.${INTERFACE}_lb.ifname=\"@lan\" ; \
  uci set network.${INTERFACE}_lb.proto=static ; \
  uci set network.${INTERFACE}_lb.hostname=${CLUSTER_NAME}-lb.${DOMAIN} ; \
  uci set network.${INTERFACE}_lb.ipaddr=${haproxy_ip}/${DOMAIN_NETMASK} ; \
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
    root_vol=$(yq e ".bootstrap.node-spec.root-vol" ${CLUSTER_CONFIG})
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
      if [[ ${node_index} -gt 0 ]]
      then
        pause 15 "Pause to stagger node start up"
      fi
      kvm_host=$(yq e ".control-plane.okd-hosts.[${node_index}].kvm-host" ${CLUSTER_CONFIG})
      host_name=$(yq e ".control-plane.okd-hosts.[${node_index}].name" ${CLUSTER_CONFIG})
      startNode ${kvm_host} ${host_name}
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
      root_vol=$(yq e ".bootstrap.node-spec.root-vol" ${CLUSTER_CONFIG})
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
      root_vol=$(yq e ".control-plane.node-spec.root-vol" ${CLUSTER_CONFIG})
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
        root_vol=$(yq e ".control-plane.node-spec.root-vol" ${CLUSTER_CONFIG})
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
  
  ${OC} extract -n openshift-machine-api secret/worker-user-data --keys=userData --to=- > ${WORK_DIR}/ipxe-work-dir/worker.ign
  let node_count=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    host_name=${CLUSTER_NAME}-worker-${node_index}
    yq e ".compute-nodes.[${node_index}].name = \"${host_name}\"" -i ${CLUSTER_CONFIG}
    ip_addr=$(yq e ".compute-nodes.[${node_index}].ip-addr" ${CLUSTER_CONFIG})
    ceph_node=$(yq ".compute-nodes.[${node_index}] | has(\"ceph\")" ${CLUSTER_CONFIG})
    if [[ $(yq e ".compute-nodes.[${node_index}].metal" ${CLUSTER_CONFIG}) == "true" ]]
    then
      platform=metal
      boot_dev=$(yq e ".compute-nodes.[${node_index}].boot-dev" ${CLUSTER_CONFIG})
    else
      platform=qemu
      boot_dev="sda"
      memory=$(yq e ".compute-nodes.[${node_index}].node-spec.memory" ${CLUSTER_CONFIG})
      cpu=$(yq e ".compute-nodes.[${node_index}].node-spec.cpu" ${CLUSTER_CONFIG})
      root_vol=$(yq e ".compute-nodes.[${node_index}].node-spec.root-vol" ${CLUSTER_CONFIG})
      kvm_host=$(yq e ".compute-nodes.[${node_index}].kvm-host" ${CLUSTER_CONFIG})
      # Create the VM
      if [[ ${ceph_node} == "true" ]]
      then
        ceph_vol=$(yq e ".compute-nodes.[${node_index}].ceph.ceph-vol" ${CLUSTER_CONFIG})
      else
        ceph_vol=0
      fi
      createOkdVmNode ${ip_addr} ${host_name} ${kvm_host} worker ${memory} ${cpu} ${root_vol} ${ceph_vol} ".compute-nodes.[${node_index}].mac-addr"
    fi
    # Create the ignition and iPXE boot files
    mac_addr=$(yq e ".compute-nodes.[${node_index}].mac-addr" ${CLUSTER_CONFIG})
    configOkdNode ${ip_addr} ${host_name}.${DOMAIN} ${mac_addr} worker
    if [[ ${ceph_node} == "true" ]]
    then
      ceph_type=$(yq e ".compute-nodes.[${node_index}].ceph.type" ${CLUSTER_CONFIG})
      if [[ ${ceph_type} == "part" ]]
      then
        configCephPart ${mac_addr} ${boot_dev}
      fi
    fi
    createPxeFile ${mac_addr} ${platform} ${boot_dev}
    # Create DNS entries
    echo "${host_name}.${DOMAIN}.   IN      A      ${ip_addr} ; ${host_name}-${DOMAIN}-wk" >> ${WORK_DIR}/dns-work-dir/forward.zone
    o4=$(echo ${ip_addr} | cut -d"." -f4)
    echo "${o4}    IN      PTR     ${host_name}.${DOMAIN}. ; ${host_name}-${DOMAIN}-wk" >> ${WORK_DIR}/dns-work-dir/reverse.zone
    node_index=$(( ${node_index} + 1 ))
  done
  prepNodeFiles
}

function deploy() {
  for i in "$@"
  do
    case $i in
      -c|--cluster)
        deployCluster
      ;;
      -w|--worker)
        deployWorkers
      ;;
      -k|--kvm-hosts)
        deployKvmHosts
      ;;
      *)
        # catch all
      ;;
    esac
  done
}

function destroy() {
  P_CMD="poweroff"

  for i in "$@"
  do
    case $i in
      -b|--bootstrap)
        DELETE_BOOTSTRAP=true
      ;;
      -w=*|--worker=*)
        DELETE_WORKER=true
        W_HOST_NAME="${i#*=}"
      ;;
      -c|--cluster)
        DELETE_CLUSTER=true
        DELETE_WORKER=true
        W_HOST_NAME="all"
      ;;
      -k=*|--kvm-host=*)
        DELETE_KVM_HOST=true
        K_HOST_NAME="${i#*=}"
      ;;
      -m=*|--master=*)
        M_HOST_NAME="${i#*=}"
      ;;
      -r)
        P_CMD="reboot"
      ;;
      *)
        # catch all
      ;;
    esac
  done

  WORK_DIR=${OKD_LAB_PATH}/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}

  if [[ ${DELETE_WORKER} == "true" ]]
  then
    if [[ ${W_HOST_NAME} == "" ]]
    then
      echo "-w | --worker must have a value"
      exit 1
    fi
    if [[ ${W_HOST_NAME} == "all" ]] # Delete all Nodes
    then
      let j=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
      let i=0
      while [[ i -lt ${j} ]]
      do
        deleteWorker ${i} ${P_CMD}
        i=$(( ${i} + 1 ))
      done
    else
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
      deleteWorker ${W_HOST_INDEX} ${P_CMD}
    fi
  fi

  if [[ ${DELETE_KVM_HOST} == "true" ]]
  then
    if [[ ${K_HOST_NAME} == "" ]]
    then
      echo "-k"
      exit 1
    fi
    if [[ ${K_HOST_NAME} == "all" ]] # Delete all Nodes
    then
      let j=$(yq e ".kvm-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
      let i=0
      while [[ i -lt ${j} ]]
      do
        deleteKvmHost ${i} ${P_CMD}
        i=$(( ${i} + 1 ))
      done
    else
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
      deleteKvmHost ${K_HOST_INDEX} ${P_CMD}
    fi
  fi

  if [[ ${DELETE_BOOTSTRAP} == "true" ]]
  then
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
      ${SSH} root@${DOMAIN_ROUTER} "cat /etc/haproxy-${CLUSTER_NAME}.cfg | grep -v bootstrap > /etc/haproxy-${CLUSTER_NAME}.no-bootstrap && \
      mv /etc/haproxy-${CLUSTER_NAME}.no-bootstrap /etc/haproxy-${CLUSTER_NAME}.cfg && \
      /etc/init.d/haproxy-${CLUSTER_NAME} stop ; \
      /etc/init.d/haproxy-${CLUSTER_NAME} start"
    fi
  fi

  if [[ ${DELETE_CLUSTER} == "true" ]]
  then
    deleteControlPlane ${P_CMD}
  fi

  ${SSH} root@${DOMAIN_ROUTER} "/etc/init.d/named stop && sleep 2 && /etc/init.d/named start && sleep 2"
  ${SSH} root@${EDGE_ROUTER} "/etc/init.d/named stop && sleep 2 && /etc/init.d/named start"
}

function start() {
  for i in "$@"
  do
    case $i in
      -b)
        startBootstrap
      ;;
      -m)
        startControlPlane
      ;;
      -w)
        startWorker
      ;;
      -u)
        unCordonNode
      ;;
      -i)
        ${OC} patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed"}}'
      ;;
      *)
        # catch all
      ;;
    esac
  done
}

function monitor() {

  for i in "$@"
  do
    case $i in
      -b)
        openshift-install --dir=${INSTALL_DIR} wait-for bootstrap-complete --log-level debug
      ;;
      -i)
        openshift-install --dir=${INSTALL_DIR} wait-for install-complete --log-level debug
      ;;
      -j)
        ${SSH} core@${CLUSTER_NAME}-bootstrap.${SUB_DOMAIN}.${LAB_DOMAIN} "journalctl -b -f -u release-image.service -u bootkube.service"
      ;;
      -m=*)
        CP_INDEX="${i#*=}"
        ${SSH} core@${CLUSTER_NAME}-master-${CP_INDEX}.${SUB_DOMAIN}.${LAB_DOMAIN} "journalctl -b -f"
      ;;
      -w=*)
        W_INDEX="${i#*=}"
        ${SSH} core@${CLUSTER_NAME}-worker-${W_INDEX}.${SUB_DOMAIN}.${LAB_DOMAIN} "journalctl -b -f"
      ;;
      *)
        # catch all
      ;;
    esac
  done
}

function stop() {
  for i in "$@"
  do
    case $i in
      -c|--cluster)
        stopCluster
      ;;
      -w|--worker)
        stopWorkers
      ;;
      -k|--kvm)
        stopKvmHosts
      ;;
      *)
        # catch all
      ;;
    esac
  done
}

function mirrorCeph() {

  echo "Enter the credentials for the openshift mirrir service account in Nexus:"
  podman login ${LOCAL_REGISTRY}

  echo "Pulling Rook/Ceph Images..."
  podman pull  quay.io/cephcsi/cephcsi:${CEPH_CSI_VER}
  podman pull  k8s.gcr.io/sig-storage/csi-node-driver-registrar:${CSI_NODE_DRIVER_REG_VER}
  podman pull  k8s.gcr.io/sig-storage/csi-resizer:${CSI_RESIZER_VER}
  podman pull  k8s.gcr.io/sig-storage/csi-provisioner:${CSI_PROVISIONER_VER}
  podman pull  k8s.gcr.io/sig-storage/csi-snapshotter:${CSI_SNAPSHOTTER_VER}
  podman pull  k8s.gcr.io/sig-storage/csi-attacher:${CSI_ATTACHER_VER}
  podman pull  docker.io/rook/ceph:${ROOK_CEPH_VER}
  podman pull  quay.io/ceph/ceph:${CEPH_VER}

  echo "Tagging Rook/Ceph Images..."
  podman tag quay.io/cephcsi/cephcsi:${CEPH_CSI_VER} ${LOCAL_REGISTRY}/cephcsi/cephcsi:${CEPH_CSI_VER}
  podman tag k8s.gcr.io/sig-storage/csi-node-driver-registrar:${CSI_NODE_DRIVER_REG_VER} ${LOCAL_REGISTRY}/sig-storage/csi-node-driver-registrar:${CSI_NODE_DRIVER_REG_VER}
  podman tag k8s.gcr.io/sig-storage/csi-resizer:${CSI_RESIZER_VER} ${LOCAL_REGISTRY}/sig-storage/csi-resizer:${CSI_RESIZER_VER}
  podman tag k8s.gcr.io/sig-storage/csi-provisioner:${CSI_PROVISIONER_VER} ${LOCAL_REGISTRY}/sig-storage/csi-provisioner:${CSI_PROVISIONER_VER}
  podman tag k8s.gcr.io/sig-storage/csi-snapshotter:${CSI_SNAPSHOTTER_VER} ${LOCAL_REGISTRY}/sig-storage/csi-snapshotter:${CSI_SNAPSHOTTER_VER}
  podman tag k8s.gcr.io/sig-storage/csi-attacher:${CSI_ATTACHER_VER} ${LOCAL_REGISTRY}/sig-storage/csi-attacher:${CSI_ATTACHER_VER}
  podman tag docker.io/rook/ceph:${ROOK_CEPH_VER} ${LOCAL_REGISTRY}/rook/ceph:${ROOK_CEPH_VER}
  podman tag quay.io/ceph/ceph:${CEPH_VER} ${LOCAL_REGISTRY}/ceph/ceph:${CEPH_VER}

  echo "Pushing Rook/Ceph Images..."
  podman push ${LOCAL_REGISTRY}/cephcsi/cephcsi:${CEPH_CSI_VER} --tls-verify=false
  podman push ${LOCAL_REGISTRY}/sig-storage/csi-node-driver-registrar:${CSI_NODE_DRIVER_REG_VER} --tls-verify=false
  podman push ${LOCAL_REGISTRY}/sig-storage/csi-resizer:${CSI_RESIZER_VER} --tls-verify=false
  podman push ${LOCAL_REGISTRY}/sig-storage/csi-provisioner:${CSI_PROVISIONER_VER} --tls-verify=false
  podman push ${LOCAL_REGISTRY}/sig-storage/csi-snapshotter:${CSI_SNAPSHOTTER_VER} --tls-verify=false
  podman push ${LOCAL_REGISTRY}/sig-storage/csi-attacher:${CSI_ATTACHER_VER} --tls-verify=false
  podman push ${LOCAL_REGISTRY}/rook/ceph:${ROOK_CEPH_VER} --tls-verify=false
  podman push ${LOCAL_REGISTRY}/ceph/ceph:${CEPH_VER} --tls-verify=false

  echo "Cleaning up local Rook/Ceph Images..."
  podman image rm -a
}

function installCeph() {

  ${OC} apply -f ${CEPH_WORK_DIR}/install/crds.yaml
  ${OC} apply -f ${CEPH_WORK_DIR}/install/common.yaml
  ${OC} apply -f ${CEPH_WORK_DIR}/install/rbac.yaml

  envsubst < ${CEPH_WORK_DIR}/install/operator-openshift.yaml | ${OC} apply -f -
}

function createCephCluster() {

  let NODE_COUNT=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${NODE_COUNT} ]]
  do
    node_name=$(yq e ".compute-nodes.[${node_index}].name" ${CLUSTER_CONFIG}).${DOMAIN}
    ceph_node=$(yq ".compute-nodes.[${node_index}] | has(\"ceph\")" ${CLUSTER_CONFIG})
    if [[ ${ceph_node} == "true" ]]
    then
      ceph_dev=$(yq e ".compute-nodes.[${node_index}].ceph.ceph-dev" ${CLUSTER_CONFIG})
      yq e ".spec.storage.nodes.[${node_index}].name = \"${node_name}\"" -i ${CEPH_WORK_DIR}/install/cluster.yaml
      yq e ".spec.storage.nodes.[${node_index}].devices.[0].name = \"${ceph_dev}\"" -i ${CEPH_WORK_DIR}/install/cluster.yaml
      yq e ".spec.storage.nodes.[${node_index}].devices.[0].config.osdsPerDevice = \"1\"" -i ${CEPH_WORK_DIR}/install/cluster.yaml
      ${SSH} -o ConnectTimeout=5 core@${node_name} "sudo wipefs -a -f /dev/${ceph_dev} && sudo dd if=/dev/zero of=/dev/${ceph_dev} bs=4096 count=1"
    fi
    node_index=$(( ${node_index} + 1 ))
    ${OC} label nodes ${node_name} role=storage-node
  done
  envsubst < ${CEPH_WORK_DIR}/install/cluster.yaml | ${OC} apply -f -
}

function regPvc() {
  ${OC} apply -f ${CEPH_WORK_DIR}/configure/ceph-storage-class.yaml
  ${OC} patch configmap rook-ceph-operator-config -n rook-ceph --type merge --patch '"data": {"CSI_PLUGIN_TOLERATIONS": "- key: \"node-role.kubernetes.io/master\"\n  operator: \"Exists\"\n  effect: \"NoSchedule\"\n"}'
  ${OC} apply -f ${CEPH_WORK_DIR}/configure/registry-pvc.yaml
  ${OC} patch configs.imageregistry.operator.openshift.io cluster --type json -p '[{ "op": "remove", "path": "/spec/storage/emptyDir" }]'
  ${OC} patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"rolloutStrategy":"Recreate","managementState":"Managed","storage":{"pvc":{"claim":"registry-pvc"}}}}'
}

function initCephVars() {
  export CEPH_WORK_DIR=${OKD_LAB_PATH}/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}/ceph-work-dir
  rm -rf ${CEPH_WORK_DIR}
  git clone https://github.com/cgruver/lab-ceph.git ${CEPH_WORK_DIR}

  export CEPH_CSI_VER=$(yq e ".cephcsi" ${CEPH_WORK_DIR}/install/versions.yaml)
  export CSI_NODE_DRIVER_REG_VER=$(yq e ".csi-node-driver-registrar" ${CEPH_WORK_DIR}/install/versions.yaml)
  export CSI_RESIZER_VER=$(yq e ".csi-resizer" ${CEPH_WORK_DIR}/install/versions.yaml)
  export CSI_PROVISIONER_VER=$(yq e ".csi-provisioner" ${CEPH_WORK_DIR}/install/versions.yaml)
  export CSI_SNAPSHOTTER_VER=$(yq e ".csi-snapshotter" ${CEPH_WORK_DIR}/install/versions.yaml)
  export CSI_ATTACHER_VER=$(yq e ".csi-attacher" ${CEPH_WORK_DIR}/install/versions.yaml)
  export ROOK_CEPH_VER=$(yq e ".rook-ceph" ${CEPH_WORK_DIR}/install/versions.yaml)
  export CEPH_VER=$(yq e ".ceph" ${CEPH_WORK_DIR}/install/versions.yaml)

  for j in "$@"
  do
    case $j in
      -m)
        mirrorCeph
      ;;
      -i)     
        installCeph
      ;;
      -c)
        createCephCluster
      ;;
      -r)
        regPvc
      ;;
      *)
        # catch all
      ;;
    esac
  done
}

function postInstall() {
    for j in "$@"
  do
    case $j in
      -d)
        ${OC} patch ClusterVersion version --type merge -p '{"spec":{"channel":""}}'
        ${OC} patch configs.samples.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Removed"}}'
        ${OC} patch OperatorHub cluster --type json -p '[{"op": "replace", "path": "/spec/sources", "value": []}]'
        ${OC} patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'
      ;;
      *)
        # catch all
      ;;
    esac
  done
  ${OC} patch imagepruners.imageregistry.operator.openshift.io/cluster --type merge -p '{"spec":{"schedule":"0 0 * * *","suspend":false,"keepTagRevisions":3,"keepYoungerThan":60,"resources":{},"affinity":{},"nodeSelector":{},"tolerations":[],"startingDeadlineSeconds":60,"successfulJobsHistoryLimit":3,"failedJobsHistoryLimit":3}}'
  ${OC} delete pod --field-selector=status.phase==Succeeded --all-namespaces
  ${OC} patch OperatorHub cluster --type json -p '[{"op": "replace", "path": "/spec/sources", "value": [{"disabled":true,"name":"certified-operators"},{"disabled":true,"name":"redhat-marketplace"},{"disabled":true,"name":"redhat-operators"}]}]'
}

function getNodes() {

  for j in "$@"
  do
    case $j in
      -cp)
        YQ_PATH="control-plane.okd-hosts"
        let NODE_COUNT=$(yq e ".control-plane.okd-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
      ;;
      -cn)
        YQ_PATH="compute-nodes"
        let NODE_COUNT=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
      ;;
    esac
  done
  
  let node_index=0
  while [[ node_index -lt ${NODE_COUNT} ]]
  do
    node_name=$(yq e ".${YQ_PATH}.[${node_index}].name" ${CLUSTER_CONFIG}).${DOMAIN}
    echo ${node_name}
    node_index=$(( ${node_index} + 1 ))
  done

}

