function startWorker() {

  STAGGER="false"

  for i in "$@"
  do
    case $i in
      -s)
        STAGGER="true"
      ;;
    esac
  done

  let node_count=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    host_name=$(yq e ".compute-nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    if [[ $(yq e ".compute-nodes.[${node_index}].metal" ${CLUSTER_CONFIG}) == "true" ]]
    then
      local mac=$(yq e ".compute-nodes.[${node_index}].mac-addr" ${CLUSTER_CONFIG})
      startMetal ${mac}
    else
      kvm_host=$(yq e ".compute-nodes.[${node_index}].kvm-host" ${CLUSTER_CONFIG})  
      startNode ${kvm_host}.${DOMAIN} ${host_name}
    fi
    if [[ ${node_index} -gt 0 ]] && [[ ${STAGGER} == "true" ]]
    then
      pause 30 "Pause to stagger node start up"
    fi
    node_index=$(( ${node_index} + 1 ))
  done
}

function stopWorkers() {
  
  let node_count=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)

  # Cordon Compute Nodes
  cordonNode

  CEPH_PDB="false"
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    node_index=$(( ${node_index} + 1 ))
    if [[ $(yq ".compute-nodes.[${node_index}] | has(\"ceph\")" ${CLUSTER_CONFIG}) == "true" ]]
    then
      CEPH_PDB="true"
    fi
  done
  if [[ ${CEPH_PDB} == "true" ]]
  then
    ${OC} scale deployment rook-ceph-operator -n rook-ceph --replicas=0
    ${OC} patch pdb rook-ceph-mgr-pdb -n rook-ceph --type=merge -p '{"spec":{"maxUnavailable":"100%"}}'
    ${OC} patch pdb rook-ceph-mon-pdb -n rook-ceph --type=merge -p '{"spec":{"maxUnavailable":"100%"}}'
    ${OC} patch pdb rook-ceph-osd -n rook-ceph --type=merge -p '{"spec":{"maxUnavailable":"100%"}}'
  fi
  # Drain & Shutdown Compute Nodes
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    host_name=$(yq e ".compute-nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    ${OC} adm drain ${host_name} --ignore-daemonsets --force --grace-period=20 --delete-emptydir-data
    ${SSH} -o ConnectTimeout=5 core@${host_name}.${DOMAIN} "sudo systemctl poweroff"
    node_index=$(( ${node_index} + 1 ))
  done
}

function deleteWorker() {
  local index=${1}
  local p_cmd=${2}

  host_name=$(yq e ".compute-nodes.[${index}].name" ${CLUSTER_CONFIG})
  mac_addr=$(yq e ".control-plane.nodes.[${index}].mac-addr" ${CLUSTER_CONFIG})
  if [[ $(yq e ".compute-nodes.[${index}].metal" ${CLUSTER_CONFIG})  == "true" ]]
  then
    boot_dev=$(yq e ".compute-nodes.[${index}].boot-dev" ${CLUSTER_CONFIG})
    ceph_dev=$(yq e ".compute-nodes.[${index}].ceph.ceph-dev" ${CLUSTER_CONFIG})
    destroyMetal core ${host_name} ${boot_dev} "${ceph_dev}" ${p_cmd}
  else
    kvm_host=$(yq e ".compute-nodes.[${index}].kvm-host" ${CLUSTER_CONFIG})
    deleteNodeVm ${host_name} ${kvm_host}.${DOMAIN}
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
    ${OC} adm cordon ${host_name}
    node_index=$(( ${node_index} + 1 ))
  done
}

function unCordonNode() {
  
  let node_count=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    host_name=$(yq e ".compute-nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    ${OC} adm uncordon ${host_name}
    node_index=$(( ${node_index} + 1 ))
  done
  CEPH_PDB="false"
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    node_index=$(( ${node_index} + 1 ))
    if [[ $(yq ".compute-nodes.[${node_index}] | has(\"ceph\")" ${CLUSTER_CONFIG}) == "true" ]]
    then
      CEPH_PDB="true"
    fi
  done
  if [[ ${CEPH_PDB} == "true" ]]
  then
    ${OC} scale deployment rook-ceph-operator -n rook-ceph --replicas=1
    ${OC} patch pdb rook-ceph-mgr-pdb -n rook-ceph --type=merge -p '{"spec":{"maxUnavailable":1}}'
    ${OC} patch pdb rook-ceph-mon-pdb -n rook-ceph --type=merge -p '{"spec":{"maxUnavailable":1}}'
    ${OC} patch pdb rook-ceph-osd -n rook-ceph --type=merge -p '{"spec":{"maxUnavailable":1}}'
  fi
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
  PWD_WORK_DIR=$(mktemp -d)
  PASSWD_FILE=${PWD_WORK_DIR}/htpasswd
  if [[ ${OAUTH_INIT} == "true" ]]
  then
    touch ${PASSWD_FILE}
  else
    ${OC} get secret openshift-htpasswd-secret -n openshift-config -o jsonpath='{.data.htpasswd}' | base64 -d > ${PASSWD_FILE}
  fi
  if [[ -z ${USER} ]]
  then
    echo "Usage: labcli --user [ -a | --admin ] -u=user-name-to-add"
    exit 1
  fi
  htpasswd -B ${PASSWD_FILE} ${USER}
  ${OC} create -n openshift-config secret generic openshift-htpasswd-secret --from-file=htpasswd=${PASSWD_FILE} -o yaml --dry-run='client' | ${OC} apply -f -
  if [[ ${ADMIN_USER} == "true" ]]
  then
    ${OC} adm policy add-cluster-role-to-user cluster-admin ${USER}
  fi
  if [[ ${OAUTH_INIT} == "true" ]]
  then
    ${OC} patch oauth cluster --type merge --patch '{"spec":{"identityProviders":[{"name":"openshift_htpasswd_idp","mappingMethod":"claim","type":"HTPasswd","htpasswd":{"fileData":{"name":"openshift-htpasswd-secret"}}}]}}'
    ${OC} delete secrets kubeadmin -n kube-system
  fi
  rm -rf ${PWD_WORK_DIR}
}

function setKubeConfig() {
  export KUBECONFIG=${KUBE_INIT_CONFIG}
}

function approveCsr() {
    ${OC} get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs ${OC} adm certificate approve
}

function pullSecret() {

  if [[ ! -d ${OPENSHIFT_LAB_PATH}/pull-secrets ]]
  then
    mkdir -p ${OPENSHIFT_LAB_PATH}/pull-secrets
  fi
  if [[ ${DISCONNECTED_CLUSTER} == "true" ]]
  then
    createPullSecret
  else
    release_type=$(yq e ".cluster.release-type" ${CLUSTER_CONFIG})
    if [[ ${release_type} == "ocp" ]]
    then
      cp ${OPENSHIFT_LAB_PATH}/lab-config/ocp-pull-secret ${PULL_SECRET}
    else
      echo -n "{\"auths\": {\"fake\": {\"auth\": \"Zm9vOmJhcgo=\"}}}" > ${PULL_SECRET}
    fi
  fi
}

function createPullSecret() {
  NEXUS_PWD="hello"
  NEXUS_PWD_CHK="goodbye"
  echo "Enter the Nexus user for the pull secret:"
  read NEXUS_USER
  while [[ ${NEXUS_PWD} != ${NEXUS_PWD_CHK} ]]
  do
    echo "Enter the password for the pull secret:"
    read -s NEXUS_PWD
    echo "Re-Enter the password for the pull secret:"
    read -s NEXUS_PWD_CHK
    if [[ ${NEXUS_PWD} != ${NEXUS_PWD_CHK} ]]
    then
      echo "Passwords do not match. Try Again."
    fi
  done
  NEXUS_SECRET=$(echo -n "${NEXUS_USER}:${NEXUS_PWD}" | base64)
  release_type=$(yq e ".cluster.release-type" ${CLUSTER_CONFIG})
  if [[ ${release_type} == "ocp" ]]
  then
    cat ${OPENSHIFT_LAB_PATH}/lab-config/ocp-pull-secret | jq -c .auths | yq -p=json > ${PULL_SECRET}.yaml
  else
    echo "{\"fake\": {\"auth\": \"Zm9vOmJhcgo=\"}" | yq -p=json > ${PULL_SECRET}.yaml
  fi
  echo -n "{\"nexus.${LAB_DOMAIN}:5000\": {\"auth\": \"${NEXUS_SECRET}\"}}" | yq -p=json >> ${PULL_SECRET}.yaml
  echo -n "{\"auths\": $(cat ${PULL_SECRET}.yaml | yq -o=json)}" > ${PULL_SECRET}
  # cat ${PULL_SECRET}.yaml | yq -o=json > ${PULL_SECRET}
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

function getButaneRelease() {

  BUTANE_VERSION=$(basename $(curl -Ls -o /dev/null -w %{url_effective} https://github.com/coreos/butane/releases/latest))
  echo "Butane Release: ${BUTANE_VERSION}"
  yq e ".cluster.butane-version = \"${BUTANE_VERSION}\"" -i ${CLUSTER_CONFIG}
  setButaneRelease
}

function ocLogin() {

  USER=admin
  
  for i in "$@"
  do
    case $i in
      -u=*)
        USER="${i#*=}"
      ;;
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
      oc login -u ${USER} https://api.${CLUSTER_NAME}.${DOMAIN}:6443
      DOMAIN_INDEX=$(( ${DOMAIN_INDEX} + 1 ))
    done
  else
    oc login -u ${USER} https://api.${CLUSTER_NAME}.${DOMAIN}:6443
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
      open -a Safari https://console-openshift-console.apps.${CLUSTER_NAME}.${DOMAIN}
      DOMAIN_INDEX=$(( ${DOMAIN_INDEX} + 1 ))
    done
  else
    open -a Safari https://console-openshift-console.apps.${CLUSTER_NAME}.${DOMAIN}
  fi
}

function configInfraNodes() {
  
  for node_index in 0 1 2
  do
    ${OC} label nodes ${CLUSTER_NAME}-cp-${node_index} node-role.kubernetes.io/infra=""
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
  rm -rf ${OPENSHIFT_LAB_PATH}/lab-config/work-dir
  mkdir -p ${OPENSHIFT_LAB_PATH}/lab-config/work-dir
  mkdir -p ${OPENSHIFT_LAB_PATH}/lab-config/release-sigs
  oc adm -a ${PULL_SECRET} release mirror --from=${OPENSHIFT_REGISTRY}:${OPENSHIFT_RELEASE} --to=${LOCAL_REGISTRY}/openshift --to-release-image=${LOCAL_REGISTRY}/openshift:${OPENSHIFT_RELEASE} --release-image-signature-to-dir=${OPENSHIFT_LAB_PATH}/lab-config/work-dir

  SIG_FILE=$(ls ${OPENSHIFT_LAB_PATH}/lab-config/work-dir)
  mv ${OPENSHIFT_LAB_PATH}/lab-config/work-dir/${SIG_FILE} ${OPENSHIFT_LAB_PATH}/lab-config/release-sigs/${OPENSHIFT_RELEASE}-sig.yaml
  rm -rf ${OPENSHIFT_LAB_PATH}/lab-config/work-dir
}

function startNode() {
  local kvm_host=${1}
  local host_name=${2}
  ${SSH} root@${kvm_host} "virsh start ${host_name}"
}

function startMetal() {
  local mac=${1}
  ${SSH} root@${DOMAIN_ROUTER} "etherwake -i br-lan ${mac}"
}

function startBootstrap() {
  host_name="$(yq e ".cluster.name" ${CLUSTER_CONFIG})-bootstrap"

  if [[ $(yq e ".bootstrap.metal" ${CLUSTER_CONFIG}) == "true" ]]
  then
    memory=$(yq e ".bootstrap.node-spec.memory" ${CLUSTER_CONFIG})
    cpu=$(yq e ".bootstrap.node-spec.cpu" ${CLUSTER_CONFIG})
    root_vol=$(yq e ".bootstrap.node-spec.root-vol" ${CLUSTER_CONFIG})
    bridge_dev=$(yq e ".bootstrap.bridge-dev" ${CLUSTER_CONFIG})
    WORK_DIR=${OPENSHIFT_LAB_PATH}/${CLUSTER_NAME}.${DOMAIN}
    mkdir -p ${WORK_DIR}/bootstrap
    qemu-img create -f qcow2 ${WORK_DIR}/bootstrap/bootstrap-node.qcow2 ${root_vol}G
    qemu-system-x86_64 -accel accel=hvf -m ${memory}M -smp ${cpu} -display none -nographic -drive file=${WORK_DIR}/bootstrap/bootstrap-node.qcow2,if=none,id=disk1  -device ide-hd,bus=ide.0,drive=disk1,id=sata0-0-0,bootindex=1 -boot n -netdev vde,id=nic0,sock=/var/run/vde.bridged.${bridge_dev}.ctl -device virtio-net-pci,netdev=nic0,mac=52:54:00:a1:b2:c3
  else
    kvm_host=$(yq e ".bootstrap.kvm-host" ${CLUSTER_CONFIG})
    startNode ${kvm_host}.${BOOTSTRAP_KVM_DOMAIN} ${host_name}
  fi
}

function startControlPlane() {

  STAGGER="false"

  for i in "$@"
  do
    case $i in
      -s)
        STAGGER="true"
      ;;
    esac
  done

  if [[ $(yq e ".control-plane.metal" ${CLUSTER_CONFIG}) == "true" ]]
  then
    if [[ $(yq e ".control-plane.nodes" ${CLUSTER_CONFIG} | yq e 'length' -) == "1" ]]
    then
      local mac=$(yq e ".control-plane.nodes.[0].mac-addr" ${CLUSTER_CONFIG})
      startMetal ${mac}
    else
      for node_index in 0 1 2
      do
        if [[ ${node_index} -gt 0 ]] && [[ ${STAGGER} == "true" ]]
        then
          pause 30 "Pause to stagger node start up"
        fi
        local mac=$(yq e ".control-plane.nodes.[${node_index}].mac-addr" ${CLUSTER_CONFIG})
        startMetal ${mac}
      done
    fi
  elif [[ $(yq e ".control-plane.nodes" ${CLUSTER_CONFIG} | yq e 'length' -) == "1" ]]
  then
    kvm_host=$(yq e ".control-plane.nodes.[0].kvm-host" ${CLUSTER_CONFIG})
    host_name=$(yq e ".control-plane.nodes.[0].name" ${CLUSTER_CONFIG})
    startNode ${kvm_host}.${DOMAIN} ${host_name}
  else
    for node_index in 0 1 2
    do
      if [[ ${node_index} -gt 0 ]]
      then
        pause 30 "Pause to stagger node start up"
      fi
      kvm_host=$(yq e ".control-plane.nodes.[${node_index}].kvm-host" ${CLUSTER_CONFIG})
      host_name=$(yq e ".control-plane.nodes.[${node_index}].name" ${CLUSTER_CONFIG})
      startNode ${kvm_host}.${DOMAIN} ${host_name}
    done
  fi
}

function stopControlPlane() {
  let node_count=$(yq e ".control-plane.nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ ${node_index} -lt ${node_count} ]]
  do
    host_name=$(yq e ".control-plane.nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    ${SSH} -o ConnectTimeout=5 core@${host_name}.${DOMAIN} "sudo systemctl poweroff"
    node_index=$(( ${node_index} + 1 ))
  done
}

function start() {
  for i in "$@"
  do
    case $i in
      -b)
        startBootstrap
      ;;
      -c)
        startControlPlane "$@"
        startWorker "$@"
      ;;
      -m)
        startControlPlane "$@"
      ;;
      -w)
        startWorker "$@"
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
        openshift-install agent wait-for bootstrap-complete --dir=${OPENSHIFT_LAB_PATH}/${CLUSTER_NAME}.${DOMAIN}/openshift-install-dir --log-level debug
      ;;
      -i)
        openshift-install agent wait-for install-complete --dir=${OPENSHIFT_LAB_PATH}/${CLUSTER_NAME}.${DOMAIN}/openshift-install-dir --log-level debug
      ;;
      -m=*)
        CP_INDEX="${i#*=}"
        host_name=$(yq e ".control-plane.nodes.[${CP_INDEX}].name" ${CLUSTER_CONFIG})
        ${SSH} core@${host_name}.${DOMAIN} "journalctl -b -f"
      ;;
      -w=*)
        W_INDEX="${i#*=}"
        host_name=$(yq e ".compute-nodes.[${W_INDEX}].name" ${CLUSTER_CONFIG})
        ${SSH} core@${host_name}.${DOMAIN} "journalctl -b -f"
      ;;
      -s)
        host_name=$(yq e ".control-plane.nodes.[0].name" ${CLUSTER_CONFIG})
        ${SSH} core@${host_name}.${DOMAIN} "journalctl -b -f -u release-image.service -u release-image-pivot.service"
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
  podman pull --arch=amd64 quay.io/cephcsi/cephcsi:${CEPH_CSI_VER}
  podman pull --arch=amd64 registry.k8s.io/sig-storage/csi-node-driver-registrar:${CSI_NODE_DRIVER_REG_VER}
  podman pull --arch=amd64 registry.k8s.io/sig-storage/csi-resizer:${CSI_RESIZER_VER}
  podman pull --arch=amd64 registry.k8s.io/sig-storage/csi-provisioner:${CSI_PROVISIONER_VER}
  podman pull --arch=amd64 registry.k8s.io/sig-storage/csi-snapshotter:${CSI_SNAPSHOTTER_VER}
  podman pull --arch=amd64 registry.k8s.io/sig-storage/csi-attacher:${CSI_ATTACHER_VER}
  podman pull --arch=amd64 docker.io/rook/ceph:${ROOK_CEPH_VER}
  podman pull --arch=amd64 quay.io/ceph/ceph:${CEPH_VER}

  echo "Tagging Rook/Ceph Images..."
  podman tag quay.io/cephcsi/cephcsi:${CEPH_CSI_VER} ${LOCAL_REGISTRY}/cephcsi/cephcsi:${CEPH_CSI_VER}
  podman tag registry.k8s.io/sig-storage/csi-node-driver-registrar:${CSI_NODE_DRIVER_REG_VER} ${LOCAL_REGISTRY}/sig-storage/csi-node-driver-registrar:${CSI_NODE_DRIVER_REG_VER}
  podman tag registry.k8s.io/sig-storage/csi-resizer:${CSI_RESIZER_VER} ${LOCAL_REGISTRY}/sig-storage/csi-resizer:${CSI_RESIZER_VER}
  podman tag registry.k8s.io/sig-storage/csi-provisioner:${CSI_PROVISIONER_VER} ${LOCAL_REGISTRY}/sig-storage/csi-provisioner:${CSI_PROVISIONER_VER}
  podman tag registry.k8s.io/sig-storage/csi-snapshotter:${CSI_SNAPSHOTTER_VER} ${LOCAL_REGISTRY}/sig-storage/csi-snapshotter:${CSI_SNAPSHOTTER_VER}
  podman tag registry.k8s.io/sig-storage/csi-attacher:${CSI_ATTACHER_VER} ${LOCAL_REGISTRY}/sig-storage/csi-attacher:${CSI_ATTACHER_VER}
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
  envsubst < ${CEPH_OPERATOR_FILE} | ${OC} apply -f -
}

function createCephCluster() {

  if [[ $(yq ". | has(\"compute-nodes\")" ${CLUSTER_CONFIG}) == "true" ]]
  then
    createWorkerCephCluster
  else
    createControlPlaneCephCluster
  fi
  envsubst < ${CEPH_CLUSTER_FILE} | ${OC} apply -f -
  ${OC} patch configmap rook-ceph-operator-config -n rook-ceph --type merge --patch '"data": {"CSI_PLUGIN_TOLERATIONS": "- key: \"node-role.kubernetes.io/master\"\n  operator: \"Exists\"\n  effect: \"NoSchedule\"\n"}'
  ${OC} apply -f ${CEPH_WORK_DIR}/configure/ceph-storage-class.yaml
}

function createControlPlaneCephCluster() {
  for node_index in 0 1 2
  do
    node_name=$(yq e ".control-plane.nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    ceph_dev=$(yq e ".control-plane.ceph.ceph-dev" ${CLUSTER_CONFIG})
    yq e ".spec.storage.nodes.[${node_index}].name = \"${node_name}\"" -i ${CEPH_CLUSTER_FILE}
    yq e ".spec.storage.nodes.[${node_index}].devices.[0].name = \"${ceph_dev}\"" -i ${CEPH_CLUSTER_FILE}
    yq e ".spec.storage.nodes.[${node_index}].devices.[0].config.osdsPerDevice = \"1\"" -i ${CEPH_CLUSTER_FILE}
    ${SSH} -o ConnectTimeout=5 core@${node_name}.${DOMAIN} "sudo wipefs -a -f ${ceph_dev} && sudo dd if=/dev/zero of=${ceph_dev} bs=4096 count=100"
    ${OC} label nodes ${node_name} role=storage-node
  done
}

function createWorkerCephCluster() {
  let NODE_COUNT=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${NODE_COUNT} ]]
  do
    node_name=$(yq e ".compute-nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    ceph_node=$(yq ".compute-nodes.[${node_index}] | has(\"ceph\")" ${CLUSTER_CONFIG})
    if [[ ${ceph_node} == "true" ]]
    then
      ceph_dev=$(yq e ".compute-nodes.[${node_index}].ceph.ceph-dev" ${CLUSTER_CONFIG})
      yq e ".spec.storage.nodes.[${node_index}].name = \"${node_name}\"" -i ${CEPH_CLUSTER_FILE}
      yq e ".spec.storage.nodes.[${node_index}].devices.[0].name = \"${ceph_dev}\"" -i ${CEPH_CLUSTER_FILE}
      yq e ".spec.storage.nodes.[${node_index}].devices.[0].config.osdsPerDevice = \"1\"" -i ${CEPH_CLUSTER_FILE}
      ${SSH} -o ConnectTimeout=5 core@${node_name}.${DOMAIN} "sudo wipefs -a -f ${ceph_dev} && sudo dd if=/dev/zero of=${ceph_dev} bs=4096 count=100"
    fi
    node_index=$(( ${node_index} + 1 ))
    ${OC} label nodes ${node_name} role=storage-node
  done
}

function regPvc() {
  ${OC} apply -f ${CEPH_WORK_DIR}/configure/registry-pvc.yaml
  ${OC} patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"rolloutStrategy":"Recreate","managementState":"Managed","storage":{"pvc":{"claim":"registry-pvc"}}}}'
}

function initCephVars() {
  export CEPH_WORK_DIR=${OPENSHIFT_LAB_PATH}/${CLUSTER_NAME}.${DOMAIN}/ceph-work-dir
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

  if [[ ${DISCONNECTED_CLUSTER} == "true" ]]
  then
    CEPH_OPERATOR_FILE=${CEPH_WORK_DIR}/install/operator-openshift.yaml
    CEPH_CLUSTER_FILE=${CEPH_WORK_DIR}/install/cluster.yaml
  else
    CEPH_OPERATOR_FILE=${CEPH_WORK_DIR}/install/operator-openshift-no-pi.yaml
    CEPH_CLUSTER_FILE=${CEPH_WORK_DIR}/install/cluster-no-pi.yaml
  fi

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

  ${OC} patch imagepruners.imageregistry.operator.openshift.io/cluster --type merge -p '{"spec":{"schedule":"0 0 * * *","suspend":false,"keepTagRevisions":3,"keepYoungerThan":60,"resources":{},"affinity":{},"nodeSelector":{},"tolerations":[],"startingDeadlineSeconds":60,"successfulJobsHistoryLimit":3,"failedJobsHistoryLimit":3}}'
  ${OC} delete pod --field-selector=status.phase==Succeeded --all-namespaces
  ${OC} delete pod --field-selector=status.phase==Failed --all-namespaces
  if [[ $(yq e ".cluster.release-type" ${CLUSTER_CONFIG}) != "ocp" ]]
  then
    ${OC} patch OperatorHub cluster --type json -p '[{"op": "replace", "path": "/spec/sources", "value": [{"disabled":true,"name":"certified-operators"},{"disabled":true,"name":"redhat-marketplace"},{"disabled":true,"name":"redhat-operators"}]}]'
    ${OC} patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": false}]'
  fi
  for j in "$@"
  do
    case $j in
      -d)
        ${OC} patch ClusterVersion version --type merge -p '{"spec":{"channel":""}}'
        ${OC} patch configs.samples.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Removed"}}'
        # ${OC} patch OperatorHub cluster --type json -p '[{"op": "replace", "path": "/spec/sources", "value": []}]'
        ${OC} patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'
      ;;
      *)
        # catch all
      ;;
    esac
  done
}

function getNodes() {

  for j in "$@"
  do
    case $j in
      -cp)
        YQ_PATH="control-plane.nodes"
        let NODE_COUNT=$(yq e ".control-plane.nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
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

function deploySnoHostPath() {

local CERT_MGR_VER=$(basename $(curl -Ls -o /dev/null -w %{url_effective} https://github.com/cert-manager/cert-manager/releases/latest))
local HPP_VER=$(basename $(curl -Ls -o /dev/null -w %{url_effective} https://github.com/kubevirt/hostpath-provisioner-operator/releases/latest))

${OC} create -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MGR_VER}/cert-manager.yaml
${OC} wait --for=condition=Available -n cert-manager --timeout=300s --all deployments
${OC} create -f https://github.com/kubevirt/hostpath-provisioner-operator/releases/download/${HPP_VER}/namespace.yaml
${OC} create -f https://github.com/kubevirt/hostpath-provisioner-operator/releases/download/${HPP_VER}/webhook.yaml -n hostpath-provisioner
${OC} create -f https://github.com/kubevirt/hostpath-provisioner-operator/releases/download/${HPP_VER}/operator.yaml -n hostpath-provisioner
${OC} wait --for=condition=Available -n hostpath-provisioner --timeout=300s --all deployments

cat << EOF | ${OC} apply -f -
apiVersion: hostpathprovisioner.kubevirt.io/v1beta1
kind: HostPathProvisioner
metadata:
  name: hostpath-provisioner
spec:
  imagePullPolicy: Always
  storagePools:
    - name: "local"
      path: "/var/hostpath"
  workload:
    nodeSelector:
      kubernetes.io/os: linux
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: hostpath-csi
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubevirt.io.hostpath-provisioner
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
parameters:
  storagePool: local
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-pvc
  namespace: openshift-image-registry
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
  storageClassName: hostpath-csi
EOF

${OC} patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"rolloutStrategy":"Recreate","managementState":"Managed","storage":{"pvc":{"claim":"registry-pvc"}}}}'

}

# function deployGitOps() {
#   ${OC} create ns openshift-gitops-operator
#   ${OC} label namespace openshift-gitops-operator openshift.io/cluster-monitoring=true

# cat << EOF | ${OC} apply -f -
# apiVersion: operators.coreos.com/v1
# kind: OperatorGroup
# metadata:
#   name: openshift-gitops-operator
#   namespace: openshift-gitops-operator
# spec:
#   upgradeStrategy: Default
# EOF

# cat << EOF | ${OC} apply -f -
# apiVersion: operators.coreos.com/v1alpha1
# kind: Subscription
# metadata:
#   name: openshift-gitops-operator
#   namespace: openshift-gitops-operator
# spec:
#   channel: latest 
#   installPlanApproval: Manual
#   name: openshift-gitops-operator 
#   source: redhat-operators 
#   sourceNamespace: openshift-marketplace 
# EOF

# }