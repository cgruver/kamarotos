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

function createClusterConfig() {

  mkdir ${WORK_DIR}/okd-install-dir/openshift
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
  cp ${WORK_DIR}/agent-config.yaml ${WORK_DIR}/okd-install-dir/agent-config.yaml
}

function appendDisconnectedInstallConfig() {

NEXUS_CERT=$( openssl s_client -showcerts -connect ${PROXY_REGISTRY} </dev/null 2>/dev/null|openssl x509 -outform PEM | while read line ; do echo "  ${line}" ; done )

cat << EOF >> ${WORK_DIR}/install-config-upi.yaml
additionalTrustBundle: |
${NEXUS_CERT}
imageContentSources:
- mirrors:
  - ${PROXY_REGISTRY}/okd
  source: quay.io/openshift/okd
- mirrors:
  - ${PROXY_REGISTRY}/okd
  source: quay.io/openshift/okd-content
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

  checkRouterModel ${lb_ip}
  if [[ ${GL_MODEL} == "GL-AXT1800" ]]
  then
    configNginx ${lb_ip}
    ${SCP} ${WORK_DIR}/nginx-${CLUSTER_NAME}.conf root@${DOMAIN_ROUTER}:/usr/local/nginx/nginx-${CLUSTER_NAME}.conf
    ${SSH} root@${DOMAIN_ROUTER} "/etc/init.d/nginx restart"
  else
    configHaProxy ${lb_ip}
    ${SCP} ${WORK_DIR}/haproxy-${CLUSTER_NAME}.cfg root@${DOMAIN_ROUTER}:/etc/haproxy-${CLUSTER_NAME}.cfg
    ${SCP} ${WORK_DIR}/haproxy-${CLUSTER_NAME}.init root@${DOMAIN_ROUTER}:/etc/init.d/haproxy-${CLUSTER_NAME}
    ${SSH} root@${DOMAIN_ROUTER} "chmod 644 /etc/haproxy-${CLUSTER_NAME}.cfg ; \
      chmod 750 /etc/init.d/haproxy-${CLUSTER_NAME} ; \
      /etc/init.d/haproxy-${CLUSTER_NAME} enable ; \
      /etc/init.d/haproxy-${CLUSTER_NAME} start"
  fi
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
  if [[ ${metal} == "true" ]]
  then
    boot_dev=$(yq e ".control-plane.boot-dev" ${CLUSTER_CONFIG})
  fi
  let node_count=$(yq e ".control-plane.nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    ip_addr=$(yq e ".control-plane.nodes.[${node_index}].ip-addr" ${CLUSTER_CONFIG})
    host_name=${CLUSTER_NAME}-cp-${node_index}
    yq e ".control-plane.nodes.[${node_index}].name = \"${host_name}\"" -i ${CLUSTER_CONFIG}
    if [[ ${metal} == "false" ]]
    then
      memory=$(yq e ".control-plane.node-spec.memory" ${CLUSTER_CONFIG})
      cpu=$(yq e ".control-plane.node-spec.cpu" ${CLUSTER_CONFIG})
      root_vol=$(yq e ".control-plane.node-spec.root-vol" ${CLUSTER_CONFIG})
      kvm_host=$(yq e ".control-plane.nodes.[${node_index}].kvm-host" ${CLUSTER_CONFIG})
      boot_dev="/dev/sda"
      ceph_node=$(yq ".control-plane | has(\"ceph\")" ${CLUSTER_CONFIG})
      if [[ ${ceph_node} == "true" ]]
      then
        ceph_vol=$(yq e ".control-plane.ceph.ceph-vol" ${CLUSTER_CONFIG})
      else
        ceph_vol=0
      fi
      # Create the VM
      createOkdVmNode ${ip_addr} ${host_name} ${kvm_host}.${DOMAIN} master ${memory} ${cpu} ${root_vol} ${ceph_vol} ".control-plane.nodes.[${node_index}].mac-addr"
    fi
    # Create the ignition and iPXE boot files
    platform=qemu
    if [[ ${metal} == "true" ]]
    then
      platform=metal
    fi
    mac_addr=$(yq e ".control-plane.nodes.[${node_index}].mac-addr" ${CLUSTER_CONFIG})
    createPxeFile ${mac_addr} ${platform} ${boot_dev} ${host_name} ${ip_addr}
    # Create control plane node DNS Records:
    echo "${host_name}.${DOMAIN}.   IN      A      ${ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
    o4=$(echo ${ip_addr} | cut -d"." -f4)
    echo "${o4}    IN      PTR     ${host_name}.${DOMAIN}.  ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/reverse.zone
    node_index=$(( ${node_index} + 1 ))
  done
}

function deployCluster() {

  WORK_DIR=${OKD_LAB_PATH}/${CLUSTER_NAME}.${DOMAIN}
  rm -rf ${WORK_DIR}
  mkdir -p ${WORK_DIR}/ipxe-work-dir/ignition
  mkdir ${WORK_DIR}/dns-work-dir
  mkdir ${WORK_DIR}/okd-install-dir
  if [[ -d ${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}.${DOMAIN} ]]
  then
    rm -rf ${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}.${DOMAIN}
  fi
  mkdir -p ${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}.${DOMAIN}
  SSH_KEY=$(cat ${OKD_LAB_PATH}/ssh_key.pub)
  SNO="false"
  AGENT="true"
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
  cp ${WORK_DIR}/install-config-upi.yaml ${WORK_DIR}/okd-install-dir/install-config.yaml
  createClusterConfig
  openshift-install --dir=${WORK_DIR}/okd-install-dir agent create pxe-files 
  configControlPlane
  cp ${WORK_DIR}/okd-install-dir/auth/kubeconfig ${KUBE_INIT_CONFIG}
  chmod 400 ${KUBE_INIT_CONFIG}
  prepNodeFiles
}

function deployWorkers() {
  WORK_DIR=${OKD_LAB_PATH}/${CLUSTER_NAME}.${DOMAIN}
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
      boot_dev="/dev/sda"
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
      createOkdVmNode ${ip_addr} ${host_name} ${kvm_host}.${DOMAIN} worker ${memory} ${cpu} ${root_vol} ${ceph_vol} ".compute-nodes.[${node_index}].mac-addr"
    fi
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
    createButaneConfig ${ip_addr} ${host_name}.${DOMAIN} ${mac_addr} worker ${platform} ${config_ceph} ${boot_dev}
    createPxeFile ${mac_addr} ${platform} ${boot_dev} ${host_name} ${ip_addr}
    # Create DNS entries
    echo "${host_name}.${DOMAIN}.   IN      A      ${ip_addr} ; ${host_name}-${DOMAIN}-wk" >> ${WORK_DIR}/dns-work-dir/forward.zone
    o4=$(echo ${ip_addr} | cut -d"." -f4)
    echo "${o4}    IN      PTR     ${host_name}.${DOMAIN}. ; ${host_name}-${DOMAIN}-wk" >> ${WORK_DIR}/dns-work-dir/reverse.zone
    node_index=$(( ${node_index} + 1 ))
  done
  prepNodeFiles
}

deployHcpControlPlane() {

  createLbConfig
  ingress_ip=$(yq e ".cluster.ingress-ip-addr" ${CLUSTER_CONFIG})
  echo "*.apps.${CLUSTER_NAME}.${DOMAIN}.     IN      A      ${ingress_ip} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
  echo "api.${CLUSTER_NAME}.${DOMAIN}.        IN      A      ${ingress_ip} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
  echo "api-int.${CLUSTER_NAME}.${DOMAIN}.    IN      A      ${ingress_ip} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone

  let node_count=$(yq e ".control-plane.nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    ip_addr=$(yq e ".control-plane.nodes.[${node_index}].ip-addr" ${CLUSTER_CONFIG})
    host_name=${CLUSTER_NAME}-cp-${node_index}
    yq e ".control-plane.nodes.[${node_index}].name = \"${host_name}\"" -i ${CLUSTER_CONFIG}
    echo "${host_name}.${DOMAIN}.   IN      A      ${ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
    o4=$(echo ${ip_addr} | cut -d"." -f4)
    echo "${o4}    IN      PTR     ${host_name}.${DOMAIN}.  ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/reverse.zone
    node_index=$(( ${node_index} + 1 ))
  done 
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
        deployKvmHosts "$@"
      ;;
      *)
        # catch all
      ;;
    esac
  done
}

