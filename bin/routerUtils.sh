function configRouter() {
  EDGE="false"
  WLAN="false"
  WWAN="false"
  INIT_IP=192.168.8.1
  WIFI_CHANNEL=3
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

function initRouter() {
  if [[ ${EDGE} == "true" ]]
  then
    labenv -e
    if [[ ${LAB_CTX_ERROR} == "true" ]]
    then
      exit 1
    fi
    initEdge
  else
    if [[ -z ${SUB_DOMAIN} ]]
    then
      labctx
    else
      labctx ${SUB_DOMAIN}
    fi
    if [[ ${LAB_CTX_ERROR} == "true" ]]
    then
      exit 1
    fi
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
  ${SSH} root@${INIT_IP} "cat /tmp/uci.batch | uci batch ; passwd -l root ; reboot"
}

function setupRouter() {
  if [[ ${EDGE} == "true" ]]
  then
    labenv -e
    if [[ ${LAB_CTX_ERROR} == "true" ]]
    then
      exit 1
    fi
    setupEdge
    ${SSH} root@${EDGE_ROUTER} "opkg update && opkg install ip-full procps-ng-ps bind-server bind-tools sfdisk rsync resize2fs wget"
    setupRouterCommon ${EDGE_ROUTER}
  else
    if [[ -z ${SUB_DOMAIN} ]]
    then
      labctx
    else
      labctx ${SUB_DOMAIN}
    fi
    if [[ ${LAB_CTX_ERROR} == "true" ]]
    then
      exit 1
    fi
    setupDomain
    ${SSH} root@${EDGE_ROUTER} "unset ROUTE ; \
      ROUTE=\$(uci add network route) ; \
      uci set network.\${ROUTE}.interface=lan ; \
      uci set network.\${ROUTE}.target=${DOMAIN_NETWORK} ; \
      uci set network.\${ROUTE}.netmask=${DOMAIN_NETMASK} ; \
      uci set network.\${ROUTE}.gateway=${DOMAIN_ROUTER_EDGE} ; \
      uci commit network ; \
      /etc/init.d/network restart"
    pause 5 "Give the Router network time to restart"
    ${SSH} root@${EDGE_ROUTER} "/etc/init.d/named restart"
    ${SSH} root@${DOMAIN_ROUTER} "opkg update && opkg install ip-full procps-ng-ps bind-server bind-tools haproxy bash shadow uhttpd wget ; \
      mv /etc/haproxy.cfg /etc/haproxy.cfg.orig ; \
      /etc/init.d/lighttpd disable ; \
      /etc/init.d/lighttpd stop ; \
      groupadd haproxy ; \
      useradd -d /data/haproxy -g haproxy haproxy ; \
      mkdir -p /data/haproxy ; \
      chown -R haproxy:haproxy /data/haproxy ; \
      rm -f /etc/init.d/haproxy ; \
      /etc/init.d/uhttpd enable"
    cat ${WORK_DIR}/edge-zone | ${SSH} root@${EDGE_ROUTER} "cat >> /etc/bind/named.conf"
    setupRouterCommon ${DOMAIN_ROUTER}
  fi
}

function setupRouterCommon() {

  local router_ip=${1}

cat << EOF > ${WORK_DIR}/boot.ipxe
#!ipxe
   
echo ========================================================
echo UUID: \${uuid}
echo Manufacturer: \${manufacturer}
echo Product name: \${product}
echo Hostname: \${hostname}
echo
echo MAC address: \${net0/mac}
echo IP address: \${net0/ip}
echo IPv6 address: \${net0.ndp.0/ip6:ipv6}
echo Netmask: \${net0/netmask}
echo
echo Gateway: \${gateway}
echo DNS: \${dns}
echo IPv6 DNS: \${dns6}
echo Domain: \${domain}
echo ========================================================
   
chain --replace --autofree ipxe/\${mac:hexhyp}.ipxe
EOF

# cat << "EOF" > /etc/hotplug.d/iface/30-named
# if [ "${ACTION}" = "ifup" -o "${ACTION}" = "ifupdate" ]
# then /etc/init.d/named restart
# fi
# EOF

  if [[ ! -d ${OKD_LAB_PATH}/boot-files ]]
  then
    getBootFiles
  fi

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
    uci commit ; \
    mkdir -p /data/tftpboot/ipxe ; \
    mkdir /data/tftpboot/networkboot"
  ${SCP} ${OKD_LAB_PATH}/boot-files/ipxe.efi root@${router_ip}:/data/tftpboot/ipxe.efi
  ${SCP} ${OKD_LAB_PATH}/boot-files/vmlinuz root@${router_ip}:/data/tftpboot/networkboot/vmlinuz
  ${SCP} ${OKD_LAB_PATH}/boot-files/initrd.img root@${router_ip}:/data/tftpboot/networkboot/initrd.img
  ${SCP} ${WORK_DIR}/boot.ipxe root@${router_ip}:/data/tftpboot/boot.ipxe
  ${SCP} ${WORK_DIR}/uci.batch root@${router_ip}:/tmp/uci.batch
  ${SSH} root@${router_ip} "cat /tmp/uci.batch | uci batch ; reboot"

  if [[ ${EDGE} == "false" ]]
  then
    ${SSH} root@${EDGE_ROUTER} "/etc/init.d/named restart"
  fi
}

function configWwanMV1000W() {

local wifi_ssid=${1}
local wifi_key=${2}

cat << EOF >> ${WORK_DIR}/uci.batch
set wireless.radio2.disabled="0"
set wireless.radio2.repeater="1"
set wireless.radio2.legacy_rates="0"
set wireless.radio2.htmode="HT20"
set wireless.sta=wifi-iface
set wireless.sta.device="radio2"
set wireless.sta.ifname="wlan2"
set wireless.sta.mode="sta"
set wireless.sta.disabled="0"
set wireless.sta.network="wwan"
set wireless.sta.wds="0"
set wireless.sta.ssid="${wifi_ssid}"  
set wireless.sta.encryption="psk2"      
set wireless.sta.key="${wifi_key}"    
set network.wwan=interface
set network.wwan.proto="dhcp"
set network.wwan.metric="20"
EOF
}

function configWwanAR750S() {

  local wifi_ssid=${1}
  local wifi_key=${2}

cat << EOF >> ${WORK_DIR}/uci.batch
set wireless.radio0.repeater="1"
set wireless.radio0.org_htmode='VHT80'
set wireless.radio0.htmode='HT20'
set wireless.sta=wifi-iface
set wireless.sta.device='radio0'
set wireless.sta.network='wwan'
set wireless.sta.mode='sta'
set wireless.sta.ifname='wlan-sta'
set wireless.sta.ssid="${wifi_ssid}"
set wireless.sta.encryption='psk-mixed'
set wireless.sta.key="${wifi_key}"
set wireless.sta.disabled='0'
set network.wwan=interface
set network.wwan.proto='dhcp'
set network.wwan.metric='20'
EOF
}

function configWlanMV1000W() {

local wifi_ssid=${1}
local wifi_key=${2}

cat << EOF >> ${WORK_DIR}/uci.batch
delete network.guest
delete dhcp.guest
delete wireless.guest2g
delete wireless.sta2
set wireless.default_radio0=wifi-iface
set wireless.default_radio0.device="radio0"
set wireless.default_radio0.ifname="wlan0"
set wireless.default_radio0.network="lan"
set wireless.default_radio0.mode="ap"
set wireless.default_radio0.disabled="0"
set wireless.default_radio0.ssid="${wifi_ssid}"
set wireless.default_radio0.key="${wifi_key}"
set wireless.default_radio0.encryption="psk2"
set wireless.default_radio0.multi_ap="1"
set wireless.radio0.legacy_rates="0"
set wireless.radio0.htmode="HT20"
set wireless.radio0.channel=${WIFI_CHANNEL}
EOF

}

function configWlanAR750S() {

local wifi_ssid=${1}
local wifi_key=${2}

cat << EOF >> ${WORK_DIR}/uci.batch
set wireless.default_radio0=wifi-iface
set wireless.default_radio0.device='radio0'
set wireless.default_radio0.network='lan'
set wireless.default_radio0.mode='ap'
set wireless.default_radio0.key="${wifi_key}"
set wireless.default_radio0.disassoc_low_ack='0'
set wireless.default_radio0.ifname='wlan0'
set wireless.default_radio0.wds='1'
set wireless.default_radio0.ssid="${wifi_ssid}"
set wireless.default_radio0.encryption='sae-mixed'
set wireless.default_radio1.key="${wifi_key}"
set wireless.default_radio1.wds='1'
set wireless.default_radio1.disassoc_low_ack='0'
set wireless.default_radio1.ifname='wlan1'
set wireless.default_radio1.ssid="${wifi_ssid}"
set wireless.default_radio1.encryption='sae-mixed'
delete wireless.guest5g
delete wireless.guest2g
delete network.guest
delete dhcp.guest
EOF
}

function initEdge() {

  WLAN_DEV=wlan0
  GL_MODEL=$(${SSH} root@${INIT_IP} "uci get glconfig.general.model" )
  echo "Detected Router Model: ${GL_MODEL}"
  if [[ ${GL_MODEL} != "ar750s"  ]] && [[ ${GL_MODEL} != "mv1000"  ]]
  then
    echo "Unsupported Router Model Detected.  These scripts only support configuration of GL-iNet AR-750S or MV1000 routers."
    exit 1
  fi

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
    ${SSH} root@${INIT_IP} "iwinfo ${WLAN_DEV} scan"
    echo ""
    echo "Enter the SSID of the Wireless Lan that you are connecting to:"
    read WIFI_SSID
    echo "Enter the passphrase of the wireless lan that you are connecting to:"
    read WIFI_KEY

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
      configWwanAR750S ${WIFI_SSID} ${WIFI_KEY}
    else
      configWwanMV1000W ${WIFI_SSID} ${WIFI_KEY}
    fi
  fi

  if [[ ${WLAN} == "true" ]]
  then
    echo "Enter an SSID for you Lab Wireless LAN:"
    read LAB_WIFI_SSID
    echo "Enter a WPA/PSK 2 Passphrase for your Lab Wireless LAN:"
    read LAB_WIFI_KEY
    if [[ ${GL_MODEL} == "ar750s"  ]]
    then
      configWlanAR750S ${LAB_WIFI_SSID} ${LAB_WIFI_KEY}
    else
      configWlanMV1000W ${LAB_WIFI_SSID} ${LAB_WIFI_KEY}
    fi
  fi

  echo "commit" >> ${WORK_DIR}/uci.batch
}

function setupEdge() {

cat << EOF > ${WORK_DIR}/uci.batch
set dhcp.@dnsmasq[0].domain=${LAB_DOMAIN}
set dhcp.@dnsmasq[0].localuse=0
set dhcp.@dnsmasq[0].cachelocal=0
set dhcp.@dnsmasq[0].port=0
commit
EOF

cat << EOF > ${WORK_DIR}/dns/named.conf
acl "trusted" {
 ${EDGE_NETWORK}/${EDGE_CIDR};
 127.0.0.1;
};

options {
listen-on port 53 { 127.0.0.1; ${EDGE_ROUTER}; };
   
directory  "/data/var/named";
dump-file  "/data/var/named/data/cache_dump.db";
statistics-file "/data/var/named/data/named_stats.txt";
memstatistics-file "/data/var/named/data/named_mem_stats.txt";
allow-query     { trusted; };

recursion yes;

dnssec-validation yes;

/* Path to ISC DLV key */
bindkeys-file "/etc/bind/bind.keys";

managed-keys-directory "/data/var/named/dynamic";

pid-file "/var/run/named/named.pid";
session-keyfile "/var/run/named/session.key";

};

logging {
      channel default_debug {
               file "data/named.run";
               severity dynamic;
      };
};

zone "${LAB_DOMAIN}" {
   type master;
   file "/etc/bind/db.${LAB_DOMAIN}"; # zone file path
};

zone "${EDGE_ARPA}.in-addr.arpa" {
   type master;
   file "/etc/bind/db.${EDGE_ARPA}";
};

zone "localhost" {
   type master;
   file "/etc/bind/db.local";
};

zone "127.in-addr.arpa" {
   type master;
   file "/etc/bind/db.127";
};

zone "0.in-addr.arpa" {
   type master;
   file "/etc/bind/db.0";
};

zone "255.in-addr.arpa" {
   type master;
   file "/etc/bind/db.255";
};

EOF

cat << EOF > ${WORK_DIR}/dns/db.${LAB_DOMAIN}
@       IN      SOA     router.${LAB_DOMAIN}. admin.${LAB_DOMAIN}. (
            3          ; Serial
            604800     ; Refresh
            86400     ; Retry
            2419200     ; Expire
            604800 )   ; Negative Cache TTL
;
; name servers - NS records
   IN      NS     router.${LAB_DOMAIN}.

; name servers - A records
router.${LAB_DOMAIN}.         IN      A      ${EDGE_ROUTER}

; ${EDGE_NETWORK}/${EDGE_CIDR} - A records
EOF

cat << EOF > ${WORK_DIR}/dns/db.${EDGE_ARPA}
@       IN      SOA     router.${LAB_DOMAIN}. admin.${LAB_DOMAIN}. (
                              3         ; Serial
                        604800         ; Refresh
                        86400         ; Retry
                        2419200         ; Expire
                        604800 )       ; Negative Cache TTL

; name servers - NS records
      IN      NS      router.${LAB_DOMAIN}.

; PTR Records
1    IN      PTR     router.${LAB_DOMAIN}.
EOF

}

function initDomain() {

cat << EOF >> ${WORK_DIR}/uci.batch
set dropbear.@dropbear[0].PasswordAuth='off'
set dropbear.@dropbear[0].RootPasswordAuth='off'
set network.wan.proto=static
set network.wan.ipaddr=${DOMAIN_ROUTER_EDGE}
set network.wan.netmask=${EDGE_NETMASK}
set network.wan.gateway=${EDGE_ROUTER}
set network.wan.hostname=router.${SUB_DOMAIN}.${LAB_DOMAIN}
set network.wan.dns=${EDGE_ROUTER}
set network.lan.ipaddr=${DOMAIN_ROUTER}
set network.lan.netmask=${DOMAIN_NETMASK}
set network.lan.hostname=router.${SUB_DOMAIN}.${LAB_DOMAIN}
delete network.guest
delete network.wan6
set system.@system[0].hostname=router.${SUB_DOMAIN}.${LAB_DOMAIN}
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

function setupDomain() {

cat << EOF > ${WORK_DIR}/uci.batch
add_list dhcp.lan.dhcp_option="6,${DOMAIN_ROUTER}"
set dhcp.lan.leasetime="5m"
set dhcp.@dnsmasq[0].enable_tftp=1
set dhcp.@dnsmasq[0].tftp_root=/data/tftpboot
set dhcp.efi64_boot_1=match
set dhcp.efi64_boot_1.networkid='set:efi64'
set dhcp.efi64_boot_1.match='60,PXEClient:Arch:00007'
set dhcp.efi64_boot_2=match
set dhcp.efi64_boot_2.networkid='set:efi64'
set dhcp.efi64_boot_2.match='60,PXEClient:Arch:00009'
set dhcp.ipxe_boot=userclass
set dhcp.ipxe_boot.networkid='set:ipxe'
set dhcp.ipxe_boot.userclass='iPXE'
set dhcp.uefi=boot
set dhcp.uefi.filename='tag:efi64,tag:!ipxe,ipxe.efi'
set dhcp.uefi.serveraddress="${DOMAIN_ROUTER}"
set dhcp.uefi.servername='pxe'
set dhcp.uefi.force='1'
set dhcp.ipxe=boot
set dhcp.ipxe.filename='tag:ipxe,boot.ipxe'
set dhcp.ipxe.serveraddress="${DOMAIN_ROUTER}"
set dhcp.ipxe.servername='pxe'
set dhcp.ipxe.force='1'
set dhcp.@dnsmasq[0].domain=${SUB_DOMAIN}.${LAB_DOMAIN}
set dhcp.@dnsmasq[0].localuse=0
set dhcp.@dnsmasq[0].cachelocal=0
set dhcp.@dnsmasq[0].port=0
del_list uhttpd.main.listen_http="[::]:80"
del_list uhttpd.main.listen_http="0.0.0.0:80"
del_list uhttpd.main.listen_https="[::]:443"
del_list uhttpd.main.listen_https="0.0.0.0:443"
add_list uhttpd.main.listen_http="${DOMAIN_ROUTER}:80"
add_list uhttpd.main.listen_https="${DOMAIN_ROUTER}:443"
add_list uhttpd.main.listen_http="127.0.0.1:80"
add_list uhttpd.main.listen_https="127.0.0.1:443"
commit
EOF

cat << EOF > ${WORK_DIR}/edge-zone
zone "${SUB_DOMAIN}.${LAB_DOMAIN}" {
    type stub;
    masters { ${DOMAIN_ROUTER}; };
    file "stub.${SUB_DOMAIN}.${LAB_DOMAIN}";
};

EOF

cat << EOF > ${WORK_DIR}/dns/named.conf
acl "trusted" {
 ${DOMAIN_NETWORK}/${DOMAIN_CIDR};
 ${EDGE_NETWORK}/${EDGE_CIDR};
 127.0.0.1;
};

options {
 listen-on port 53 { 127.0.0.1; ${DOMAIN_ROUTER}; };
 
 directory  "/data/var/named";
 dump-file  "/data/var/named/data/cache_dump.db";
 statistics-file "/data/var/named/data/named_stats.txt";
 memstatistics-file "/data/var/named/data/named_mem_stats.txt";
 allow-query     { trusted; };

 recursion yes;

 forwarders { ${EDGE_ROUTER}; };

 dnssec-validation yes;

 /* Path to ISC DLV key */
 bindkeys-file "/etc/bind/bind.keys";

 managed-keys-directory "/data/var/named/dynamic";

 pid-file "/var/run/named/named.pid";
 session-keyfile "/var/run/named/session.key";

};

logging {
        channel default_debug {
                file "data/named.run";
                severity dynamic;
        };
};

zone "." IN {
 type hint;
 file "/etc/bind/db.root";
};

zone "${SUB_DOMAIN}.${LAB_DOMAIN}" {
    type master;
    file "/etc/bind/db.${SUB_DOMAIN}.${LAB_DOMAIN}"; # zone file path
};

zone "${DOMAIN_ARPA}.in-addr.arpa" {
    type master;
    file "/etc/bind/db.${DOMAIN_ARPA}";
};

zone "localhost" {
    type master;
    file "/etc/bind/db.local";
};

zone "127.in-addr.arpa" {
    type master;
    file "/etc/bind/db.127";
};

zone "0.in-addr.arpa" {
    type master;
    file "/etc/bind/db.0";
};

zone "255.in-addr.arpa" {
    type master;
    file "/etc/bind/db.255";
};

EOF

cat << EOF > ${WORK_DIR}/dns/db.${SUB_DOMAIN}.${LAB_DOMAIN}
@       IN      SOA     router.${SUB_DOMAIN}.${LAB_DOMAIN}. admin.${SUB_DOMAIN}.${LAB_DOMAIN}. (
             3          ; Serial
             604800     ; Refresh
              86400     ; Retry
            2419200     ; Expire
             604800 )   ; Negative Cache TTL
;
; name servers - NS records
    IN      NS     router.${SUB_DOMAIN}.${LAB_DOMAIN}.

; name servers - A records
router.${SUB_DOMAIN}.${LAB_DOMAIN}.         IN      A      ${DOMAIN_ROUTER}

; ${DOMAIN_NETWORK}/${DOMAIN_CIDR} - A records
EOF

cat << EOF > ${WORK_DIR}/dns/db.${DOMAIN_ARPA}
@       IN      SOA     router.${SUB_DOMAIN}.${LAB_DOMAIN}. admin.${SUB_DOMAIN}.${LAB_DOMAIN}. (
                            3         ; Serial
                        604800         ; Refresh
                        86400         ; Retry
                        2419200         ; Expire
                        604800 )       ; Negative Cache TTL

; name servers - NS records
    IN      NS      router.${SUB_DOMAIN}.${LAB_DOMAIN}.

; PTR Records
1    IN      PTR     router.${SUB_DOMAIN}.${LAB_DOMAIN}.
EOF

}

function getBootFiles() {
  mkdir -p ${OKD_LAB_PATH}/boot-files
  wget http://boot.ipxe.org/ipxe.efi -O ${OKD_LAB_PATH}/boot-files/ipxe.efi
  wget http://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/isolinux/vmlinuz -O ${OKD_LAB_PATH}/boot-files/vmlinuz
  wget http://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/isolinux/initrd.img -O ${OKD_LAB_PATH}/boot-files/initrd.img
}

function addWireless() {
  if [[ ${EDGE} == "true" ]]
  then
    labenv -e
    if [[ ${LAB_CTX_ERROR} == "true" ]]
    then
      exit 1
    fi
    ROUTER=${EDGE_ROUTER}
  else
    if [[ -z ${SUB_DOMAIN} ]]
    then
      labctx
    else
      labctx ${SUB_DOMAIN}
    fi
    if [[ ${LAB_CTX_ERROR} == "true" ]]
    then
      exit 1
    fi
    ROUTER=${DOMAIN_ROUTER}
  fi

  echo "Enter an SSID for you Lab Wireless LAN:"
  read LAB_WIFI_SSID
  echo "Enter a WPA/PSK 2 Passphrase for your Lab Wireless LAN:"
  read LAB_WIFI_KEY

  ${SSH} root@${ROUTER} "uci set wireless.default_radio0.ssid=${LAB_WIFI_SSID} ; \
    uci set wireless.default_radio0.key=${LAB_WIFI_KEY} ; \
    uci set wireless.default_radio0.encryption=psk2 ; \
    uci set wireless.radio0.band=2G_5G ; \
    uci set wireless.radio0.channel=153 ; \
    uci set wireless.radio0.htmode=VHT80 ; \
    uci commit wireless ; \
    /etc/init.d/network reload"
}