
function deployCluster() {

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
  openshift-install --dir=${WORK_DIR}/openshift-install-dir agent create pxe-files 
  configControlPlane
  cp ${WORK_DIR}/openshift-install-dir/auth/kubeconfig ${KUBE_INIT_CONFIG}
  chmod 400 ${KUBE_INIT_CONFIG}
  copyFiles
}

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

function createClusterConfig() {

  mkdir ${WORK_DIR}/openshift-install-dir/openshift
  createClusterCustomMC
  if [[ $(yq ".control-plane | has(\"hostpath-dev\")" ${CLUSTER_CONFIG}) == "true" ]]
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

function createHostPathMC() {

  local hostpath_dev=$(yq e ".control-plane.hostpath-dev" ${CLUSTER_CONFIG})
  local mc_version="$(getMcVersion)"

cat << EOF | butane > ${WORK_DIR}/98-hostpath-config.yaml
variant: openshift
version: ${mc_version}
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 98-cluster-hostpath-config
storage:
  disks:
  - device: ${hostpath_dev}
    wipe_table: true
  filesystems:
  - device: ${hostpath_dev}
    path: /var/hostpath
    format: ext4
    wipe_filesystem: true
    with_mount_unit: true
EOF
cp ${WORK_DIR}/98-hostpath-config.yaml ${WORK_DIR}/openshift-install-dir/openshift/98-hostpath-config.yaml
}

function createClusterCustomMC() {

local mc_version="$(getMcVersion)"

cat << EOF | butane > ${WORK_DIR}/98-cluster-config.yaml
variant: openshift
version: ${mc_version}
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 98-cluster-config
storage:
  files:
    - path: /etc/chrony.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          pool ${INSTALL_HOST_IP} iburst 
          driftfile /var/lib/chrony/drift
          makestep 1.0 3
          rtcsync
          logdir /var/log/chrony
EOF
cp ${WORK_DIR}/98-cluster-config.yaml ${WORK_DIR}/openshift-install-dir/openshift/98-cluster-config.yaml
}

function configControlPlane() {

  metal=$(yq e ".control-plane.metal" ${CLUSTER_CONFIG})
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
    createPxeFile ${mac_addr} ${boot_dev} ${host_name} ${ip_addr}
    echo "${host_name}.${DOMAIN}.   IN      A      ${ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
    o4=$(echo ${ip_addr} | cut -d"." -f4)
    echo "${o4}    IN      PTR     ${host_name}.${DOMAIN}.  ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/reverse.zone
    node_index=$(( ${node_index} + 1 ))
  done
}

function createPxeFile() {
  local mac=${1}
  local boot_dev=${2}
  local hostname=${3}
  local ip_addr=${4}

cat << EOF > ${WORK_DIR}/ipxe-work-dir/${mac//:/-}.ipxe
#!ipxe

initrd --name initrd http://${INSTALL_HOST_IP}/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/initrd
kernel http://${INSTALL_HOST_IP}/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/vmlinuz ignition.firstboot ignition.platform.id=metal initrd=initrd coreos.live.rootfs_url=http://${INSTALL_HOST_IP}/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/rootfs.img

boot
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

function configNginx() {

  local lb_ip=${1}
  local cp_0=$(yq e ".control-plane.nodes.[0].ip-addr" ${CLUSTER_CONFIG})
  local cp_1=$(yq e ".control-plane.nodes.[1].ip-addr" ${CLUSTER_CONFIG})
  local cp_2=$(yq e ".control-plane.nodes.[2].ip-addr" ${CLUSTER_CONFIG})
  local bs_api=""
  local bs_mc=""
  local bs=""

cat << EOF > ${WORK_DIR}/nginx-${CLUSTER_NAME}.conf
upstream openshift4-api-${CLUSTER_NAME} {
    server ${cp_0}:6443 max_fails=3 fail_timeout=1s;
    server ${cp_1}:6443 max_fails=3 fail_timeout=1s;
    server ${cp_2}:6443 max_fails=3 fail_timeout=1s;
    ${bs_api}
}
upstream openshift4-mc-${CLUSTER_NAME} {
    server ${cp_0}:22623 max_fails=3 fail_timeout=1s;
    server ${cp_1}:22623 max_fails=3 fail_timeout=1s;
    server ${cp_2}:22623 max_fails=3 fail_timeout=1s;
    ${bs_mc}
}
upstream openshift4-https-${CLUSTER_NAME} {
    server ${cp_0}:443 max_fails=3 fail_timeout=1s;
    server ${cp_1}:443 max_fails=3 fail_timeout=1s;
    server ${cp_2}:443 max_fails=3 fail_timeout=1s;
}
upstream openshift4-http-${CLUSTER_NAME} {
    server ${cp_0}:80 max_fails=3 fail_timeout=1s;
    server ${cp_1}:80 max_fails=3 fail_timeout=1s;
    server ${cp_2}:80 max_fails=3 fail_timeout=1s;
}
server {
    listen ${lb_ip}:6443;
    proxy_pass openshift4-api-${CLUSTER_NAME};
}
server {
    listen ${lb_ip}:22623;
    proxy_pass openshift4-mc-${CLUSTER_NAME};
}
server {
    listen ${lb_ip}:443;
    proxy_pass openshift4-https-${CLUSTER_NAME};
}
server {
    listen ${lb_ip}:80;
    proxy_pass openshift4-http-${CLUSTER_NAME};
}
EOF
}

function copyFiles() {
  ${SSH} root@${INSTALL_HOST_IP} "mkdir -p /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}"
  ${SCP} ${WORK_DIR}/openshift-install-dir/boot-artifacts/agent.x86_64-initrd.img root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/initrd
  ${SCP} ${WORK_DIR}/openshift-install-dir/boot-artifacts/agent.x86_64-vmlinuz root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/vmlinuz
  ${SCP} ${WORK_DIR}/openshift-install-dir/boot-artifacts/agent.x86_64-rootfs.img root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/rootfs.img
  ${SSH} root@${INSTALL_HOST_IP} "chmod 644 /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/*"
  ${SCP} -r ${WORK_DIR}/ipxe-work-dir/*.ipxe root@${DOMAIN_ROUTER}:/usr/local/tftpboot/ipxe/
  cat ${WORK_DIR}/dns-work-dir/forward.zone | ${SSH} root@${DOMAIN_ROUTER} "cat >> /usr/local/bind/db.${DOMAIN}"
  cat ${WORK_DIR}/dns-work-dir/reverse.zone | ${SSH} root@${DOMAIN_ROUTER} "cat >> /usr/local/bind/db.${DOMAIN_ARPA}"
  ${SSH} root@${DOMAIN_ROUTER} "/etc/init.d/named stop && sleep 2 && /etc/init.d/named start && sleep 2"
  ${SSH} root@${EDGE_ROUTER_LAN} "/etc/init.d/named stop && sleep 2 && /etc/init.d/named start && sleep 2"
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
    createButaneConfig ${ip_addr} ${host_name} ${mac_addr} worker ${boot_dev}
    createPxeFile ${mac_addr} ${boot_dev} ${host_name} ${ip_addr}
    # Create DNS entries
    echo "${host_name}.${DOMAIN}.   IN      A      ${ip_addr} ; ${host_name}-${DOMAIN}-wk" >> ${WORK_DIR}/dns-work-dir/forward.zone
    o4=$(echo ${ip_addr} | cut -d"." -f4)
    echo "${o4}    IN      PTR     ${host_name}.${DOMAIN}. ; ${host_name}-${DOMAIN}-wk" >> ${WORK_DIR}/dns-work-dir/reverse.zone
    node_index=$(( ${node_index} + 1 ))
  done
  copyFiles
}

function createButaneConfig() {
    
  local ip_addr=${1}
  local host_name=${2}
  local mac=${3}
  local role=${4}
  local boot_dev=${5}
  local mc_version="$(getMcVersion)"

  writeButaneHeader ${mac} ${role}
  writeButaneFiles ${ip_addr} ${host_name} ${mac} ${role}
  writeButaneMetal ${mac}
  cat ${WORK_DIR}/ipxe-work-dir/${mac//:/-}-config.yml | butane -d ${WORK_DIR}/ipxe-work-dir/ -o ${WORK_DIR}/ipxe-work-dir/ignition/${mac//:/-}.ign
}

function writeButaneHeader() {

  local mac=${1}
  local role=${2}

cat << EOF > ${WORK_DIR}/ipxe-work-dir/${mac//:/-}-config.yml
variant: ${BUTANE_VARIANT}
version: ${BUTANE_SPEC_VERSION}
ignition:
  config:
    merge:
      - local: ${role}.ign
EOF
}

function writeButaneFiles() {

  local ip_addr=${1}
  local host_name=${2}
  local mac=${3}
  local cidr=$(mask2cidr ${DOMAIN_NETMASK})

cat << EOF >> ${WORK_DIR}/ipxe-work-dir/${mac//:/-}-config.yml
storage:
  files:
    - path: /etc/zincati/config.d/90-disable-feature.toml
      mode: 0644
      contents:
        inline: |
          [updates]
          enabled = false
    - path: /etc/systemd/network/25-nic0.link
      mode: 0644
      contents:
        inline: |
          [Match]
          MACAddress=${mac}
          [Link]
          Name=nic0
    - path: /etc/NetworkManager/system-connections/nic0.nmconnection
      mode: 0600
      overwrite: true
      contents:
        inline: |
          [connection]
          type=ethernet
          interface-name=nic0

          [ethernet]
          mac-address=${mac}

          [ipv4]
          method=manual
          addresses=${ip_addr}/${cidr}
          gateway=${DOMAIN_ROUTER}
          dns=${DOMAIN_ROUTER}
          dns-search=${DOMAIN}

          [ipv6]
          method=disabled
    - path: /etc/hostname
      mode: 0420
      overwrite: true
      contents:
        inline: |
          ${host_name}
    - path: /etc/chrony.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          pool ${INSTALL_HOST_IP} iburst 
          driftfile /var/lib/chrony/drift
          makestep 1.0 3
          rtcsync
          logdir /var/log/chrony
EOF
}

function writeButaneMetal() {

local mac=${1}

cat << EOF >> ${WORK_DIR}/ipxe-work-dir/${mac//:/-}-config.yml
kernel_arguments:
  should_exist:
    - mitigations=auto
  should_not_exist:
    - mitigations=auto,nosmt
    - mitigations=off
EOF
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