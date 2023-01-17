function createBootstrapNode() {
  host_name=${CLUSTER_NAME}-bootstrap
  yq e ".bootstrap.name = \"${host_name}\"" -i ${CLUSTER_CONFIG}
  bs_ip_addr=$(yq e ".bootstrap.ip-addr" ${CLUSTER_CONFIG})
  boot_dev=/dev/sda
  platform=qemu
  if [[ $(yq e ".bootstrap.metal" ${CLUSTER_CONFIG}) == "false" ]]
  then
    kvm_host=$(yq e ".bootstrap.kvm-host" ${CLUSTER_CONFIG})
    memory=$(yq e ".bootstrap.node-spec.memory" ${CLUSTER_CONFIG})
    cpu=$(yq e ".bootstrap.node-spec.cpu" ${CLUSTER_CONFIG})
    root_vol=$(yq e ".bootstrap.node-spec.root-vol" ${CLUSTER_CONFIG})
    createOkdVmNode ${bs_ip_addr} ${host_name} ${kvm_host}.${BOOTSTRAP_KVM_DOMAIN} bootstrap ${memory} ${cpu} ${root_vol} 0 ".bootstrap.mac-addr"
  fi
  # Create the ignition and iPXE boot files
  mac_addr=$(yq e ".bootstrap.mac-addr" ${CLUSTER_CONFIG})
  configOkdNode ${bs_ip_addr} ${host_name}.${DOMAIN} ${mac_addr} bootstrap
  createPxeFile ${mac_addr} ${platform} ${boot_dev}
}