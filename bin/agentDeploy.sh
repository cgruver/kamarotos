function agentDeploy() {

  COREOS_INSTALLER_IMAGE=quay.io/coreos/coreos-installer
  COREOS_INSTALLER_VER=v0.17.0
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
  CP_REPLICAS=$(yq e ".control-plane.okd-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
  if [[ ${CP_REPLICAS} != "3" ]]
  then
    echo "There must be 3 host entries for the control plane for a full cluster, or 1 entry for a Single Node cluster."
    exit 1
  fi
  setControlPlaneVars
  createAgentDnsRecords
  pause 40 "Give DNS Time to recover"
  nslookup quay.io
  createAgentInstallConfig
  createAgentPxeBootFiles ${NODE_0_MAC} ${NODE_0_IP} ${NODE_0_NAME}
  createAgentPxeBootFiles ${NODE_1_MAC} ${NODE_1_IP} ${NODE_1_NAME}
  createAgentPxeBootFiles ${NODE_2_MAC} ${NODE_2_IP} ${NODE_2_NAME}
  createBipIpRes ${NODE_0_MAC} ${NODE_0_IP} ${NODE_0_NAME}
  createBipIpRes ${NODE_1_MAC} ${NODE_1_IP} ${NODE_1_NAME}
  createBipIpRes ${NODE_2_MAC} ${NODE_2_IP} ${NODE_2_NAME}
  ${SSH} root@${DOMAIN_ROUTER} "/etc/init.d/dnsmasq restart"
  # createAgentLbConfig
  # configNginx
  copyFiles
}

function setControlPlaneVars() {

  INGRESS_VIP=$(yq e ".cluster.ingress-ip-addr" ${CLUSTER_CONFIG})
  API_VIP=$(yq e ".cluster.api-ip-addr" ${CLUSTER_CONFIG})
  DOMAIN_CIDR=$(mask2cidr ${DOMAIN_NETMASK})
  NODE_0_IP=$(yq e ".control-plane.okd-hosts.[0].ip-addr" ${CLUSTER_CONFIG})
  NODE_1_IP=$(yq e ".control-plane.okd-hosts.[1].ip-addr" ${CLUSTER_CONFIG})
  NODE_2_IP=$(yq e ".control-plane.okd-hosts.[2].ip-addr" ${CLUSTER_CONFIG})
  NODE_0_NAME=${CLUSTER_NAME}-master-0.${DOMAIN}
  NODE_1_NAME=${CLUSTER_NAME}-master-1.${DOMAIN}
  NODE_2_NAME=${CLUSTER_NAME}-master-2.${DOMAIN}
  NODE_0_MAC=$(yq e ".control-plane.okd-hosts.[0].mac-addr" ${CLUSTER_CONFIG})
  NODE_1_MAC=$(yq e ".control-plane.okd-hosts.[1].mac-addr" ${CLUSTER_CONFIG})
  NODE_2_MAC=$(yq e ".control-plane.okd-hosts.[2].mac-addr" ${CLUSTER_CONFIG})
  yq e ".control-plane.okd-hosts.[0].name = \"${CLUSTER_NAME}-master-0\"" -i ${CLUSTER_CONFIG}
  yq e ".control-plane.okd-hosts.[1].name = \"${CLUSTER_NAME}-master-1\"" -i ${CLUSTER_CONFIG}
  yq e ".control-plane.okd-hosts.[2].name = \"${CLUSTER_NAME}-master-2\"" -i ${CLUSTER_CONFIG}

}

function generateConfigFiles() {

cat << EOF > ${WORK_DIR}/install-config.yaml
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
  - cidr: ${DOMAIN_NETWORK}/${DOMAIN_CIDR}
compute:
- name: worker
  replicas: 0
controlPlane:
  name: master
  replicas: ${CP_REPLICAS}
platform:
  baremetal:
    apiVIPs:
    - ${API_VIP}
    ingressVIPs:
    - ${INGRESS_VIP}
pullSecret: '${PULL_SECRET_TXT}'
sshKey: ${SSH_KEY}
EOF

cat << EOF > ${WORK_DIR}/agent-config.yaml
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: ${CLUSTER_NAME}
rendezvousIP: ${NODE_0_IP}
hosts:
- hostname: ${NODE_0_NAME}
  role: master
  rootDeviceHints:
    deviceName: "/dev/sda"
  interfaces:
  - name: nic0
    macAddress: ${NODE_0_MAC}
- hostname: ${NODE_1_NAME}
  role: master
  rootDeviceHints:
    deviceName: "/dev/sda"
  interfaces:
  - name: nic0
    macAddress: ${NODE_1_MAC}
- hostname: ${NODE_2_NAME}
  role: master
  rootDeviceHints:
    deviceName: "/dev/sda"
  interfaces:
  - name: nic0
    macAddress: ${NODE_2_MAC}
EOF

cat << EOF > ${WORK_DIR}/okd-install-dir/create-cluster-boot-files.sh
#!/usr/bin/env bash
# coreos-installer iso extract pxe agent.x86_64.iso
# coreos-installer pxe customize --live-ignition <(coreos-installer iso ignition show agent.x86_64.iso) -o agent.initrd.img agent.x86_64-initrd.img
coreos-installer iso ignition show agent.x86_64.iso > agent-install.ign
EOF

}

function createAgentInstallConfig() {

  if [[ ! -f  ${PULL_SECRET} ]]
  then
    pullSecret
  fi

  PULL_SECRET_TXT=$(cat ${PULL_SECRET})
  generateConfigFiles
  chmod 755 ${WORK_DIR}/okd-install-dir/create-cluster-boot-files.sh
  cp ${WORK_DIR}/install-config.yaml ${WORK_DIR}/okd-install-dir/install-config.yaml
  cp ${WORK_DIR}/agent-config.yaml ${WORK_DIR}/okd-install-dir/agent-config.yaml
  openshift-install --dir=${WORK_DIR}/okd-install-dir agent create image
  podman run --rm -v ${WORK_DIR}/okd-install-dir:/data -w /data --entrypoint /data/create-cluster-boot-files.sh ${COREOS_INSTALLER_IMAGE}:${COREOS_INSTALLER_VER}
  cp ${WORK_DIR}/okd-install-dir/auth/kubeconfig ${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}.${DOMAIN}/
  chmod 400 ${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}.${DOMAIN}/kubeconfig
  
  KERNEL_URL=$(openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.kernel.location')
  INITRD_URL=$(openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.initramfs.location')
  ROOTFS_URL=$(openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.rootfs.location')

  ${SSH} root@${INSTALL_HOST_IP} "if [[ ! -d /usr/local/www/install/fcos/${OKD_RELEASE} ]] ; \
    then mkdir -p /usr/local/www/install/fcos/${OKD_RELEASE} ; \
    curl -o /usr/local/www/install/fcos/${OKD_RELEASE}/vmlinuz ${KERNEL_URL} ; \
    curl -o /usr/local/www/install/fcos/${OKD_RELEASE}/initrd ${INITRD_URL} ; \
    curl -o /usr/local/www/install/fcos/${OKD_RELEASE}/rootfs.img ${ROOTFS_URL} ; \
    fi"
}

function createAgentDnsRecords() {

  echo "*.apps.${CLUSTER_NAME}.${DOMAIN}.     IN      A      ${INGRESS_VIP} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
  echo "api.${CLUSTER_NAME}.${DOMAIN}.        IN      A      ${API_VIP} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
  echo "api-int.${CLUSTER_NAME}.${DOMAIN}.    IN      A      ${API_VIP} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
  echo "${NODE_0_NAME}.   IN      A      ${NODE_0_IP} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
  o4=$(echo ${NODE_0_IP} | cut -d"." -f4)
  echo "${o4}    IN      PTR     ${NODE_0_NAME}.  ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/reverse.zone
  echo "${NODE_1_NAME}.   IN      A      ${NODE_1_IP} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
  o4=$(echo ${NODE_1_IP} | cut -d"." -f4)
  echo "${o4}    IN      PTR     ${NODE_1_NAME}.  ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/reverse.zone
  echo "${NODE_2_NAME}.   IN      A      ${NODE_2_IP} ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/forward.zone
  o4=$(echo ${NODE_2_IP} | cut -d"." -f4)
  echo "${o4}    IN      PTR     ${NODE_2_NAME}.  ; ${CLUSTER_NAME}-${DOMAIN}-cp" >> ${WORK_DIR}/dns-work-dir/reverse.zone

  cat ${WORK_DIR}/dns-work-dir/forward.zone | ${SSH} root@${DOMAIN_ROUTER} "cat >> /data/bind/db.${DOMAIN}"
  cat ${WORK_DIR}/dns-work-dir/reverse.zone | ${SSH} root@${DOMAIN_ROUTER} "cat >> /data/bind/db.${DOMAIN_ARPA}"
  ${SSH} root@${DOMAIN_ROUTER} "/etc/init.d/named restart && sleep 5"
  if [[ ${DOMAIN_ROUTER} != ${EDGE_ROUTER} ]]
  then
    ${SSH} root@${EDGE_ROUTER} "/etc/init.d/named restart && sleep 5"
  fi
}

function createAgentPxeBootFiles() {

  local mac=${1}
  local ip_addr=${2}
  local hostname=${3}

cat << EOF > ${WORK_DIR}/ipxe-work-dir/${mac//:/-}.ipxe
#!ipxe

kernel http://${INSTALL_HOST_IP}/install/fcos/${OKD_RELEASE}/vmlinuz edd=off net.ifnames=1 ifname=nic0:${mac} ip=${ip_addr}::${DOMAIN_ROUTER}:${DOMAIN_NETMASK}:${hostname}:nic0:none nameserver=${DOMAIN_ROUTER} rd.neednet=1 ignition.firstboot ignition.platform.id=metal initrd=initrd  coreos.live.rootfs_url=http://${INSTALL_HOST_IP}/install/fcos/${OKD_RELEASE}/rootfs.img ignition.config.url=http://${INSTALL_HOST_IP}/install/fcos/agent-boot/${CLUSTER_NAME}.${DOMAIN}/agent-install.ign
initrd http://${INSTALL_HOST_IP}/install/fcos/${OKD_RELEASE}/initrd

boot
EOF

# cat << EOF > ${WORK_DIR}/ipxe-work-dir/${mac//:/-}.ipxe
# #!ipxe

# kernel http://${INSTALL_HOST_IP}/install/fcos/${OKD_RELEASE}/vmlinuz edd=off net.ifnames=1 ifname=nic0:${mac} ip=${ip_addr}::${DOMAIN_ROUTER}:${DOMAIN_NETMASK}:${hostname}:nic0:none nameserver=${DOMAIN_ROUTER} rd.neednet=1 coreos.inst.install_dev=/dev/nvme0n1 coreos.inst.ignition_url=http://${INSTALL_HOST_IP}/install/fcos/agent-boot/${CLUSTER_NAME}.${DOMAIN}/agent-install.ign coreos.inst.platform_id=${platform} initrd=initrd initrd=rootfs.img ${CONSOLE_OPT}
# initrd http://${INSTALL_HOST_IP}/install/fcos/${OKD_RELEASE}/initrd
# initrd http://${INSTALL_HOST_IP}/install/fcos/${OKD_RELEASE}/rootfs.img

# boot
# EOF

}

function copyFiles() {

  ${SSH} root@${INSTALL_HOST_IP} "mkdir -p /usr/local/www/install/fcos/agent-boot/${CLUSTER_NAME}.${DOMAIN}"
  ${SCP} ${WORK_DIR}/okd-install-dir/agent-install.ign root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/agent-boot/${CLUSTER_NAME}.${DOMAIN}/agent-install.ign
  # ${SCP} ${WORK_DIR}/okd-install-dir/agent.x86_64-initrd.img root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/agent-boot/${CLUSTER_NAME}.${DOMAIN}/initrd.img
  # ${SCP} ${WORK_DIR}/okd-install-dir/agent.x86_64-rootfs.img root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/agent-boot/${CLUSTER_NAME}.${DOMAIN}/rootfs.img
  # ${SCP} ${WORK_DIR}/okd-install-dir/agent.x86_64-vmlinuz root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/agent-boot/${CLUSTER_NAME}.${DOMAIN}/vmlinuz
  ${SSH} root@${INSTALL_HOST_IP} "chmod 644 /usr/local/www/install/fcos/agent-boot/${CLUSTER_NAME}.${DOMAIN}/*"
  ${SCP} -r ${WORK_DIR}/ipxe-work-dir/*.ipxe root@${DOMAIN_ROUTER}:/data/tftpboot/ipxe/
  ${SCP} ${WORK_DIR}/nginx-${CLUSTER_NAME}.conf root@${DOMAIN_ROUTER}:/usr/local/nginx/nginx-${CLUSTER_NAME}.conf
  ${SSH} root@${DOMAIN_ROUTER} "/etc/init.d/nginx restart"
}

function createBipIpRes() {

  local mac=${1}
  local ip_addr=${2}
  local hostname=${3}

  ${SSH} root@${DOMAIN_ROUTER} "IP_RES=\$(uci add dhcp host) ; \
  uci set dhcp.\${IP_RES}.mac=\"${mac}\" ; \
  uci set dhcp.\${IP_RES}.ip=\"${ip_addr}\" ; \
  uci set dhcp.\${IP_RES}.name=\"${hostname}\" ; \
  uci commit"
}

function deleteBipIpRes() {
  
  local mac=${1}

  host_idx=$(${SSH} root@${DOMAIN_ROUTER} "uci show dhcp | grep 'host\[' | grep \"${mac}\" | cut -d'[' -f2 | cut -d']' -f1")
  ${SSH} root@${DOMAIN_ROUTER} "uci delete dhcp.@host[${host_idx}] ; \
    uci commit ; \
    /etc/init.d/dnsmasq restart"
}

function createAgentLbConfig() {

  INTERFACE=$(echo "${CLUSTER_NAME//-/_}" | tr "[:upper:]" "[:lower:]")
  ${SSH} root@${DOMAIN_ROUTER} "uci set network.${INTERFACE}_api_lb=interface ; \
    uci set network.${INTERFACE}_api_lb.ifname=\"@lan\" ; \
    uci set network.${INTERFACE}_api_lb.proto=static ; \
    uci set network.${INTERFACE}_api_lb.hostname=${CLUSTER_NAME}-api-lb.${DOMAIN} ; \
    uci set network.${INTERFACE}_api_lb.ipaddr=${API_VIP}/${DOMAIN_NETMASK} ; \
    uci set network.${INTERFACE}_ingress_lb=interface ; \
    uci set network.${INTERFACE}_ingress_lb.ifname=\"@lan\" ; \
    uci set network.${INTERFACE}_ingress_lb.proto=static ; \
    uci set network.${INTERFACE}_ingress_lb.hostname=${CLUSTER_NAME}-ingress-lb.${DOMAIN} ; \
    uci set network.${INTERFACE}_ingress_lb.ipaddr=${INGRESS_VIP}/${DOMAIN_NETMASK} ; \
    uci commit ; \
    /etc/init.d/network reload ; \
    sleep 10"
}

function configNginx() {

cat << EOF > ${WORK_DIR}/nginx-${CLUSTER_NAME}.conf
stream {
    upstream okd4-api {
        server ${NODE_0_IP}:6443 max_fails=3 fail_timeout=1s;
        server ${NODE_1_IP}:6443 max_fails=3 fail_timeout=1s;
        server ${NODE_2_IP}:6443 max_fails=3 fail_timeout=1s;
    }
    upstream okd4-mc {
        server ${NODE_0_IP}:22623 max_fails=3 fail_timeout=1s;
        server ${NODE_1_IP}:22623 max_fails=3 fail_timeout=1s;
        server ${NODE_2_IP}:22623 max_fails=3 fail_timeout=1s;
    }
    upstream okd4-https {
        server ${NODE_0_IP}:443 max_fails=3 fail_timeout=1s;
        server ${NODE_1_IP}:443 max_fails=3 fail_timeout=1s;
        server ${NODE_2_IP}:443 max_fails=3 fail_timeout=1s;
    }
    upstream okd4-http {
        server ${NODE_0_IP}:80 max_fails=3 fail_timeout=1s;
        server ${NODE_1_IP}:80 max_fails=3 fail_timeout=1s;
        server ${NODE_2_IP}:80 max_fails=3 fail_timeout=1s;
    }
    server {
        listen ${API_VIP}:6443;
        proxy_pass okd4-api;
    }
    server {
        listen ${API_VIP}:22623;
        proxy_pass okd4-mc;
    }
    server {
        listen ${INGRESS_VIP}:443;
        proxy_pass okd4-https;
    }
    server {
        listen ${INGRESS_VIP}:80;
        proxy_pass okd4-http;
    }
}
EOF
}

# apiVersion: v1alpha1
# kind: AgentConfig
# metadata:
#   name: ${CLUSTER_NAME}
# rendezvousIP: ${NODE_0_IP}
# hosts:
# - hostname: ${NODE_0_NAME}
#   role: master
#   rootDeviceHints:
#     deviceName: "/dev/sda"
#   interfaces:
#   - name: nic0
#     macAddress: ${NODE_0_MAC}
#   networkConfig:
#     interfaces:
#     - name: nic0
#       type: ethernet
#       state: up
#       mac-address: 00:ef:44:21:e6:a5
#       ipv4:
#         enabled: true
#         address:
#         - ip: ${NODE_0_IP}
#           prefix-length: 24
#           dhcp: false
#     dns-resolver:
#       config:
#         server:
#         - ${DOMAIN_ROUTER}
#     routes:
#       config:
#       - destination: 0.0.0.0/0
#         next-hop-address: ${DOMAIN_ROUTER}
#         next-hop-interface: nic0
#         table-id: 254
# - hostname: ${NODE_1_NAME}
#   role: master
#   rootDeviceHints:
#     deviceName: "/dev/sda"
#   interfaces:
#   - name: nic0
#     macAddress: ${NODE_1_MAC}
#   networkConfig:
#     interfaces:
#     - name: nic0
#       type: ethernet
#       state: up
#       mac-address: 00:ef:44:21:e6:a5
#       ipv4:
#         enabled: true
#         address:
#         - ip: ${NODE_1_IP}
#           prefix-length: 24
#           dhcp: false
#     dns-resolver:
#       config:
#         server:
#         - ${DOMAIN_ROUTER}
#     routes:
#       config:
#       - destination: 0.0.0.0/0
#         next-hop-address: ${DOMAIN_ROUTER}
#         next-hop-interface: nic0
#         table-id: 254
# - hostname: ${NODE_2_NAME}
#   role: master
#   rootDeviceHints:
#     deviceName: "/dev/sda"
#   interfaces:
#   - name: nic0
#     macAddress: ${NODE_2_MAC}
#   networkConfig:
#     interfaces:
#     - name: nic0
#       type: ethernet
#       state: up
#       mac-address: 00:ef:44:21:e6:a5
#       ipv4:
#         enabled: true
#         address:
#         - ip: ${NODE_2_IP}
#           prefix-length: 24
#           dhcp: false
#     dns-resolver:
#       config:
#         server:
#         - ${DOMAIN_ROUTER}
#     routes:
#       config:
#       - destination: 0.0.0.0/0
#         next-hop-address: ${DOMAIN_ROUTER}
#         next-hop-interface: nic0
#         table-id: 254