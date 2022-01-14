#!/bin/bash

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
CONFIG_FILE=${LAB_CONFIG_FILE}

HOST_NAME=""
INDEX=""

for i in "$@"
do
case $i in
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      shift
    ;;
    -h=*|--host=*)
      HOST_NAME="${i#*=}"
      shift
    ;;
    -d=*|--domain=*)
      SUB_DOMAIN="${i#*=}"
      shift
    ;;
    *)
          # Put usage here:
    ;;
esac
done

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

function createBootFile() {

local hostname=${1}
local mac_addr=${2}
local ip_addr=${3}

cat << EOF > ${OKD_LAB_PATH}/boot-work-dir/${mac_addr//:/-}.ipxe
#!ipxe

kernel ${INSTALL_URL}/repos/BaseOS/x86_64/os/isolinux/vmlinuz net.ifnames=1 ifname=nic0:${mac_addr} ip=${ip_addr}::${ROUTER}:${NETMASK}:${hostname}.${DOMAIN}:nic0:none nameserver=${ROUTER} inst.ks=${INSTALL_URL}/kickstart/${mac_addr//:/-}.ks inst.repo=${INSTALL_URL}/repos/BaseOS/x86_64/os initrd=initrd.img
initrd ${INSTALL_URL}/repos/BaseOS/x86_64/os/isolinux/initrd.img

boot
EOF
}

function createKickStartFile() {

local hostname=${1}
local mac_addr=${2}
local ip_addr=${3}
local disk1=${4}
local disk2=${5}

PART_INFO=$(createPartInfo ${disk1} ${disk2} )
DISK_LIST=${disk1}
if [[ ${disk2} != "NA" ]]
then
  DISK_LIST="${disk1},${disk2}"
fi

cat << EOF > ${OKD_LAB_PATH}/boot-work-dir/${mac_addr//:/-}.ks
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
echo "InitiatorName=iqn.$(hostname)" > /etc/iscsi/initiatorname.iscsi
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

function createDnsRecords() {

  local hostname=${1}
  local ip_octet=${2}

  echo "${hostname}.${DOMAIN}.   IN      A      ${NET_PREFIX}.${ip_octet} ; ${hostname}-${DOMAIN}-kvm" >> ${OKD_LAB_PATH}/boot-work-dir/forward.zone
  echo "${ip_octet}.${NET_PREFIX_ARPA}    IN      PTR     ${hostname}.${DOMAIN}. ; ${hostname}-${DOMAIN}-kvm" >> ${OKD_LAB_PATH}/boot-work-dir/reverse.zone
}

function buildHostConfig() {
  local index=${1}

  hostname=$(yq e ".kvm-hosts.[${index}].host-name" ${CLUSTER_CONFIG})
  mac_addr=$(yq e ".kvm-hosts.[${index}].mac-addr" ${CLUSTER_CONFIG})
  ip_octet=$(yq e ".kvm-hosts.[${index}].ip-octet" ${CLUSTER_CONFIG})
  ip_addr=${NET_PREFIX}.${ip_octet}
  disk1=$(yq e ".kvm-hosts.[${index}].disks.disk1" ${CLUSTER_CONFIG})
  disk2=$(yq e ".kvm-hosts.[${index}].disks.disk2" ${CLUSTER_CONFIG})

  createDnsRecords ${hostname} ${ip_octet}
  createBootFile ${hostname} ${mac_addr} ${ip_addr}
  createKickStartFile ${hostname} ${mac_addr} ${ip_addr} ${disk1} ${disk2}
}

if [[ ${SUB_DOMAIN} != "" ]]
then
  DONE=false
  DOMAIN_COUNT=$(yq e ".sub-domain-configs" ${CONFIG_FILE} | yq e 'length' -)
  let i=0
  while [[ i -lt ${DOMAIN_COUNT} ]]
  do
    domain_name=$(yq e ".sub-domain-configs.[${i}].name" ${CONFIG_FILE})
    if [[ ${domain_name} == ${SUB_DOMAIN} ]]
    then
      INDEX=${i}
      DONE=true
      break
    fi
    i=$(( ${i} + 1 ))
  done
  if [[ ${DONE} == "false" ]]
  then
    echo "Domain Entry Not Found In Config File."
    exit 1
  fi
  SUB_DOMAIN=$(yq e ".sub-domain-configs.[${INDEX}].name" ${CONFIG_FILE})
  ROUTER=$(yq e ".sub-domain-configs.[${INDEX}].router-ip" ${CONFIG_FILE})
  NETWORK=$(yq e ".sub-domain-configs.[${INDEX}].network" ${CONFIG_FILE})
  NETMASK=$(yq e ".sub-domain-configs.[${INDEX}].netmask" ${CONFIG_FILE})
  CLUSTER_CONFIG=$(yq e ".sub-domain-configs.[${INDEX}].cluster-config-file" ${CONFIG_FILE})
  DOMAIN="${SUB_DOMAIN}.${LAB_DOMAIN}"
else
  DOMAIN=$(yq e ".domain" ${CONFIG_FILE})
  ROUTER=$(yq e ".router" ${CONFIG_FILE})
  NETWORK=$(yq e ".network" ${CONFIG_FILE})
  NETMASK=$(yq e ".netmask" ${CONFIG_FILE})
  CLUSTER_CONFIG=${CONFIG_FILE}
fi

BASTION_HOST=$(yq e ".bastion-ip" ${CONFIG_FILE})
INSTALL_URL="http://${BASTION_HOST}/install"

LAB_PWD=$(cat ${OKD_LAB_PATH}/lab_host_pw)
IFS=. read -r i1 i2 i3 i4 << EOF
${NETWORK}
EOF
NET_PREFIX=${i1}.${i2}.${i3}
NET_PREFIX_ARPA=${i3}.${i2}.${i1}

# Create temporary work directory
mkdir -p ${OKD_LAB_PATH}/boot-work-dir

HOST_COUNT=$(yq e ".kvm-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)

if [[ ${HOST_NAME} == "" ]]
then
  let i=0
  while [[ i -lt ${HOST_COUNT} ]]
  do
    buildHostConfig ${i}
    i=$(( ${i} + 1 ))
  done
else
  DONE=false
  let i=0
  while [[ i -lt ${HOST_COUNT} ]]
  do
    host_name=$(yq e ".kvm-hosts.[${i}].host-name" ${CLUSTER_CONFIG})
    if [[ ${host_name} == ${HOST_NAME} ]]
    then
      buildHostConfig ${i}
      DONE=true
      break
    fi
    i=$(( ${i} + 1 ))
  done
  if [[ ${DONE} == "false" ]]
  then
    echo "KVM HOST Entry Not Found In Config File."
    exit 1
  fi
fi

${SCP} -r ${OKD_LAB_PATH}/boot-work-dir/*.ks root@${BASTION_HOST}:/usr/local/www/install/kickstart
${SCP} -r ${OKD_LAB_PATH}/boot-work-dir/*.ipxe root@${ROUTER}:/data/tftpboot/ipxe

cat ${OKD_LAB_PATH}/boot-work-dir/forward.zone | ${SSH} root@${ROUTER} "cat >> /etc/bind/db.${DOMAIN}"
cat ${OKD_LAB_PATH}/boot-work-dir/reverse.zone | ${SSH} root@${ROUTER} "cat >> /etc/bind/db.${NET_PREFIX_ARPA}"
${SSH} root@${ROUTER} "/etc/init.d/named stop && /etc/init.d/named start"


rm -rf ${OKD_LAB_PATH}/boot-work-dir
