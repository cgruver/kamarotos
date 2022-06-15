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
dnf config-manager  --disable extras-common

mkdir -p /root/.ssh
chmod 700 /root/.ssh
curl -o /root/.ssh/authorized_keys ${INSTALL_URL}/postinstall/authorized_keys
chmod 600 /root/.ssh/authorized_keys
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
echo '@reboot root nmcli con mod "br0_slave_1" ethtool.feature-tso off' >> /etc/crontab
%end

reboot

EOF
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
  while [[ node_index -lt ${node_count} ]]
  do
    host_name=$(yq e ".kvm-hosts.[${node_index}].host-name" ${CLUSTER_CONFIG})
    ${SSH} root@${host_name}.${DOMAIN} "shutdown -h now"
    node_index=$(( ${node_index} + 1 ))
  done
}

function deleteKvmHost() {
  local index=${1}
  local p_cmd=${2}

  mac_addr=$(yq e ".kvm-hosts.[${index}].mac-addr" ${CLUSTER_CONFIG})
  host_name=$(yq e ".kvm-hosts.[${index}].host-name" ${CLUSTER_CONFIG})
  boot_dev=$(yq e ".kvm-hosts.[${index}].disks.disk1" ${CLUSTER_CONFIG})
  destroyMetal root ${host_name} ${boot_dev} na ${p_cmd}
  deletePxeConfig ${mac_addr}
  deleteDns ${host_name}-${DOMAIN}-kvm
}

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

function configOkdNode() {
    
  local ip_addr=${1}
  local host_name=${2}
  local mac=${3}
  local role=${4}

cat << EOF > ${WORK_DIR}/ipxe-work-dir/${mac//:/-}-config.yml
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

cat ${WORK_DIR}/ipxe-work-dir/${mac//:/-}-config.yml | butane -d ${WORK_DIR}/ipxe-work-dir/ -o ${WORK_DIR}/ipxe-work-dir/ignition/${mac//:/-}.ign

}

function configCephPart() {

local mac=${1}
local boot_dev=${2}

mv ${WORK_DIR}/ipxe-work-dir/ignition/${mac//:/-}.ign ${WORK_DIR}/ipxe-work-dir/${mac//:/-}.ign

cat << EOF > ${WORK_DIR}/ipxe-work-dir/${mac//:/-}-ceph.yml
variant: fcos
version: ${BUTANE_SPEC_VERSION}
ignition:
  config:
    merge:
      - local: ${mac//:/-}.ign
storage:
  disks:
    - device: ${boot_dev}
      wipe_table: false
      partitions:
        - label: root
          number: 4
          size_mib: 102400
          resize: true
        - number: 5
          size_mib: 0
EOF

cat ${WORK_DIR}/ipxe-work-dir/${mac//:/-}-ceph.yml | butane -d ${WORK_DIR}/ipxe-work-dir/ -o ${WORK_DIR}/ipxe-work-dir/ignition/${mac//:/-}.ign

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

kernel http://${BASTION_HOST}/install/fcos/${OKD_RELEASE}/vmlinuz edd=off net.ifnames=1 rd.neednet=1 coreos.inst.install_dev=${boot_dev} coreos.inst.ignition_url=http://${BASTION_HOST}/install/fcos/ignition/${CLUSTER_NAME}-${SUB_DOMAIN}/${mac//:/-}.ign coreos.inst.platform_id=${platform} initrd=initrd initrd=rootfs.img ${CONSOLE_OPT}
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

function deployKvmHosts() {

  KVM_EDGE=false

  for i in "$@"
  do
    case $i in
      -e)
        KVM_EDGE=true
      ;;
      -h=*)
        HOST_NAME="${i#*=}"
      ;;
    esac
  done

  if [[ ${KVM_EDGE} == "true" ]]
  then
    labenv -e
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

function updateCentos() {

  wget http://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/isolinux/vmlinuz -O ${OKD_LAB_PATH}/boot-files/vmlinuz
  wget http://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/isolinux/initrd.img -O ${OKD_LAB_PATH}/boot-files/initrd.img
  DOMAIN_COUNT=$(yq e ".sub-domain-configs" ${LAB_CONFIG_FILE} | yq e 'length' -)
  let array_index=0
  while [[ array_index -lt ${DOMAIN_COUNT} ]]
  do
    router_ip=$(yq e ".sub-domain-configs.[${array_index}].router-ip" ${LAB_CONFIG_FILE})
    ${SCP} ${OKD_LAB_PATH}/boot-files/vmlinuz root@${router_ip}:/data/tftpboot/networkboot/vmlinuz
    ${SCP} ${OKD_LAB_PATH}/boot-files/initrd.img root@${router_ip}:/data/tftpboot/networkboot/initrd.img
    array_index=$(( ${array_index} + 1 ))
  done
  ${SSH} root@${BASTION_HOST} "nohup /root/bin/MirrorSync.sh &"
}
