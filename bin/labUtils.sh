function deployCluster() {
  WORK_DIR=${OKD_LAB_PATH}/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}
  rm -rf ${WORK_DIR}
  mkdir -p ${WORK_DIR}/ipxe-work-dir/ignition
  mkdir ${WORK_DIR}/dns-work-dir
  mkdir ${WORK_DIR}/okd-install-dir
  PULL_SECRET_FILE=$(yq e ".cluster.secret-file" ${CLUSTER_CONFIG})
  PULL_SECRET=$(cat ${PULL_SECRET_FILE})
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
  let NODE_COUNT=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${NODE_COUNT} ]]
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

function deployKvmHosts() {
  if [[ ${KVM_EDGE} == "true" ]]
  then
    lab --edge
    DOMAIN=${LAB_DOMAIN}
    ROUTER=${EDGE_ROUTER}
    NETWORK=${EDGE_NETWORK}
    NETMASK=${EDGE_NETMASK}
    CONFIG_FILE=${LAB_CONFIG_FILE}
    ARPA=${EDGE_ARPA}
  else
    DOMAIN="${SUB_DOMAIN}.${LAB_DOMAIN}"
    ROUTER=${DOMAIN_ROUTER}
    NETWORK=${DOMAIN_NETWORK}
    NETMASK=${DOMAIN_NETMASK}
    CONFIG_FILE=${CLUSTER_CONFIG}
    ARPA=${DOMAIN_ARPA}
  fi
  LAB_PWD=$(cat ${OKD_LAB_PATH}/lab_host_pw)
  WORK_DIR=${OKD_LAB_PATH}/boot-work-dir
  rm -rf ${WORK_DIR}
  mkdir -p ${WORK_DIR}

  HOST_COUNT=$(yq e ".kvm-hosts" ${CONFIG_FILE} | yq e 'length' -)

  if [[ ${HOST_NAME} == "" ]]
  then
    let node_index=0
    while [[ node_index -lt ${HOST_COUNT} ]]
    do
      buildHostConfig ${node_index}
      node_index=$(( ${node_index} + 1 ))
    done
  else
    DONE=false
    let node_index=0
    while [[ node_index -lt ${HOST_COUNT} ]]
    do
      host_name=$(yq e ".kvm-hosts.[${node_index}].host-name" ${CONFIG_FILE})
      if [[ ${host_name} == ${HOST_NAME} ]]
      then
        buildHostConfig ${node_index}
        DONE=true
        break
      fi
      node_index=$(( ${node_index} + 1 ))
    done
    if [[ ${DONE} == "false" ]]
    then
      echo "KVM HOST Entry Not Found In Config File."
      exit 1
    fi
  fi

  ${SCP} -r ${WORK_DIR}/*.ks root@${BASTION_HOST}:/usr/local/www/install/kickstart
  ${SCP} -r ${WORK_DIR}/*.ipxe root@${ROUTER}:/data/tftpboot/ipxe

  cat ${WORK_DIR}/forward.zone | ${SSH} root@${ROUTER} "cat >> /etc/bind/db.${DOMAIN}"
  cat ${WORK_DIR}/reverse.zone | ${SSH} root@${ROUTER} "cat >> /etc/bind/db.${ARPA}"
  ${SSH} root@${ROUTER} "/etc/init.d/named stop && /etc/init.d/named start"
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

function startWorker() {
  let node_count=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ i -lt ${node_count} ]]
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
  let NODE_COUNT=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${NODE_COUNT} ]]
  do
    host_name=$(yq e ".compute-nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    oc adm cordon ${host_name}.${DOMAIN}
    node_index=$(( ${node_index} + 1 ))
  done
}

function unCordonNode() {
  setKubeConfig
  let NODE_COUNT=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${NODE_COUNT} ]]
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

function deleteNodeVm() {
  local host_name=${1}
  local kvm_host=${2}

  ${SSH} root@${kvm_host}.${DOMAIN} "virsh destroy ${host_name}"
  ${SSH} root@${kvm_host}.${DOMAIN} "virsh undefine ${host_name}"
  ${SSH} root@${kvm_host}.${DOMAIN} "virsh pool-destroy ${host_name}"
  ${SSH} root@${kvm_host}.${DOMAIN} "virsh pool-undefine ${host_name}"
  ${SSH} root@${kvm_host}.${DOMAIN} "rm -rf /VirtualMachines/${host_name}"
}

function stopKvmHosts() {

  let node_count=$(yq e ".kvm-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${NODE_COUNT} ]]
  do
    host_name=$(yq e ".kvm-hosts.[${node_index}].host-name" ${CLUSTER_CONFIG})
    ssh root@${host_name}.${DOMAIN} "shutdown -h now"
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

function deletePxeConfig() {
  local mac_addr=${1}
  
  ${SSH} root@${DOMAIN_ROUTER} "rm -f /data/tftpboot/ipxe/${mac_addr//:/-}.ipxe"
  ${SSH} root@${BASTION_HOST} "rm -f /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}/${mac_addr//:/-}.ign"
}

function deleteDns() {
  local key=${1}
  ${SSH} root@${DOMAIN_ROUTER} "cat /etc/bind/db.${DOMAIN} | grep -v ${key} > /tmp/db.${DOMAIN} && cp /tmp/db.${DOMAIN} /etc/bind/db.${DOMAIN}"
  ${SSH} root@${DOMAIN_ROUTER} "cat /etc/bind/db.${DOMAIN_ARPA} | grep -v ${key} > /tmp/db.${DOMAIN_ARPA} && cp /tmp/db.${DOMAIN_ARPA} /etc/bind/db.${DOMAIN_ARPA}"
}

function createSnoBipDNS() {
  local host_name=${1}
  local ip_addr=${2}

cat << EOF > ${WORK_DIR}/dns-work-dir/forward.zone
*.apps.${CLUSTER_NAME}.${DOMAIN}.     IN      A      ${ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-cp
api.${CLUSTER_NAME}.${DOMAIN}.        IN      A      ${ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-cp
api-int.${CLUSTER_NAME}.${DOMAIN}.    IN      A      ${ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-cp
${host_name}.${DOMAIN}.   IN      A      ${ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-cp
etcd-0.${DOMAIN}.          IN      A      ${ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-cp
_etcd-server-ssl._tcp.${CLUSTER_NAME}.${DOMAIN}    86400     IN    SRV     0    10    2380    etcd-0.${CLUSTER_NAME}.${DOMAIN}. ; ${CLUSTER_NAME}-${DOMAIN}-cp
EOF

o4=$(echo ${ip_addr} | cut -d"." -f4)

cat << EOF > ${WORK_DIR}/dns-work-dir/reverse.zone
${o4}    IN      PTR     ${host_name}.${DOMAIN}.  ; ${CLUSTER_NAME}-${DOMAIN}-cp
EOF

}

function createSnoDNS() {
  local host_name=${1}
  local ip_addr=${2}
  local bs_ip_addr=${3}

cat << EOF > ${WORK_DIR}/dns-work-dir/forward.zone
${CLUSTER_NAME}-bootstrap.${DOMAIN}.  IN      A      ${bs_ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-bs
*.apps.${CLUSTER_NAME}.${DOMAIN}.     IN      A      ${ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-cp
api.${CLUSTER_NAME}.${DOMAIN}.        IN      A      ${ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-cp
api.${CLUSTER_NAME}.${DOMAIN}.        IN      A      ${bs_ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-bs
api-int.${CLUSTER_NAME}.${DOMAIN}.    IN      A      ${ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-cp
api-int.${CLUSTER_NAME}.${DOMAIN}.    IN      A      ${bs_ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-bs
${host_name}.${DOMAIN}.   IN      A      ${ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-cp
etcd-0.${DOMAIN}.          IN      A      ${ip_addr} ; ${CLUSTER_NAME}-${DOMAIN}-cp
_etcd-server-ssl._tcp.${CLUSTER_NAME}.${DOMAIN}    86400     IN    SRV     0    10    2380    etcd-0.${CLUSTER_NAME}.${DOMAIN}. ; ${CLUSTER_NAME}-${DOMAIN}-cp
EOF

o4=$(echo ${ip_addr} | cut -d"." -f4)
bs_o4=$(echo ${bs_ip_addr} | cut -d"." -f4)
cat << EOF > ${WORK_DIR}/dns-work-dir/reverse.zone
${o4}    IN      PTR     ${host_name}.${DOMAIN}.  ; ${CLUSTER_NAME}-${DOMAIN}-cp
${bs_o4}    IN      PTR     ${CLUSTER_NAME}-bootstrap.${DOMAIN}.   ; ${CLUSTER_NAME}-${DOMAIN}-bs
EOF

}

function createInstallConfig() {

  local install_dev=${1}

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
pullSecret: '${PULL_SECRET}'
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

function configOkdNode() {
    
  local ip_addr=${1}
  local host_name=${2}
  local mac=${3}
  local role=${4}

cat << EOF > ${WORK_DIR}/ipxe-work-dir/ignition/${mac//:/-}.yml
variant: fcos
version: ${BUTANE_SPEC_VERSION}
ignition:
  config:
    merge:
      - local: ${role}.ign
kernel_arguments:
  should_exist:
    - mitigations=auto
  should_not_exist:
    - mitigations=auto,nosmt
  should_not_exist:
    - mitigations=off
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
          addresses=${ip_addr}/${DOMAIN_NETMASK}
          gateway=${DOMAIN_ROUTER}
          dns=${DOMAIN_ROUTER}
          dns-search=${DOMAIN}
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
          pool ${BASTION_HOST} iburst 
          driftfile /var/lib/chrony/drift
          makestep 1.0 3
          rtcsync
          logdir /var/log/chrony
EOF

cat ${WORK_DIR}/ipxe-work-dir/ignition/${mac//:/-}.yml | butane -d ${WORK_DIR}/ipxe-work-dir/ -o ${WORK_DIR}/ipxe-work-dir/ignition/${mac//:/-}.ign

}

function createPxeFile() {
  local mac=${1}
  local platform=${2}
  local boot_dev=${3}

if [[ ${platform} == "qemu" ]]
then
  CONSOLE_OPT="console=ttyS0"
fi

# Save for when BIP is working
# cat << EOF > ${WORK_DIR}/ipxe-work-dir/${mac//:/-}.ipxe
# #!ipxe

# kernel http://${BASTION_HOST}/install/fcos/${OKD_RELEASE}/vmlinuz edd=off net.ifnames=1 rd.neednet=1 ignition.firstboot ignition.config.url=http://${BASTION_HOST}/install/fcos/ignition/${CLUSTER_NAME}-${SUB_DOMAIN}/${mac//:/-}.ign ignition.platform.id=${platform} initrd=initrd initrd=rootfs.img ${CONSOLE_OPT}
# initrd http://${BASTION_HOST}/install/fcos/${OKD_RELEASE}/initrd
# initrd http://${BASTION_HOST}/install/fcos/${OKD_RELEASE}/rootfs.img

# boot
# EOF
cat << EOF > ${WORK_DIR}/ipxe-work-dir/${mac//:/-}.ipxe
#!ipxe

kernel http://${BASTION_HOST}/install/fcos/${OKD_RELEASE}/vmlinuz edd=off net.ifnames=1 rd.neednet=1 coreos.inst.install_dev=/dev/${boot_dev} coreos.inst.ignition_url=http://${BASTION_HOST}/install/fcos/ignition/${CLUSTER_NAME}-${SUB_DOMAIN}/${mac//:/-}.ign coreos.inst.platform_id=${platform} initrd=initrd initrd=rootfs.img ${CONSOLE_OPT}
initrd http://${BASTION_HOST}/install/fcos/${OKD_RELEASE}/initrd
initrd http://${BASTION_HOST}/install/fcos/${OKD_RELEASE}/rootfs.img

boot
EOF

}

function createOkdVmNode() {
    
  local ip_addr=${1}
  local host_name=${2}
  local kvm_host=${3}
  local role=${4}
  local memory=${5}
  local cpu=${6}
  local root_vol=${7}
  local ceph_vol=${8}
  local yq_loc=${9}

  # Create the VM
  DISK_CONFIG="--disk size=${root_vol},path=/VirtualMachines/${host_name}/rootvol,bus=sata"
  if [ ${ceph_vol} != "0" ]
  then
    DISK_CONFIG="${DISK_CONFIG} --disk size=${ceph_vol},path=/VirtualMachines/${host_name}/datavol,bus=sata"
  fi
  ${SSH} root@${kvm_host}.${DOMAIN} "mkdir -p /VirtualMachines/${host_name} ; \
    virt-install --print-xml 1 --name ${host_name} --memory ${memory} --vcpus ${cpu} --boot=hd,network,menu=on,useserial=on ${DISK_CONFIG} --network bridge=br0 --graphics none --noautoconsole --os-variant centos7.0 --cpu host-passthrough,match=exact > /VirtualMachines/${host_name}.xml ; \
    virsh define /VirtualMachines/${host_name}.xml"
  # Get the MAC address for eth0 in the new VM  
  var=$(${SSH} root@${kvm_host}.${DOMAIN} "virsh -q domiflist ${host_name} | grep br0")
  mac_addr=$(echo ${var} | cut -d" " -f5)
  yq e "${yq_loc} = \"${mac_addr}\"" -i ${CLUSTER_CONFIG}
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

function prepNodeFiles() {
  cat ${WORK_DIR}/dns-work-dir/forward.zone | ${SSH} root@${DOMAIN_ROUTER} "cat >> /etc/bind/db.${DOMAIN}"
  cat ${WORK_DIR}/dns-work-dir/reverse.zone | ${SSH} root@${DOMAIN_ROUTER} "cat >> /etc/bind/db.${DOMAIN_ARPA}"
  ${SSH} root@${DOMAIN_ROUTER} "/etc/init.d/named stop && sleep 2 && /etc/init.d/named start && sleep 2"
  ${SSH} root@${EDGE_ROUTER} "/etc/init.d/named stop && sleep 2 && /etc/init.d/named start"
  ${SSH} root@${BASTION_HOST} "mkdir -p /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}-${SUB_DOMAIN}"
  ${SCP} -r ${WORK_DIR}/ipxe-work-dir/ignition/*.ign root@${BASTION_HOST}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}-${SUB_DOMAIN}/
  ${SSH} root@${BASTION_HOST} "chmod 644 /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}-${SUB_DOMAIN}/*"
  ${SCP} -r ${WORK_DIR}/ipxe-work-dir/*.ipxe root@${DOMAIN_ROUTER}:/data/tftpboot/ipxe/
}

function createPartInfo() {

local disk1=${1}
local disk2=${2}

if [[ ${disk2} == "NA" ]]
then
cat <<EOF
part pv.1 --fstype="lvmpv" --ondisk=${disk1} --size=1024 --grow --maxsize=2000000
volgroup centos --pesize=4096 pv.1
EOF
else
cat <<EOF
part pv.1 --fstype="lvmpv" --ondisk=${disk1} --size=1024 --grow --maxsize=2000000
part pv.2 --fstype="lvmpv" --ondisk=${disk2} --size=1024 --grow --maxsize=2000000
volgroup centos --pesize=4096 pv.1 pv.2
EOF
fi
}

function buildHostConfig() {
  local index=${1}

  hostname=$(yq e ".kvm-hosts.[${index}].host-name" ${CONFIG_FILE})
  mac_addr=$(yq e ".kvm-hosts.[${index}].mac-addr" ${CONFIG_FILE})
  ip_addr=$(yq e ".kvm-hosts.[${index}].ip-addr" ${CONFIG_FILE})
  disk1=$(yq e ".kvm-hosts.[${index}].disks.disk1" ${CONFIG_FILE})
  disk2=$(yq e ".kvm-hosts.[${index}].disks.disk2" ${CONFIG_FILE})

  IFS="." read -r i1 i2 i3 i4 <<< "${ip_addr}"
  echo "${hostname}.${DOMAIN}.   IN      A      ${ip_addr} ; ${hostname}-${DOMAIN}-kvm" >> ${WORK_DIR}/forward.zone
  echo "${i4}    IN      PTR     ${hostname}.${DOMAIN}. ; ${hostname}-${DOMAIN}-kvm" >> ${WORK_DIR}/reverse.zone
  
cat << EOF > ${WORK_DIR}/${mac_addr//:/-}.ipxe
#!ipxe

kernel ${INSTALL_URL}/repos/BaseOS/x86_64/os/isolinux/vmlinuz net.ifnames=1 ifname=nic0:${mac_addr} ip=${ip_addr}::${ROUTER}:${NETMASK}:${hostname}.${DOMAIN}:nic0:none nameserver=${ROUTER} inst.ks=${INSTALL_URL}/kickstart/${mac_addr//:/-}.ks inst.repo=${INSTALL_URL}/repos/BaseOS/x86_64/os initrd=initrd.img
initrd ${INSTALL_URL}/repos/BaseOS/x86_64/os/isolinux/initrd.img

boot
EOF

PART_INFO=$(createPartInfo ${disk1} ${disk2} )
DISK_LIST=${disk1}
if [[ ${disk2} != "NA" ]]
then
  DISK_LIST="${disk1},${disk2}"
fi

cat << EOF > ${WORK_DIR}/${mac_addr//:/-}.ks
#version=RHEL8
cmdline
keyboard --vckeymap=us --xlayouts='us'
lang en_US.UTF-8
repo --name="install" --baseurl=${INSTALL_URL}/repos/BaseOS/x86_64/os/
url --url="${INSTALL_URL}/repos/BaseOS/x86_64/os"
rootpw --iscrypted ${LAB_PWD}
firstboot --disable
skipx
services --enabled="chronyd"
timezone America/New_York --isUtc

# Disk partitioning information
ignoredisk --only-use=${DISK_LIST}
bootloader --append=" crashkernel=auto" --location=mbr --boot-drive=${disk1}
clearpart --drives=${DISK_LIST} --all --initlabel
zerombr
part /boot --fstype="xfs" --ondisk=${disk1} --size=1024
part /boot/efi --fstype="efi" --ondisk=${disk1} --size=600 --fsoptions="umask=0077,shortname=winnt"
${PART_INFO}
logvol swap  --fstype="swap" --size=16064 --name=swap --vgname=centos
logvol /  --fstype="xfs" --grow --maxsize=2000000 --size=1024 --name=root --vgname=centos

# Network Config
network  --hostname=${hostname}
network  --device=nic0 --noipv4 --noipv6 --no-activate --onboot=no
network  --bootproto=static --device=br0 --bridgeslaves=nic0 --gateway=${ROUTER} --ip=${ip_addr} --nameserver=${ROUTER} --netmask=${NETMASK} --noipv6 --activate --bridgeopts="stp=false" --onboot=yes

eula --agreed

%packages
@^minimal-environment
kexec-tools
%end

%addon com_redhat_kdump --enable --reserve-mb='auto'

%end

%anaconda
pwpolicy root --minlen=6 --minquality=1 --notstrict --nochanges --notempty
pwpolicy user --minlen=6 --minquality=1 --notstrict --nochanges --emptyok
pwpolicy luks --minlen=6 --minquality=1 --notstrict --nochanges --notempty
%end

%post
dnf config-manager --add-repo ${INSTALL_URL}/postinstall/local-repos.repo
dnf config-manager  --disable appstream
dnf config-manager  --disable baseos
dnf config-manager  --disable extras

mkdir -p /root/.ssh
chmod 700 /root/.ssh
curl -o /root/.ssh/authorized_keys ${INSTALL_URL}/postinstall/authorized_keys
chmod 600 /root/.ssh/authorized_keys
dnf -y module install virt
dnf -y install wget git net-tools bind-utils bash-completion nfs-utils rsync libguestfs-tools virt-install iscsi-initiator-utils
dnf -y update
echo "InitiatorName=iqn.\$(hostname)" > /etc/iscsi/initiatorname.iscsi
echo "options kvm_intel nested=1" >> /etc/modprobe.d/kvm.conf
systemctl enable libvirtd
mkdir /VirtualMachines
mkdir -p /root/bin
curl -o /root/bin/rebuildhost.sh ${INSTALL_URL}/postinstall/rebuildhost.sh
chmod 700 /root/bin/rebuildhost.sh
curl -o /etc/chrony.conf ${INSTALL_URL}/postinstall/chrony.conf
echo '@reboot root nmcli con mod "br0 slave 1" ethtool.feature-tso off' >> /etc/crontab
%end

reboot

EOF
}

function setKubeConfig() {
  export KUBECONFIG=${KUBE_INIT_CONFIG}
}

function approveCsr() {
  local sub_domain=${1}
  if [[ -z ${SUB_DOMAIN} ]]
  then
    setDomainIndex ${sub_domain}
  fi
  if [[ ${LAB_CTX_ERROR} == "false" ]]
  then
    CLUSTER_CONFIG=$(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].cluster-config-file" ${LAB_CONFIG_FILE})
    CLUSTER_NAME=$(yq e ".cluster.name" ${CLUSTER_CONFIG})
    LAB_DOMAIN=$(yq e ".domain" ${LAB_CONFIG_FILE})
    SUB_DOMAIN=$(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].name" ${LAB_CONFIG_FILE})
    KUBE_INIT_CONFIG=${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}/kubeconfig
    oc --kubeconfig=${KUBE_INIT_CONFIG} get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs oc adm certificate approve
  fi
}

function trustClusterCert() {
  local sub_domain=${1}
  if [[ -z ${SUB_DOMAIN} ]]
  then
    setDomainIndex ${sub_domain}
  fi
  if [[ ${LAB_CTX_ERROR} == "false" ]]
  then
    CLUSTER_CONFIG=$(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].cluster-config-file" ${LAB_CONFIG_FILE})
    CLUSTER_NAME=$(yq e ".cluster.name" ${CLUSTER_CONFIG})
    LAB_DOMAIN=$(yq e ".domain" ${LAB_CONFIG_FILE})
    SUB_DOMAIN=$(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].name" ${LAB_CONFIG_FILE})
    SYS_ARCH=$(uname)
    if [[ ${SYS_ARCH} == "Darwin" ]]
    then
      openssl s_client -showcerts -connect  console-openshift-console.apps.${CLUSTER_NAME}.${SUB_DOMAIN}.${LAB_DOMAIN}:443 </dev/null 2>/dev/null|openssl x509 -outform PEM > /tmp/okd-console.${SUB_DOMAIN}.${LAB_DOMAIN}.crt
      sudo security add-trusted-cert -d -r trustAsRoot -k "/Library/Keychains/System.keychain" /tmp/okd-console.${SUB_DOMAIN}.${LAB_DOMAIN}.crt
    elif [[ ${SYS_ARCH} == "Linux" ]]
    then
      sudo openssl s_client -showcerts -connect console-openshift-console.apps.${CLUSTER_NAME}.${SUB_DOMAIN}.${LAB_DOMAIN}:443 </dev/null 2>/dev/null|openssl x509 -outform PEM > /etc/pki/ca-trust/source/anchors/okd-console.${SUB_DOMAIN}.${LAB_DOMAIN}.crt
      sudo update-ca-trust
    else
      echo "Unsupported OS: Cannot trust openshift cert"
    fi
  fi
}

function noInternet() {
  ssh root@router.${LAB_DOMAIN} "new_rule=\$(uci add firewall rule) ; \
    uci set firewall.\${new_rule}.enabled=1 ; \
    uci set firewall.\${new_rule}.target=REJECT ; \
    uci set firewall.\${new_rule}.src=lan ; \
    uci set firewall.\${new_rule}.src_ip=${DOMAIN_NETWORK}/24 ; \
    uci set firewall.\${new_rule}.dest=wan ; \
    uci set firewall.\${new_rule}.name=${SUB_DOMAIN}-internet-deny ; \
    uci set firewall.\${new_rule}.proto=all ; \
    uci set firewall.\${new_rule}.family=ipv4 ; \
    uci commit firewall && \
    /etc/init.d/firewall restart"
}

function restoreInternet() {
  local fw_index=$(ssh root@router.${LAB_DOMAIN} "uci show firewall" | grep ${SUB_DOMAIN}-internet-deny | cut -d"[" -f2 | cut -d "]" -f1)
  if [[ ! -z ${fw_index} ]] && [[ ${fw_index} != 0 ]]
  then
    ssh root@router.${LAB_DOMAIN} "uci delete firewall.@rule[${fw_index}] ; \
      uci commit firewall ; \
      /etc/init.d/firewall restart"
  fi
}

function pullSecret() {
  echo "Enter the Nexus user for the pull secret:"
  read NEXUS_USER
  echo "Enter the password for the pull secret:"
  read NEXUS_PWD
  CLUSTER_CONFIG=$(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].cluster-config-file" ${LAB_CONFIG_FILE})
  LAB_DOMAIN=$(yq e ".domain" ${LAB_CONFIG_FILE})
  NEXUS_SECRET=$(echo -n "${NEXUS_USER}:${NEXUS_PWD}" | base64) 
  echo -n "{\"auths\": {\"fake\": {\"auth\": \"Zm9vOmJhcgo=\"},\"nexus.${LAB_DOMAIN}:5001\": {\"auth\": \"${NEXUS_SECRET}\"}}}" > ${PULL_SECRET}
}

function resetDns() {
  SYS_ARCH=$(uname)
  if [[ ${SYS_ARCH} == "Darwin" ]]
  then
    sudo killall -HUP mDNSResponder
  else
    echo "Unsupported OS: Cannot reset DNS"
  fi
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
    CLUSTER_CONFIG=$(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].cluster-config-file" ${LAB_CONFIG_FILE})
    CLUSTER_NAME=$(yq e ".cluster.name" ${CLUSTER_CONFIG})
    SUB_DOMAIN=$(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].name" ${LAB_CONFIG_FILE})
    LAB_DOMAIN=$(yq e ".domain" ${LAB_CONFIG_FILE})
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
