function destroyMetal() {
  local user=${1}
  local hostname=${2}
  local boot_dev=${3}
  local ceph_dev=${4}
  local p_cmd=${5}

  if [[ ${ceph_dev} != "na" ]] && [[ ${ceph_dev} != "" ]]
  then
    ${SSH} -o ConnectTimeout=5 ${user}@${hostname}.${DOMAIN} "sudo wipefs -a -f ${ceph_dev} && sudo dd if=/dev/zero of=${ceph_dev} bs=4096 count=1"
  fi
  ${SSH} -o ConnectTimeout=5 ${user}@${hostname}.${DOMAIN} "sudo wipefs -a -f ${boot_dev} && sudo dd if=/dev/zero of=${boot_dev} bs=4096 count=1 && sudo ${p_cmd}"
}

function deletePxeConfig() {
  local mac_addr=${1}
  
  ${SSH} root@${DOMAIN_ROUTER} "rm -f /usr/local/tftpboot/ipxe/${mac_addr//:/-}.ipxe"
  ${SSH} root@${INSTALL_HOST_IP} "rm -f /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}/${mac_addr//:/-}.ign"
}

function deleteDns() {
  local key=${1}
  ${SSH} root@${DOMAIN_ROUTER} "cat /usr/local/bind/db.${DOMAIN} | grep -v ${key} > /usr/local/bind/db.${DOMAIN}.tmp && mv /usr/local/bind/db.${DOMAIN}.tmp /usr/local/bind/db.${DOMAIN}"
  ${SSH} root@${DOMAIN_ROUTER} "cat /usr/local/bind/db.${DOMAIN_ARPA} | grep -v ${key} > /usr/local/bind/db.${DOMAIN_ARPA}.tmp &&  mv /usr/local/bind/db.${DOMAIN_ARPA}.tmp /usr/local/bind/db.${DOMAIN_ARPA}"
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
kernel http://${INSTALL_HOST_IP}/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/vmlinuz ignition.firstboot ignition.platform.id=metal initrd=initrd coreos.live.rootfs_url=http://${INSTALL_HOST_IP}/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/rootfs.img

boot
EOF

else

cat << EOF > ${WORK_DIR}/ipxe-work-dir/${mac//:/-}.ipxe
#!ipxe

kernel http://${INSTALL_HOST_IP}/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/vmlinuz edd=off net.ifnames=1 ifname=nic0:${mac} ip=${ip_addr}::${DOMAIN_ROUTER}:${DOMAIN_NETMASK}:${hostname}.${DOMAIN}:nic0:none nameserver=${DOMAIN_ROUTER} rd.neednet=1 coreos.inst.install_dev=${boot_dev} coreos.inst.ignition_url=http://${INSTALL_HOST_IP}/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/${mac//:/-}.ign coreos.inst.platform_id=metal initrd=initrd initrd=rootfs.img ${CONSOLE_OPT}
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
    ${SCP} ${WORK_DIR}/openshift-install-dir/boot-artifacts/agent.x86_64-initrd.img root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/initrd
    ${SCP} ${WORK_DIR}/openshift-install-dir/boot-artifacts/agent.x86_64-vmlinuz root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/vmlinuz
    ${SCP} ${WORK_DIR}/openshift-install-dir/boot-artifacts/agent.x86_64-rootfs.img root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/rootfs.img
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
