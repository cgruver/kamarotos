function configRouter() {
  EDGE="false"
  WLAN="false"
  WWAN="false"
  GL_MODEL=""
  INIT_IP=192.168.8.1
  wifi_channel=3
  WORK_DIR=${OKD_LAB_PATH}/work-dir-router
  rm -rf ${WORK_DIR}
  mkdir -p ${WORK_DIR}/dns
  
  for i in "$@"
  do
    case ${i} in
      -e|--edge)
        EDGE=true
      ;;
      -wl|--wireless-lan)
        WLAN="true"
      ;;
      -ww|--wireless-wan)
        WWAN="true"
      ;;
      -i|--init)
        INIT="true"
      ;;
      -s|--setup)
        SETUP="true"
      ;;
      -aw|--add-wireless)
        ADD_WIRELESS="true"
      ;;
      *)
        # catch all
      ;;
    esac
  done

  if [[ ${INIT} == "true" ]]
  then
    initRouter
  elif [[ ${SETUP} == "true" ]]
  then
    setupRouter
  elif [[ ${ADD_WIRELESS} == "true" ]]
  then
    addWireless
  fi
}

function checkRouterModel() {
  local router_ip=${1}
  GL_MODEL=$(${SSH} root@${router_ip} "uci get glconfig.general.model" )
  echo "Detected Router Model: ${GL_MODEL}"
  if [[ ${GL_MODEL} != "ar750s"  ]] && [[ ${GL_MODEL} != "mv1000"  ]]
  then
    echo "Unsupported Router Model Detected.  These scripts only support configuration of GL-iNet AR-750S or MV1000 routers."
    exit 1
  fi
}

function initRouter() {
  checkRouterModel ${INIT_IP}
  if [[ ${EDGE} == "true" ]]
  then
    initEdge
  else
    initDomain
    ${SSH} root@${INIT_IP} "FW=\$(uci add firewall forwarding) ; \
      uci set firewall.\${FW}.src=wan ; \
      uci set firewall.\${FW}.dest=lan ; \
      uci commit firewall"
  fi
  echo "Generating SSH keys"
  ${SSH} root@${INIT_IP} "rm -rf /root/.ssh ; rm -rf /data/* ; mkdir -p /root/.ssh ; dropbearkey -t rsa -s 4096 -f /root/.ssh/id_dropbear"
  echo "Copying workstation SSH key to router"
  cat ${OKD_LAB_PATH}/ssh_key.pub | ${SSH} root@${INIT_IP} "cat >> /etc/dropbear/authorized_keys"
  echo "Applying UCI config"
  ${SCP} ${WORK_DIR}/uci.batch root@${INIT_IP}:/tmp/uci.batch
  ${SSH} root@${INIT_IP} "cat /tmp/uci.batch | uci batch ; passwd -l root ; poweroff"
}

function setupRouter() {
  
  if [[ ${EDGE} == "true" ]]
  then
    checkRouterModel ${EDGE_ROUTER}
    createDhcpConfig ${LAB_DOMAIN}
    createIpxeHostConfig ${EDGE_ROUTER}
    createRouterDnsConfig  ${EDGE_ROUTER} ${LAB_DOMAIN} ${EDGE_ARPA} "edge"
    setupRouterCommon ${EDGE_ROUTER}
  else
    checkRouterModel ${DOMAIN_ROUTER}
    createDhcpConfig ${DOMAIN}
    createIpxeHostConfig ${DOMAIN_ROUTER}
    createRouterDnsConfig  ${DOMAIN_ROUTER} ${DOMAIN} ${DOMAIN_ARPA} "domain"
    ${SSH} root@${EDGE_ROUTER} "unset ROUTE ; \
      ROUTE=\$(uci add network route) ; \
      uci set network.\${ROUTE}.interface=lan ; \
      uci set network.\${ROUTE}.target=${DOMAIN_NETWORK} ; \
      uci set network.\${ROUTE}.netmask=${DOMAIN_NETMASK} ; \
      uci set network.\${ROUTE}.gateway=${DOMAIN_ROUTER_EDGE} ; \
      uci commit network ; \
      /etc/init.d/network restart"
    pause 15 "Give the Router network time to restart"
    ${SSH} root@${EDGE_ROUTER} "/etc/init.d/named stop && /etc/init.d/named start"
    cat ${WORK_DIR}/edge-zone | ${SSH} root@${EDGE_ROUTER} "cat >> /etc/bind/named.conf"
    setupRouterCommon ${DOMAIN_ROUTER}
  fi
}

function setupRouterCommon() {

  local router_ip=${1}

  ${SSH} root@${router_ip} "opkg update && opkg install ip-full procps-ng-ps bind-server bind-tools haproxy bash shadow uhttpd sfdisk rsync resize2fs wget block-mount"
  if [[ ${GL_MODEL} == "ar750s"  ]]
  then
    initMicroSD ${router_ip}
  fi
  ${SSH} root@${router_ip} "mv /etc/haproxy.cfg /etc/haproxy.cfg.orig ; \
    /etc/init.d/lighttpd disable ; \
    /etc/init.d/lighttpd stop ; \
    groupadd haproxy ; \
    useradd -d /data/haproxy -g haproxy haproxy ; \
    mkdir -p /data/haproxy ; \
    chown -R haproxy:haproxy /data/haproxy ; \
    rm -f /etc/init.d/haproxy ; \
    /etc/init.d/uhttpd enable ; \
    mkdir -p /data/tftpboot/ipxe ; \
    mkdir /data/tftpboot/networkboot"
  if [[ ! -d ${OKD_LAB_PATH}/boot-files ]]
  then
    getBootFiles
  fi
  ${SCP} ${OKD_LAB_PATH}/boot-files/ipxe.efi root@${router_ip}:/data/tftpboot/ipxe.efi
  ${SCP} ${OKD_LAB_PATH}/boot-files/vmlinuz root@${router_ip}:/data/tftpboot/networkboot/vmlinuz
  ${SCP} ${OKD_LAB_PATH}/boot-files/initrd.img root@${router_ip}:/data/tftpboot/networkboot/initrd.img
  ${SCP} ${WORK_DIR}/boot.ipxe root@${router_ip}:/data/tftpboot/boot.ipxe
  ${SCP} ${WORK_DIR}/local-repos.repo root@${BASTION_HOST}:/usr/local/www/install/postinstall/local-repos.repo
  ${SCP} ${WORK_DIR}/chrony.conf root@${BASTION_HOST}:/usr/local/www/install/postinstall/chrony.conf
  ${SCP} ${WORK_DIR}/MirrorSync.sh root@${BASTION_HOST}:/root/bin/MirrorSync.sh
  ${SSH} root@${BASTION_HOST} "chmod 750 /root/bin/MirrorSync.sh"
  ${SCP} -r ${WORK_DIR}/dns/* root@${router_ip}:/etc/bind/
  ${SSH} root@${router_ip} "mkdir -p /data/var/named/dynamic ; \
    mkdir /data/var/named/data ; \
    chown -R bind:bind /data/var/named ; \
    chown -R bind:bind /etc/bind ; \
    /etc/init.d/named disable ; \
    sed -i \"s|START=50|START=99|g\" /etc/init.d/named ; \
    /etc/init.d/named enable ; \
    uci set network.wan.dns=${router_ip} ; \
    uci set network.wan.peerdns=0 ; \
    uci show network.wwan ; \
    if [[ \$? -eq 0 ]] ; \
    then uci set network.wwan.dns=${router_ip} ; \
      uci set network.wwan.peerdns=0 ; \
    fi ; \
    uci commit"
  echo "commit" >> ${WORK_DIR}/uci.batch
  ${SCP} ${WORK_DIR}/uci.batch root@${router_ip}:/tmp/uci.batch
  ${SSH} root@${router_ip} "cat /tmp/uci.batch | uci batch ; reboot"

  if [[ ${EDGE} == "false" ]]
  then
    ${SSH} root@${EDGE_ROUTER} "/etc/init.d/named stop && /etc/init.d/named start"
  fi
}

function initEdge() {

cat << EOF > ${WORK_DIR}/uci.batch
set dropbear.@dropbear[0].PasswordAuth="off"
set dropbear.@dropbear[0].RootPasswordAuth="off"
set network.lan.ipaddr="${EDGE_ROUTER}"
set network.lan.netmask=${EDGE_NETMASK}
set network.lan.hostname=router.${LAB_DOMAIN}
delete network.wan6
set dhcp.lan.leasetime="5m"
set dhcp.lan.start="225"
set dhcp.lan.limit="30"
add_list dhcp.lan.dhcp_option="6,${EDGE_ROUTER}"
EOF

  if [[ ${WWAN} == "true" ]]
  then
    echo "Listing available Wireless Networks:"
    ${SSH} root@${INIT_IP} "iwinfo wlan0 scan | grep -E 'ESSID|Mode'"
    echo ""
    echo "Enter the ESSID of the Wireless Lan that you are connecting to:"
    read wan_wifi_ssid
    echo "Enter the Channel of the Wireless Lan that you are connecting to:"
    read wwan_channel
    echo "Enter the passphrase of the wireless lan that you are connecting to:"
    read wan_wifi_key

    unset zone
    let i=0
    let j=1
    while [[ ${j} -eq 1 ]]
    do
      zone=$(${SSH} root@${INIT_IP} "uci get firewall.@zone[${i}].name")
      let rc=${?}
      if [[ ${rc} -ne 0 ]]
      then
        let j=2
      elif [[ ${zone} == "wan" ]]
      then
        let j=0
      else
        let i=${i}+1
      fi
    done
    if [[ ${j} -eq 0 ]]
    then
      echo "add_list firewall.@zone[${i}].network=wwan" >> ${WORK_DIR}/uci.batch
    else
      echo "FIREWALL ZONE NOT FOUND, CCONFIGURE MANUALLY WITH LUCI"
    fi
    if [[ ${GL_MODEL} == "ar750s"  ]]
    then
      configWwanAR750S "${wan_wifi_ssid}" "${wan_wifi_key}" ${wwan_channel}
    else
      configWwanMV1000W "${wan_wifi_ssid}" "${wan_wifi_key}" ${wwan_channel}
    fi
  fi

  if [[ ${WLAN} == "true" ]]
  then
    echo "Enter an SSID for your Lab Wireless LAN:"
    read lab_wifi_ssid
    echo "Enter a WPA/PSK 2 Passphrase for your Lab Wireless LAN:"
    read lab_wifi_key
    if [[ ${GL_MODEL} == "ar750s"  ]]
    then
      configWlanAR750S "${lab_wifi_ssid}" "${lab_wifi_key}" ${wwan_channel} ${wifi_channel}
    else
      configWlanMV1000W "${lab_wifi_ssid}" "${lab_wifi_key}" ${wwan_channel}
    fi
  fi

  echo "commit" >> ${WORK_DIR}/uci.batch
}

function initDomain() {

cat << EOF >> ${WORK_DIR}/uci.batch
set dropbear.@dropbear[0].PasswordAuth='off'
set dropbear.@dropbear[0].RootPasswordAuth='off'
set network.wan.proto=static
set network.wan.ipaddr=${DOMAIN_ROUTER_EDGE}
set network.wan.netmask=${EDGE_NETMASK}
set network.wan.gateway=${EDGE_ROUTER}
set network.wan.hostname=router.${DOMAIN}
set network.wan.dns=${EDGE_ROUTER}
set network.lan.ipaddr=${DOMAIN_ROUTER}
set network.lan.netmask=${DOMAIN_NETMASK}
set network.lan.hostname=router.${DOMAIN}
delete network.guest
delete network.wan6
set system.@system[0].hostname=router.${DOMAIN}
EOF

unset zone
let i=0
let j=1
while [[ ${j} -eq 1 ]]
do
  zone=$(${SSH} root@${INIT_IP} "uci get firewall.@zone[${i}].name")
  let rc=${?}
  if [[ ${rc} -ne 0 ]]
  then
    let j=2
   elif [[ ${zone} == "wan" ]]
   then
     let j=0
   else
     let i=${i}+1
   fi
done
if [[ ${j} -eq 0 ]]
then
  echo "set firewall.@zone[${i}].input='ACCEPT'" >> ${WORK_DIR}/uci.batch
  echo "set firewall.@zone[${i}].output='ACCEPT'" >> ${WORK_DIR}/uci.batch
  echo "set firewall.@zone[${i}].forward='ACCEPT'" >> ${WORK_DIR}/uci.batch
  echo "set firewall.@zone[${i}].masq='0'" >> ${WORK_DIR}/uci.batch
else
  echo "FIREWALL ZONE NOT FOUND, CCONFIGURE MANUALLY WITH LUCI"
fi
echo "commit" >> ${WORK_DIR}/uci.batch
}

function getBootFiles() {
  mkdir -p ${OKD_LAB_PATH}/boot-files
  wget http://boot.ipxe.org/ipxe.efi -O ${OKD_LAB_PATH}/boot-files/ipxe.efi
  wget http://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/isolinux/vmlinuz -O ${OKD_LAB_PATH}/boot-files/vmlinuz
  wget http://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/isolinux/initrd.img -O ${OKD_LAB_PATH}/boot-files/initrd.img
}

function initMicroSD() {

  local router_ip=${1}

  ${SSH} root@${router_ip} "mount | grep /dev/sda | while read line ; \
    do echo \${line} | cut -d' ' -f1 ; \
    done | while read fs ; \
    do umount \${fs} ;  \
    done ; \
    dd if=/dev/zero of=/dev/sda bs=4096 count=1 ; \
    echo \"/dev/sda1 : start=1, type=83\" > /tmp/part.info ; \
    sfdisk --no-reread -f /dev/sda < /tmp/part.info ; \
    rm /tmp/part.info ; \
    umount /dev/sda1 ; \
    mkfs.ext4 /dev/sda1 ; \
    mkdir -p /usr/local ; \
    umount /dev/sda1 ; \
    echo \"mounting /usr/local filesystem\" ; \
    let RC=0 ; \
    while [[ \${RC} -eq 0 ]] ; \
    do uci delete fstab.@mount[-1] ; \
    let RC=\$? ; \
    done; \
    PART_UUID=\$(block info /dev/sda1 | cut -d\\\" -f2) ; \
    MOUNT=\$(uci add fstab mount) ; \
    uci set fstab.\${MOUNT}.target=/usr/local ; \
    uci set fstab.\${MOUNT}.uuid=\${PART_UUID} ; \
    uci set fstab.\${MOUNT}.enabled=1 ; \
    uci commit fstab ; \
    block mount ; \
    mkdir -p /usr/local/www/install ; \
    mkdir -p /usr/local/tftpboot/networkboot ; \
    ln -s /usr/local /data ; \
    ln -s /usr/local/www/install /www/install ; \
    mkdir -p /usr/local/www/install/kickstart ; \
    mkdir /usr/local/www/install/postinstall ; \
    mkdir /usr/local/www/install/fcos ; \
    mkdir -p /root/bin ; \
    for i in BaseOS AppStream ; \
    do mkdir -p /usr/local/www/install/repos/\${i}/x86_64/os/ ; \
    done ;\
    dropbearkey -y -f /root/.ssh/id_dropbear | grep \"ssh-\" > /usr/local/www/install/postinstall/authorized_keys"
}
