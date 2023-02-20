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

  if [[ ! -d ${OKD_LAB_PATH}/boot-files ]]
  then
    getBootFile
  fi
  if [[ ${INIT} == "true" ]]
  then
    checkRouterModel ${INIT_IP}
    if [[ ${GL_MODEL} == "GL-AXT1800" ]]
    then
      initAxtRouter
    else
      initRouter
    fi
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
  GL_MODEL=$(${SSH} root@${router_ip} "uci get system.@system[0].hostname" )
  echo "Detected Router Model: ${GL_MODEL}"
  if [[ ${GL_MODEL} != "GL-AR750S"  ]] && [[ ${GL_MODEL} != "GL-MV1000"  ]] && [[ ${GL_MODEL} != "GL-AXT1800"  ]]
  then
    echo "Unsupported Router Model Detected.  These scripts only support configuration of GL-iNet AR-750S or MV1000 routers."
    exit 1
  fi
}

function initRouter() {
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
  ${SSH} root@${INIT_IP} "rm /etc/hotplug.d/block/11-mount"
  echo "Generating SSH keys"
  ${SSH} root@${INIT_IP} "rm -rf /root/.ssh ; rm -rf /data/* ; mkdir -p /root/.ssh ; dropbearkey -t rsa -s 4096 -f /root/.ssh/id_dropbear"
  echo "Copying workstation SSH key to router"
  cat ${OKD_LAB_PATH}/ssh_key.pub | ${SSH} root@${INIT_IP} "cat >> /etc/dropbear/authorized_keys"
  echo "Applying UCI config"
  ${SCP} ${WORK_DIR}/uci.batch root@${INIT_IP}:/tmp/uci.batch
  ${SSH} root@${INIT_IP} "cat /tmp/uci.batch | uci batch ; \
    /etc/init.d/lighttpd disable ; \
    /etc/init.d/lighttpd stop ; \
    passwd -l root ; \
    poweroff"
}

function initAxtRouter() {

cat << EOF > ${WORK_DIR}/uci.batch
set dropbear.@dropbear[0].PasswordAuth="off"
set dropbear.@dropbear[0].RootPasswordAuth="off"
set network.lan.ipaddr="${EDGE_ROUTER}"
set network.lan.netmask=${EDGE_NETMASK}
set network.lan.hostname=router.${LAB_DOMAIN}
commit
EOF

  ${SCP} ${WORK_DIR}/uci.batch root@${INIT_IP}:/tmp/uci.batch
  ${SSH} root@${INIT_IP} "cat /tmp/uci.batch | uci batch ; \
    rm -rf /root/.ssh ; \
    mkdir -p /root/.ssh ; \
    dropbearkey -t ed25519 -f /root/.ssh/id_dropbear ; \
    /etc/init.d/gl_nas_diskmanager disable ; \
    /etc/init.d/gl_nas_diskmanager stop ; \
    /etc/init.d/gl_nas_sys disable ; \
    /etc/init.d/gl_nas_sys stop ; \
    /etc/init.d/gl_nas_sys_dl disable ; \
    /etc/init.d/gl_nas_sys_dl stop ; \
    /etc/init.d/gl_nas_sys_up disable ; \
    /etc/init.d/gl_nas_sys_up stop ; \
    rm -rf /etc/hotplug.d/block ; \
    sed -i \"s|listen 80|listen 10.11.12.1:80|g\" /etc/nginx/conf.d/gl.conf ; \
    sed -i \"s|listen 443|listen 10.11.12.1:443|g\" /etc/nginx/conf.d/gl.conf ; \
    sed -i \"/listen \[::\]:80/d\" /etc/nginx/conf.d/gl.conf ; \
    sed -i \"/listen \[::\]:443/d\" /etc/nginx/conf.d/gl.conf ; \
    reboot"
}

function setupRouter() {

  if [[ ${EDGE} == "true" ]]
  then
    checkRouterModel ${EDGE_ROUTER}
    createDhcpConfig ${EDGE_ROUTER} ${LAB_DOMAIN}
    createIpxeHostConfig ${EDGE_ROUTER}
    createRouterDnsConfig  ${EDGE_ROUTER} ${LAB_DOMAIN} ${EDGE_ARPA} "edge"
    setupRouterCommon ${EDGE_ROUTER}
  else
    checkRouterModel ${DOMAIN_ROUTER}
    createDhcpConfig ${DOMAIN_ROUTER} ${DOMAIN}
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

function setupHaProxy() {

  local router_ip=${1}

  if [[ ${GL_MODEL} == "GL-AXT1800" ]]
  then
    ${SSH} root@${router_ip} "echo 'src/gz OpenWrt https://downloads.openwrt.org/snapshots/packages/arm_cortex-a7/packages' >> /etc/opkg/customfeeds.conf ; \
    opkg update ; \
    opkg install haproxy"
  else
    ${SSH} root@${router_ip} "opkg update ; \
    opkg install haproxy"
  fi
  ${SSH} root@${router_ip} "mv /etc/haproxy.cfg /etc/haproxy.cfg.orig ; \
    addgroup haproxy ; \
    adduser -g haproxy -h /data/haproxy -G haproxy haproxy -D -H -s /bin/false ; \
    mkdir -p /data/haproxy ; \
    chown -R haproxy:haproxy /data/haproxy ; \
    rm -f /etc/init.d/haproxy"
}

function setupRouterCommon() {

  local router_ip=${1}

  ${SSH} root@${router_ip} "opkg update && opkg install ip-full procps-ng-ps bind-server bind-tools bash uhttpd sfdisk rsync resize2fs wget block-mount wipefs"
  
  if [[ ${NO_LAB_PI} == "true" ]]
  then
    initMicroSD ${router_ip}
    ${SCP} ${WORK_DIR}/local-repos.repo root@${router_ip}:/usr/local/www/install/postinstall/local-repos.repo
    ${SCP} ${WORK_DIR}/chrony.conf root@${router_ip}:/usr/local/www/install/postinstall/chrony.conf
    ${SCP} ${WORK_DIR}/MirrorSync.sh root@${router_ip}:/root/bin/MirrorSync.sh
    ${SSH} root@${router_ip} "chmod 750 /root/bin/MirrorSync.sh"
    cat ~/.ssh/id_rsa.pub | ${SSH} root@${router_ip} "cat >> /usr/local/www/install/postinstall/authorized_keys"
  fi
  setupHaProxy ${router_ip}
  ${SSH} root@${router_ip} "mkdir -p /data/tftpboot/ipxe ; \
    mkdir /data/tftpboot/networkboot"
  ${SCP} ${OKD_LAB_PATH}/boot-files/ipxe.efi root@${router_ip}:/data/tftpboot/ipxe.efi
  ${SCP} ${WORK_DIR}/boot.ipxe root@${router_ip}:/data/tftpboot/boot.ipxe
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
    if [[ ${GL_MODEL} == "GL-AR750S" ]] || [[ ${GL_MODEL} == "GL-AXT1800" ]]
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
    if [[ ${GL_MODEL} == "GL-AR750S"  ]] || [[ ${GL_MODEL} == "GL-AXT1800" ]]
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

function getBootFile() {
  mkdir -p ${OKD_LAB_PATH}/boot-files
  wget http://boot.ipxe.org/ipxe.efi -O ${OKD_LAB_PATH}/boot-files/ipxe.efi
}

function initMicroSD() {

  local router_ip=${1}

  if [[ ${GL_MODEL} == "GL-AR750S" ]]
  then
    SD_DEV=sda
    SD_PART=sda1
  else
    SD_DEV=mmcblk0
    SD_PART=mmcblk0p1
  fi
  ${SSH} root@${router_ip} "mount | grep /dev/${SD_DEV} | while read line ; \
    do echo \${line} | cut -d' ' -f1 ; \
    done | while read fs ; \
    do umount \${fs} ;  \
    done ; \
    wipefs -af /dev/${SD_DEV} ; \
    echo \"/dev/${SD_PART} : start=1, type=83\" > /tmp/part.info ; \
    sfdisk --no-reread -f /dev/${SD_DEV} < /tmp/part.info ; \
    rm /tmp/part.info ; \
    mkfs.ext4 /dev/${SD_PART} ; \
    mkdir -p /usr/local ; \
    echo \"mounting /usr/local filesystem\" ; \
    let RC=0 ; \
    while [[ \${RC} -eq 0 ]] ; \
    do uci delete fstab.@mount[-1] ; \
    let RC=\$? ; \
    done; \
    PART_UUID=\$(block info /dev/${SD_PART} | cut -d\\\" -f2) ; \
    MOUNT=\$(uci add fstab mount) ; \
    uci set fstab.\${MOUNT}.target=/usr/local ; \
    uci set fstab.\${MOUNT}.uuid=\${PART_UUID} ; \
    uci set fstab.\${MOUNT}.enabled=1 ; \
    uci commit fstab ; \
    block mount ; \
    mkdir -p /usr/local/www/install ; \
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
