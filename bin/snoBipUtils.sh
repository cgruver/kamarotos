function createBipIpRes() {

  local hostname=${1}
  local ip_addr=${2}
  local mac=${3}

  ${SSH} root@${DOMAIN_ROUTER} "IP_RES=\$(uci add dhcp host) ; \
  uci set dhcp.\${IP_RES}.mac=\"${mac}\" ; \
  uci set dhcp.\${IP_RES}.ip=\"${ip_addr}\" ; \
  uci set dhcp.\${IP_RES}.name=\"${hostname}.${DOMAIN}\" ; \
  uci commit ; \
  /etc/init.d/dnsmasq restart"
}

function deleteBipIpRes() {
  
  local mac=${1}

  host_idx=$(${SSH} root@${DOMAIN_ROUTER} "uci show dhcp | grep 'host\[' | grep \"${mac}\" | cut -d'[' -f2 | cut -d']' -f1")
  ${SSH} root@${DOMAIN_ROUTER} "uci delete dhcp.@host[${host_idx}] ; \
    uci commit ; \
    /etc/init.d/dnsmasq restart"
}

function appendBootstrapInPlaceConfig() {
  install_dev=$(yq e ".control-plane.okd-hosts.[0].sno-install-dev" ${CLUSTER_CONFIG})

cat << EOF >> ${WORK_DIR}/install-config-upi.yaml
BootstrapInPlace:
  InstallationDisk: "${install_dev}"
EOF
}

function fixSnoBootDev() {

  boot_dev=$(yq e ".control-plane.okd-hosts.[0].boot-dev" ${CLUSTER_CONFIG})
  hostname=$(yq e ".control-plane.okd-hosts.[0].name" ${CLUSTER_CONFIG})
  ${SSH} -o ConnectTimeout=5 core@${hostname}.${DOMAIN} "sudo wipefs -a -f ${boot_dev} && sudo reboot"
}

function fixSnoLogs() {

  hostname=$(yq e ".control-plane.okd-hosts.[0].name" ${CLUSTER_CONFIG})
  ${SSH} -o ConnectTimeout=5 core@${hostname}.${DOMAIN} "sudo journalctl --rotate && sudo journalctl --vacuum-time=1s"
}

function fixSnoNetwork() {

  local mac=$(yq e ".control-plane.okd-hosts.[0].mac-addr" ${CLUSTER_CONFIG})
  local ip_addr=$(yq e ".control-plane.okd-hosts.[0].ip-addr" ${CLUSTER_CONFIG})
  local cidr=$(mask2cidr ${DOMAIN_NETMASK})
  local host_name=$(yq e ".control-plane.okd-hosts.[0].name" ${CLUSTER_CONFIG})

cat << EOF | butane | ${OC} apply -f -
variant: openshift
version: 4.12.0
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: patch-network
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

function prepHostPath() {

local hostpath_dev=$(yq e ".control-plane.okd-hosts.[0].hostpath-dev" ${CLUSTER_CONFIG})
local systemd_svc_name=$(echo ${hostpath_dev//\//-} | cut -d"-" -f2-)

cat << EOF | butane | ${OC} apply -f -
variant: openshift
version: 4.12.0
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: hostpath
systemd:
  units:
  - contents: |
      [Unit]
      Description=Make File System on ${hostpath_dev}
      DefaultDependencies=no
      BindsTo=${systemd_svc_name}.device
      After=${systemd_svc_name}.device var.mount
      Before=systemd-fsck@${systemd_svc_name}.service

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/lib/systemd/systemd-makefs ext4 ${hostpath_dev}
      TimeoutSec=0

      [Install]
      WantedBy=hostpath.mount
    enabled: true
    name: systemd-mkfs@${systemd_svc_name}.service
  - contents: |
      [Unit]
      Description=Mount ${hostpath_dev} to /var/hostpath
      Before=local-fs.target
      Requires=systemd-mkfs@${systemd_svc_name}.service
      After=systemd-mkfs@${systemd_svc_name}.service

      [Mount]
      What=${hostpath_dev}
      Where=/var/hostpath
      Type=ext4
      Options=defaults

      [Install]
      WantedBy=local-fs.target
    enabled: true
    name: var-hostpath.mount
EOF

}

function snoBipUtils() {

  for i in "$@"
  do
    case $i in
      -s|--sno)
        fixSnoBootDev
      ;;
      -l|--logs)
        fixSnoLogs
      ;;
      -n|--net)
        fixSnoNetwork
      ;;
      -p|--prep-hostpath)
        prepHostPath
      ;;
      *)
        # catch all
      ;;
    esac
  done
}