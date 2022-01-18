#!/bin/bash
. ${OKD_LAB_PATH}/bin/labctx.env

INIT_CLUSTER=false
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
CONFIG_FILE=${LAB_CONFIG_FILE}
CP_REPLICAS="1"
SNO_BIP=""

# This script will set up the infrastructure to deploy an OKD 4.X cluster
# Follow the documentation at https://upstreamwithoutapaddle.com/home-lab/lab-intro/

for i in "$@"
do
  case $i in
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      shift # past argument=value
    ;;
    -i|--init)
      INIT_CLUSTER=true
      shift
    ;;
    -d=*|--domain=*)
      SUB_DOMAIN="${i#*=}"
      shift
    ;;
      *)
            # put usage here:
      ;;
  esac
done

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

function createInstallConfig() {

  local install_dev=${1}

read -r -d '' SNO_BIP << EOF
BootstrapInPlace:
  InstallationDisk: "/dev/${install_dev}"
EOF

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
  - ${REGISTRY}/okd
  source: quay.io/openshift/okd
- mirrors:
  - ${REGISTRY}/okd
  source: quay.io/openshift/okd-content
${SNO_BIP}
EOF
}

function createPxeFile() {
  local mac=${1}
  local platform=${2}
  local boot_dev=${3}

if [[ ${platform} == "qemu" ]]
then
  CONSOLE_OPT="console=ttyS0"
fi

cat << EOF > ${WORK_DIR}/ipxe-work-dir/${mac//:/-}.ipxe
#!ipxe

kernel http://${BASTION_HOST}/install/fcos/${OKD_VERSION}/vmlinuz edd=off net.ifnames=1 rd.neednet=1 ignition.firstboot ignition.config.url=http://${BASTION_HOST}/install/fcos/ignition/${CLUSTER_NAME}-${SUB_DOMAIN}/${mac//:/-}.ign ignition.platform.id=${platform} initrd=initrd initrd=rootfs.img ${CONSOLE_OPT}
initrd http://${BASTION_HOST}/install/fcos/${OKD_VERSION}/initrd
initrd http://${BASTION_HOST}/install/fcos/${OKD_VERSION}/rootfs.img

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

  # Create the VM
  DISK_CONFIG="--disk size=${root_vol},path=/VirtualMachines/${host_name}/rootvol,bus=sata"
  if [ ${ceph_vol} != "0" ]
  then
    DISK_CONFIG="${DISK_CONFIG} --disk size=${ceph_vol},path=/VirtualMachines/${host_name}/datavol,bus=sata"
  fi
  ${SSH} root@${kvm_host}.${DOMAIN} "mkdir -p /VirtualMachines/${host_name}"
  ${SSH} root@${kvm_host}.${DOMAIN} "virt-install --print-xml 1 --name ${host_name} --memory ${memory} --vcpus ${cpu} --boot=hd,network,menu=on,useserial=on ${DISK_CONFIG} --network bridge=br0 --graphics none --noautoconsole --os-variant centos7.0 --cpu host-passthrough,match=exact > /VirtualMachines/${host_name}.xml"
  ${SSH} root@${kvm_host}.${DOMAIN} "virsh define /VirtualMachines/${host_name}.xml"
}

if [[ -z ${SUB_DOMAIN} ]]
then
  labctx
fi

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

EDGE_ROUTER=$(yq e ".router" ${CONFIG_FILE})
LAB_DOMAIN=$(yq e ".domain" ${CONFIG_FILE})
BASTION_HOST=$(yq e ".bastion-ip" ${CONFIG_FILE})
SUB_DOMAIN=$(yq e ".sub-domain-configs.[${INDEX}].name" ${CONFIG_FILE})
ROUTER=$(yq e ".sub-domain-configs.[${INDEX}].router-ip" ${CONFIG_FILE})
NETWORK=$(yq e ".sub-domain-configs.[${INDEX}].network" ${CONFIG_FILE})
NETMASK=$(yq e ".sub-domain-configs.[${INDEX}].netmask" ${CONFIG_FILE})
CLUSTER_CONFIG=$(yq e ".sub-domain-configs.[${INDEX}].cluster-config-file" ${CONFIG_FILE})
DOMAIN="${SUB_DOMAIN}.${LAB_DOMAIN}"
REGISTRY=$(yq e ".cluster.proxy-registry" ${CLUSTER_CONFIG})
CLUSTER_NAME=$(yq e ".cluster.name" ${CLUSTER_CONFIG})
CLUSTER_CIDR=$(yq e ".cluster.cluster-cidr" ${CLUSTER_CONFIG})
SERVICE_CIDR=$(yq e ".cluster.service-cidr" ${CLUSTER_CONFIG})
BUTANE_SPEC_VERSION=$(yq e ".cluster.butane-spec-version" ${CLUSTER_CONFIG})
OKD_VERSION=$(yq e ".cluster.release" ${CLUSTER_CONFIG})
INSTALL_URL="http://${BASTION_HOST}/install"
PULL_SECRET_FILE=$(yq e ".cluster.secret-file" ${CLUSTER_CONFIG})
PULL_SECRET=$(cat ${PULL_SECRET_FILE})

IFS=. read -r i1 i2 i3 i4 << EOF
${NETWORK}
EOF
NET_PREFIX=${i1}.${i2}.${i3}
NET_PREFIX_ARPA=${i3}.${i2}.${i1}

WORK_DIR=${OKD_LAB_PATH}/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}
mkdir -p ${WORK_DIR}
rm -rf ${WORK_DIR}/ipxe-work-dir
rm -rf ${WORK_DIR}/dns-work-dir
mkdir -p ${WORK_DIR}/ipxe-work-dir/ignition

mkdir -p ${WORK_DIR}/dns-work-dir

if [[ -d ${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN} ]]
then
  rm -rf ${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}
fi
mkdir -p ${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}
SSH_KEY=$(cat ${OKD_LAB_PATH}/id_rsa.pub)
NEXUS_CERT=$(openssl s_client -showcerts -connect ${REGISTRY} </dev/null 2>/dev/null|openssl x509 -outform PEM | while read line; do echo "  ${line}"; done)
CP_REPLICAS=$(yq e ".control-plane.okd-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
if [[ ${CP_REPLICAS} != "1" ]]
then
  echo "There must be 1 host entry for a Single Node cluster."
  exit 1
fi

# Create and deploy ignition files single-node-ignition-config
rm -rf ${WORK_DIR}/okd-install-dir
mkdir ${WORK_DIR}/okd-install-dir

#Create Control Plane Node
metal=$(yq e ".control-plane.metal" ${CLUSTER_CONFIG})
if [[ ${metal} == "true" ]]
then
  platform=metal
else
  platform=qemu
fi

ip_addr=$(yq e ".control-plane.okd-hosts.[0].ip-addr" ${CLUSTER_CONFIG})
host_name=${CLUSTER_NAME}-node
if [[ ${metal} == "true" ]]
then
  mac_addr=$(yq e ".control-plane.okd-hosts.[0].mac-addr" ${CLUSTER_CONFIG})
else
  memory=$(yq e ".control-plane.node-spec.memory" ${CLUSTER_CONFIG})
  cpu=$(yq e ".control-plane.node-spec.cpu" ${CLUSTER_CONFIG})
  root_vol=$(yq e ".control-plane.node-spec.root_vol" ${CLUSTER_CONFIG})
  kvm_host=$(yq e ".control-plane.okd-hosts.[0].kvm-host" ${CLUSTER_CONFIG})
  # Create the VM
  createOkdVmNode ${ip_addr} ${host_name} ${kvm_host} sno ${memory} ${cpu} ${root_vol} 0
  # Get the MAC address for eth0 in the new VM  
  var=$(${SSH} root@${kvm_host}.${DOMAIN} "virsh -q domiflist ${host_name} | grep br0")
  mac_addr=$(echo ${var} | cut -d" " -f5)
  yq e ".control-plane.okd-hosts.[0].mac-addr = \"${mac_addr}\"" -i ${CLUSTER_CONFIG}
fi
# Create the ignition and iPXE boot files
install_dev=$(yq e ".control-plane.okd-hosts.[0].sno-install-dev" ${CLUSTER_CONFIG})
boot_dev=$(yq e ".control-plane.okd-hosts.[0].boot-dev" ${CLUSTER_CONFIG})

createInstallConfig ${install_dev}
cp ${WORK_DIR}/install-config-upi.yaml ${WORK_DIR}/okd-install-dir/install-config.yaml
openshift-install --dir=${WORK_DIR}/okd-install-dir create single-node-ignition-config
cp ${WORK_DIR}/okd-install-dir/bootstrap-in-place-for-live-iso.ign ${WORK_DIR}/ipxe-work-dir/sno.ign
configOkdNode ${ip_addr} ${host_name}.${DOMAIN} ${mac_addr} sno
createSnoBipDNS ${host_name} ${ip_addr}

${SSH} root@${ROUTER} "HOST=\$(uci add dhcp host) ; \
    uci set dhcp.\${HOST}.name=${host_name} ; \
    uci set dhcp.\${HOST}.mac=${mac_addr} ; \
    uci set dhcp.\${HOST}.ip=${ip_addr} ; \
    uci set dhcp.\${HOST}.dns=1 ; \
    uci commit dhcp ; \
    /etc/init.d/dnsmasq restart"

createPxeFile ${mac_addr} ${platform} ${boot_dev}
# Set the node values in the lab domain configuration file
yq e ".control-plane.okd-hosts.[0].name = \"${host_name}\"" -i ${CLUSTER_CONFIG}

KERNEL_URL=$(openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.kernel.location')
INITRD_URL=$(openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.initramfs.location')
ROOTFS_URL=$(openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.rootfs.location')

${SSH} root@${BASTION_HOST} "if [[ ! -d /usr/local/www/install/fcos/${OKD_VERSION} ]] ; \
  then mkdir -p /usr/local/www/install/fcos/${OKD_VERSION} ; \
  curl -o /usr/local/www/install/fcos/${OKD_VERSION}/vmlinuz ${KERNEL_URL} ; \
  curl -o /usr/local/www/install/fcos/${OKD_VERSION}/initrd ${INITRD_URL} ; \
  curl -o /usr/local/www/install/fcos/${OKD_VERSION}/rootfs.img ${ROOTFS_URL} ; \
  fi"

cp ${WORK_DIR}/okd-install-dir/auth/kubeconfig ${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}/
chmod 400 ${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}/kubeconfig

cat ${WORK_DIR}/dns-work-dir/forward.zone | ${SSH} root@${ROUTER} "cat >> /etc/bind/db.${DOMAIN}"
cat ${WORK_DIR}/dns-work-dir/reverse.zone | ${SSH} root@${ROUTER} "cat >> /etc/bind/db.${NET_PREFIX_ARPA}"
${SSH} root@${ROUTER} "/etc/init.d/named stop && sleep 2 && /etc/init.d/named start && sleep 2"
${SSH} root@${EDGE_ROUTER} "/etc/init.d/named stop && sleep 2 && /etc/init.d/named start"
${SSH} root@${BASTION_HOST} "mkdir -p /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}-${SUB_DOMAIN}"
${SCP} -r ${WORK_DIR}/ipxe-work-dir/ignition/*.ign root@${BASTION_HOST}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}-${SUB_DOMAIN}/
${SSH} root@${BASTION_HOST} "chmod 644 /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}-${SUB_DOMAIN}/*"
${SCP} -r ${WORK_DIR}/ipxe-work-dir/*.ipxe root@${ROUTER}:/data/tftpboot/ipxe/
