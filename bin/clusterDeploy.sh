function createInstallConfig() {

  if [[ ! -f  ${PULL_SECRET} ]]
  then
    pullSecret
  fi

  PULL_SECRET_TXT=$(cat ${PULL_SECRET})

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
  machineNetwork:
  - cidr: 10.11.12.0/24
compute:
- name: worker
  replicas: 0
  hyperthreading: Enabled
controlPlane:
  name: master
  replicas: ${CP_REPLICAS}
  hyperthreading: Enabled
platform:
  none: {}
pullSecret: '${PULL_SECRET_TXT}'
sshKey: ${SSH_KEY}
EOF

if [[ ${TPNU} == "true" ]]
then
  yq -i '.featureSet = "TechPreviewNoUpgrade" | .osImageStream = "rhel-10"' ${WORK_DIR}/install-config-upi.yaml
fi
}

function createClusterConfig() {

  mkdir ${WORK_DIR}/openshift-install-dir/openshift
  createClusterCustomMC
  if [[ $(yq ".control-plane | has(\"ceph\")" ${CLUSTER_CONFIG}) == "true" ]]
  then
    if [[ $(yq e ".control-plane.ceph.type" ${CLUSTER_CONFIG}) == "part"  ]]
    then
      createClusterCephMC
    fi
  elif [[ $(yq ".control-plane | has(\"hostpath-dev\")" ${CLUSTER_CONFIG}) == "true" ]]
  then
    createHostPathMC
  fi

  yq e ".apiVersion = \"v1alpha1\"" -n > ${WORK_DIR}/agent-config.yaml
  yq e ".kind = \"AgentConfig\"" -i ${WORK_DIR}/agent-config.yaml
  yq e ".metadata.name = \"${CLUSTER_NAME}\"" -i ${WORK_DIR}/agent-config.yaml
  yq e ".rendezvousIP = \"$(yq e ".control-plane.nodes.[0].ip-addr" ${CLUSTER_CONFIG})\"" -i ${WORK_DIR}/agent-config.yaml

  node_boot_dev=$(yq e ".control-plane.boot-dev" ${CLUSTER_CONFIG})
  let node_count=$(yq e ".control-plane.nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    node_name=${CLUSTER_NAME}-cp-${node_index}
    node_mac=$(yq e ".control-plane.nodes.[${node_index}].mac-addr" ${CLUSTER_CONFIG})
    node_ip=$(yq e ".control-plane.nodes.[${node_index}].ip-addr" ${CLUSTER_CONFIG})
    yq e ".hosts.[${node_index}].hostname = \"${node_name}\"" -i ${WORK_DIR}/agent-config.yaml
    yq e ".hosts.[${node_index}].role = \"master\"" -i ${WORK_DIR}/agent-config.yaml
    yq e ".hosts.[${node_index}].rootDeviceHints.deviceName = \"${node_boot_dev}\"" -i ${WORK_DIR}/agent-config.yaml
    yq e ".hosts.[${node_index}].interfaces.[0].name = \"nic0\"" -i ${WORK_DIR}/agent-config.yaml
    yq e ".hosts.[${node_index}].interfaces.[0].macAddress = \"${node_mac}\"" -i ${WORK_DIR}/agent-config.yaml
    yq e ".hosts.[${node_index}].networkConfig.interfaces.[0].name = \"nic0\"" -i ${WORK_DIR}/agent-config.yaml
    yq e ".hosts.[${node_index}].networkConfig.interfaces.[0].type = \"ethernet\"" -i ${WORK_DIR}/agent-config.yaml
    yq e ".hosts.[${node_index}].networkConfig.interfaces.[0].state = \"up\"" -i ${WORK_DIR}/agent-config.yaml
    yq e ".hosts.[${node_index}].networkConfig.interfaces.[0].mac-address = \"${node_mac}\"" -i ${WORK_DIR}/agent-config.yaml
    yq e ".hosts.[${node_index}].networkConfig.interfaces.[0].ipv4.enabled = true" -i ${WORK_DIR}/agent-config.yaml
    yq e ".hosts.[${node_index}].networkConfig.interfaces.[0].ipv4.address.[0].ip = \"${node_ip}\"" -i ${WORK_DIR}/agent-config.yaml
    yq e ".hosts.[${node_index}].networkConfig.interfaces.[0].ipv4.address.[0].prefix-length = 24" -i ${WORK_DIR}/agent-config.yaml
    yq e ".hosts.[${node_index}].networkConfig.interfaces.[0].ipv4.dhcp = false" -i ${WORK_DIR}/agent-config.yaml
    yq e ".hosts.[${node_index}].networkConfig.interfaces.[0].ipv6.enabled = false" -i ${WORK_DIR}/agent-config.yaml
    yq e ".hosts.[${node_index}].networkConfig.dns-resolver.config.server.[0] = \"${DOMAIN_ROUTER}\"" -i ${WORK_DIR}/agent-config.yaml
    yq e ".hosts.[${node_index}].networkConfig.routes.config.[0].destination = \"0.0.0.0/0\"" -i ${WORK_DIR}/agent-config.yaml
    yq e ".hosts.[${node_index}].networkConfig.routes.config.[0].next-hop-address = \"${DOMAIN_ROUTER}\"" -i ${WORK_DIR}/agent-config.yaml
    yq e ".hosts.[${node_index}].networkConfig.routes.config.[0].next-hop-interface = \"nic0\"" -i ${WORK_DIR}/agent-config.yaml
    yq e ".hosts.[${node_index}].networkConfig.routes.config.[0].table-id = 254" -i ${WORK_DIR}/agent-config.yaml
    node_index=$(( ${node_index} + 1 ))
  done
  cp ${WORK_DIR}/agent-config.yaml ${WORK_DIR}/openshift-install-dir/agent-config.yaml
}

function appendDisconnectedInstallConfig() {

  release_type=$(yq e ".cluster.release-type" ${CLUSTER_CONFIG})
    if [[ ${release_type} == "ocp" ]]
    then
      source_1="quay.io/openshift-release-dev/ocp-release"
      source_2="quay.io/openshift-release-dev/ocp-v4.0-art-dev"
    else
      source_1="quay.io/openshift/okd"
      source_2="quay.io/openshift/okd-content"
    fi

  NEXUS_CERT=$( openssl s_client -showcerts -connect ${LOCAL_REGISTRY} </dev/null 2>/dev/null|openssl x509 -outform PEM | while read line ; do echo "  ${line}" ; done )

cat << EOF >> ${WORK_DIR}/install-config-upi.yaml
additionalTrustBundle: |
${NEXUS_CERT}
imageDigestSources:
- mirrors:
  - ${LOCAL_REGISTRY}/openshift
  source: ${source_1}
- mirrors:
  - ${LOCAL_REGISTRY}/openshift
  source: ${source_2}
EOF
}

function createLbConfig() {

  local lb_ip=$(yq e ".cluster.ingress-ip-addr" ${CLUSTER_CONFIG})

  INTERFACE=$(echo "${CLUSTER_NAME//-/_}" | tr "[:upper:]" "[:lower:]")
  ${SSH} root@${DOMAIN_ROUTER} "uci set network.${INTERFACE}_lb=interface ; \
    uci set network.${INTERFACE}_lb.ifname=\"@lan\" ; \
    uci set network.${INTERFACE}_lb.proto=static ; \
    uci set network.${INTERFACE}_lb.hostname=${CLUSTER_NAME}-lb.${DOMAIN} ; \
    uci set network.${INTERFACE}_lb.ipaddr=${lb_ip}/${DOMAIN_NETMASK} ; \
    uci commit ; \
    /etc/init.d/network reload ; \
    sleep 10"

  configNginx ${lb_ip}
  ${SCP} ${WORK_DIR}/nginx-${CLUSTER_NAME}.conf root@${DOMAIN_ROUTER}:/usr/local/nginx/nginx-${CLUSTER_NAME}.conf
  ${SSH} root@${DOMAIN_ROUTER} "/etc/init.d/nginx restart"
}

function configControlPlane() {

  if [[ ${SNO} == "true" ]]
  then
    ingress_ip=$(yq e ".control-plane.nodes.[0].ip-addr" ${CLUSTER_CONFIG})
  else
    createLbConfig
    ingress_ip=$(yq e ".cluster.ingress-ip-addr" ${CLUSTER_CONFIG})
  fi
  echo "*.apps.${CLUSTER_NAME}.${DOMAIN}.     IN      A      ${ingress_ip} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
  echo "api.${CLUSTER_NAME}.${DOMAIN}.        IN      A      ${ingress_ip} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
  echo "api-int.${CLUSTER_NAME}.${DOMAIN}.    IN      A      ${ingress_ip} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
  boot_dev=$(yq e ".control-plane.boot-dev" ${CLUSTER_CONFIG})  
  let node_count=$(yq e ".control-plane.nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    ip_addr=$(yq e ".control-plane.nodes.[${node_index}].ip-addr" ${CLUSTER_CONFIG})
    host_name=${CLUSTER_NAME}-cp-${node_index}
    yq e ".control-plane.nodes.[${node_index}].name = \"${host_name}\"" -i ${CLUSTER_CONFIG}
    mac_addr=$(yq e ".control-plane.nodes.[${node_index}].mac-addr" ${CLUSTER_CONFIG})
    createPxeFile true ${mac_addr} ${boot_dev} ${host_name} ${ip_addr}
    # Create control plane node DNS Records:
    echo "${host_name}.${DOMAIN}.   IN      A      ${ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
    o4=$(echo ${ip_addr} | cut -d"." -f4)
    echo "${o4}    IN      PTR     ${host_name}.${DOMAIN}.  ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/reverse.zone
    node_index=$(( ${node_index} + 1 ))
  done
}

function deployCluster() {

  for i in "$@"
  do
    case $i in
      -i|--iso)
        CREATE_ISO="true"
      ;;
      *)
        # catch all
      ;;
    esac
  done

  WORK_DIR=${OPENSHIFT_LAB_PATH}/${CLUSTER_NAME}.${DOMAIN}
  rm -rf ${WORK_DIR}
  mkdir -p ${WORK_DIR}/ipxe-work-dir/ignition
  mkdir ${WORK_DIR}/dns-work-dir
  mkdir ${WORK_DIR}/openshift-install-dir
  if [[ -d ${OPENSHIFT_LAB_PATH}/lab-config/${CLUSTER_NAME}.${DOMAIN} ]]
  then
    rm -rf ${OPENSHIFT_LAB_PATH}/lab-config/${CLUSTER_NAME}.${DOMAIN}
  fi
  mkdir -p ${OPENSHIFT_LAB_PATH}/lab-config/${CLUSTER_NAME}.${DOMAIN}
  SSH_KEY=$(cat ${OPENSHIFT_LAB_PATH}/ssh_key.pub)
  SNO="false"
  AGENT_INSTALL="true"
  CP_REPLICAS=$(yq e ".control-plane.nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  if [[ ${CP_REPLICAS} == "1" ]]
  then
    SNO="true"
  elif [[ ${CP_REPLICAS} != "3" ]]
  then
    echo "There must be 3 host entries for the control plane for a full cluster, or 1 entry for a Single Node cluster."
    exit 1
  fi
  createInstallConfig
  if [[ ${DISCONNECTED_CLUSTER} == "true" ]]
  then
    appendDisconnectedInstallConfig
  fi
  cp ${WORK_DIR}/install-config-upi.yaml ${WORK_DIR}/openshift-install-dir/install-config.yaml
  createClusterConfig
  if [[ ${CREATE_ISO} == "true" ]]
    then
      openshift-install --dir=${WORK_DIR}/openshift-install-dir agent create image
    else
      openshift-install --dir=${WORK_DIR}/openshift-install-dir agent create pxe-files 
  fi
  configControlPlane
  cp ${WORK_DIR}/openshift-install-dir/auth/kubeconfig ${KUBE_INIT_CONFIG}
  chmod 400 ${KUBE_INIT_CONFIG}
  if [[ ${CREATE_ISO} != "true" ]]
  then
      prepNodeFiles true
  fi
  prepDnsFiles
}

function deployWorkers() {
  WORK_DIR=${OPENSHIFT_LAB_PATH}/${CLUSTER_NAME}.${DOMAIN}
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
    boot_dev=$(yq e ".compute-nodes.[${node_index}].boot-dev" ${CLUSTER_CONFIG})
    # Create the ignition and iPXE boot files
    mac_addr=$(yq e ".compute-nodes.[${node_index}].mac-addr" ${CLUSTER_CONFIG}) 
    config_ceph=false
    if [[ ${ceph_node} == "true" ]]
    then
      ceph_type=$(yq e ".compute-nodes.[${node_index}].ceph.type" ${CLUSTER_CONFIG})
      if [[ ${ceph_type} == "part" ]]
      then
        config_ceph=true
      fi
    fi
    createButaneConfig ${ip_addr} ${host_name} ${mac_addr} worker ${config_ceph} ${boot_dev}
    createPxeFile false ${mac_addr} ${boot_dev} ${host_name} ${ip_addr}
    # Create DNS entries
    echo "${host_name}.${DOMAIN}.   IN      A      ${ip_addr} ; ${host_name}-${DOMAIN}-wk" >> ${WORK_DIR}/dns-work-dir/forward.zone
    o4=$(echo ${ip_addr} | cut -d"." -f4)
    echo "${o4}    IN      PTR     ${host_name}.${DOMAIN}. ; ${host_name}-${DOMAIN}-wk" >> ${WORK_DIR}/dns-work-dir/reverse.zone
    node_index=$(( ${node_index} + 1 ))
  done
  prepNodeFiles false
  prepDnsFiles
}

function createPxeFile() {
  local control_plane=${1}
  local mac=${2}
  local boot_dev=${3}
  local hostname=${4}
  local ip_addr=${5}

if [[ ${control_plane} == "true" ]]
then

cat << EOF > ${WORK_DIR}/ipxe-work-dir/${mac//:/-}.ipxe
#!ipxe

initrd --name initrd http://${INSTALL_HOST_IP}/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/initrd
kernel http://${INSTALL_HOST_IP}/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/vmlinuz logo.nologo ignition.firstboot ignition.platform.id=metal initrd=initrd coreos.live.rootfs_url=http://${INSTALL_HOST_IP}/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/rootfs.img console=tty0

boot
EOF

else

cat << EOF > ${WORK_DIR}/ipxe-work-dir/${mac//:/-}.ipxe
#!ipxe

kernel http://${INSTALL_HOST_IP}/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/vmlinuz logo.nologo edd=off net.ifnames=1 ifname=nic0:${mac} ip=${ip_addr}::${DOMAIN_ROUTER}:${DOMAIN_NETMASK}:${hostname}.${DOMAIN}:nic0:none nameserver=${DOMAIN_ROUTER} rd.neednet=1 coreos.inst.install_dev=${boot_dev} coreos.inst.ignition_url=http://${INSTALL_HOST_IP}/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/${mac//:/-}.ign coreos.inst.platform_id=metal initrd=initrd initrd=rootfs.img console=tty0
initrd http://${INSTALL_HOST_IP}/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/initrd
initrd http://${INSTALL_HOST_IP}/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/rootfs.img

boot
EOF

fi
}

function prepNodeFiles() {
  local control_plane=${1}
  
  ${SSH} root@${INSTALL_HOST_IP} "mkdir -p /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}"
  if [[ ${control_plane} == "true" ]]
  then
    ${SCP} ${WORK_DIR}/openshift-install-dir/boot-artifacts/agent.*-initrd.img root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/initrd
    ${SCP} ${WORK_DIR}/openshift-install-dir/boot-artifacts/agent.*-vmlinuz root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/vmlinuz
    ${SCP} ${WORK_DIR}/openshift-install-dir/boot-artifacts/agent.*-rootfs.img root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/rootfs.img
  else
    ${SCP} -r ${WORK_DIR}/ipxe-work-dir/ignition/*.ign root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/
  fi
  ${SSH} root@${INSTALL_HOST_IP} "chmod 644 /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/*"
  ${SCP} -r ${WORK_DIR}/ipxe-work-dir/*.ipxe root@${DOMAIN_ROUTER}:/usr/local/tftpboot/ipxe/
}

function prepDnsFiles() {
  cat ${WORK_DIR}/dns-work-dir/forward.zone | ${SSH} root@${DOMAIN_ROUTER} "cat >> /usr/local/bind/db.${DOMAIN}"
  cat ${WORK_DIR}/dns-work-dir/reverse.zone | ${SSH} root@${DOMAIN_ROUTER} "cat >> /usr/local/bind/db.${DOMAIN_ARPA}"
  ${SSH} root@${DOMAIN_ROUTER} "/etc/init.d/named stop && sleep 2 && /etc/init.d/named start && sleep 2"
  ${SSH} root@${EDGE_ROUTER_LAN} "/etc/init.d/named stop && sleep 2 && /etc/init.d/named start && sleep 2"
}

function deploySnoHostPath() {

# deployCertManagerOperator

# pause 5 "Wait for Cert Manager"

local HPP_VER=$(basename $(curl -Ls -o /dev/null -w %{url_effective} https://github.com/kubevirt/hostpath-provisioner-operator/releases/latest))

${OC} wait --for=condition=Available -n cert-manager-operator --timeout=300s --all deployments
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

function deployCertManagerOperator() {

cat << EOF | ${OC} apply -f -
apiVersion: v1                      
kind: Namespace                 
metadata:
  name: cert-manager-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
  - cert-manager-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

}

function postInstall() {

  # ${OC} patch imagepruners.imageregistry.operator.openshift.io/cluster --type merge -p '{"spec":{"schedule":"0 0 * * *","suspend":false,"keepTagRevisions":3,"keepYoungerThan":60,"resources":{},"affinity":{},"nodeSelector":{},"tolerations":[],"successfulJobsHistoryLimit":3,"failedJobsHistoryLimit":3}}'
  ${OC} delete pod --field-selector=status.phase==Succeeded --all-namespaces
  ${OC} delete pod --field-selector=status.phase==Failed --all-namespaces
  ${OC} patch olmconfig cluster --type=merge -p '{"spec": {"features": {"disableCopiedCSVs": true}}}'
  ${OC} patch etcd/cluster --type=merge -p '{"spec": {"controlPlaneHardwareSpeed": "Slower"}}'  
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
  #Install GitOps Operator
  #deployGitOps
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
    alertmanagerMain:
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
    prometheusOperator:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Equal"
        value: ""
        effect: "NoSchedule"
    metricsServer:
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
    telemeterClient:
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
    monitoringPlugin:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Equal"
        value: ""
        effect: "NoSchedule"
EOF
}

function mirrorOcpRelease() {
  rm -rf ${OPENSHIFT_LAB_PATH}/lab-config/work-dir
  mkdir -p ${OPENSHIFT_LAB_PATH}/lab-config/work-dir
  mkdir -p ${OPENSHIFT_LAB_PATH}/lab-config/release-sigs
  oc adm -a ${PULL_SECRET} release mirror --from=${OPENSHIFT_REGISTRY}:${OPENSHIFT_RELEASE} --to=${LOCAL_REGISTRY}/openshift --to-release-image=${LOCAL_REGISTRY}/openshift:${OPENSHIFT_RELEASE} --release-image-signature-to-dir=${OPENSHIFT_LAB_PATH}/lab-config/work-dir

  SIG_FILE=$(ls ${OPENSHIFT_LAB_PATH}/lab-config/work-dir)
  mv ${OPENSHIFT_LAB_PATH}/lab-config/work-dir/${SIG_FILE} ${OPENSHIFT_LAB_PATH}/lab-config/release-sigs/${OPENSHIFT_RELEASE}-sig.yaml
  rm -rf ${OPENSHIFT_LAB_PATH}/lab-config/work-dir
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
  echo -n "{\"${LOCAL_REGISTRY}\": {\"auth\": \"${NEXUS_SECRET}\"}}" | yq -p=json >> ${PULL_SECRET}.yaml
  echo -n "{\"auths\": $(cat ${PULL_SECRET}.yaml | yq -o=json | jq -c)}" > ${PULL_SECRET}
  # cat ${PULL_SECRET}.yaml | yq -o=json > ${PULL_SECRET}
  NEXUS_PWD=""
  NEXUS_PWD_CHK=""
}

function deploy() {
  for i in "$@"
  do
    case $i in
      -c|--cluster)
        deployCluster "$@"
      ;;
      -w|--worker)
        deployWorkers
      ;;
      *)
        # catch all
      ;;
    esac
  done
}

