#!/bin/bash
. ${OKD_LAB_PATH}/bin/labctx.env

WLAN="false"
WWAN="false"
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
INDEX=""
CONFIG_FILE=${LAB_CONFIG_FILE}
INIT_IP=192.168.8.1
WIFI_CHANNEL=3

for i in "$@"
do
  case ${i} in
    -e|--edge)
      EDGE=true
      shift
    ;;
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      shift
    ;;
    -d=*|--domain=*)
      sub_domain="${i#*=}"
      shift
    ;;
    -wl|--wireless-lan)
      WLAN="true"
      shift
    ;;
    -ww|--wireless-wan)
      WWAN="true"
      shift
    ;;
    *)
          echo "USAGE: initRouter.sh -e -c=path/to/config/file -d=sub-domain-name"
    ;;
  esac
done

function createEdgeFIles() {

cat << EOF > ${WORK_DIR}/uci.batch
set dropbear.@dropbear[0].PasswordAuth="off"
set dropbear.@dropbear[0].RootPasswordAuth="off"
set network.lan.ipaddr="${ROUTER_IP}"
set network.lan.netmask=${NETMASK}
set network.lan.hostname=router.${DOMAIN}
delete network.wan6
set dhcp.lan.leasetime="5m"
set dhcp.lan.start="225"
set dhcp.lan.limit="30"
add_list dhcp.lan.dhcp_option="6,${ROUTER_IP}"
EOF


if [[ ${WWAN} == "true" ]]
then
  echo "Listing available Wireless Networks:"
  ${SSH} root@${INIT_IP} "iwinfo wlan0 scan"
  echo ""
  echo "Enter the SSID of the Wireless Lan that you are connecting to:"
  read WIFI_SSID
  echo "Enter the passphrase of the wireless lan that you are connecting to:"
  read WIFI_KEY
  WIFI_ENCRYPT=psk2

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
set wireless.sta.ssid="${WIFI_SSID}"  
set wireless.sta.encryption="${WIFI_ENCRYPT}"      
set wireless.sta.key="${WIFI_KEY}"    
set network.wwan=interface
set network.wwan.proto="dhcp"
set network.wwan.metric="20"
EOF
fi

if [[ ${WLAN} == "true" ]]
then
echo "Enter an SSID for you Lab Wireless LAN:"
read LAB_WIFI_SSID
echo "Enter a WPA/PSK 2 Passphrase for your Lab Wireless LAN:"
read LAB_WIFI_KEY

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
set wireless.default_radio0.ssid="${LAB_WIFI_SSID}"
set wireless.default_radio0.key="${LAB_WIFI_KEY}"
set wireless.default_radio0.encryption="psk2"
set wireless.default_radio0.multi_ap="1"
set wireless.radio0.legacy_rates="0"
set wireless.radio0.htmode="HT20"
set wireless.radio0.channel=${WIFI_CHANNEL}
EOF
fi

echo "commit" >> ${WORK_DIR}/uci.batch
}

function createDomainFIles() {

cat << EOF > ${WORK_DIR}/edge-zone
zone "${DOMAIN}" {
    type stub;
    masters { ${ROUTER_IP}; };
    file "stub.${DOMAIN}";
};

EOF

cat << EOF >> ${WORK_DIR}/uci.batch
set dropbear.@dropbear[0].PasswordAuth='off'
set dropbear.@dropbear[0].RootPasswordAuth='off'
set network.wan.proto='static'
set network.wan.ipaddr=${EDGE_IP}
set network.wan.netmask=${NETMASK}
set network.wan.gateway=${GATEWAY}
set network.wan.hostname=router.${DOMAIN}
set network.wan.dns=${GATEWAY}
set network.lan.ipaddr=${ROUTER_IP}
set network.lan.netmask=${NETMASK}
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

function validateVars() {

  if [[ ${CONFIG_FILE} == "" ]]
  then
    echo "You must specify a lab configuration YAML file."
    exit 1
  fi

  if [[ ${EDGE} == "false" ]]
  then
    if [[ ${sub_domain} != "" ]]
    then
      DONE=false
      DOMAIN_COUNT=$(yq e ".sub-domain-configs" ${CONFIG_FILE} | yq e 'length' -)
      let i=0
      while [[ i -lt ${DOMAIN_COUNT} ]]
      do
        domain_name=$(yq e ".sub-domain-configs.[${i}].name" ${CONFIG_FILE})
        if [[ ${domain_name} == ${sub_domain} ]]
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
      SUB_DOMAIN=${sub_domain}
    fi
    if [[ -z "${SUB_DOMAIN}" ]]
    then
      labctx
    fi
  fi
}

validateVars

WORK_DIR=${OKD_LAB_PATH}/work-dir-router
rm -rf ${WORK_DIR}
mkdir -p ${WORK_DIR}
LAB_DOMAIN=$(yq e ".domain" ${CONFIG_FILE})

if [[ ${EDGE} == "true" ]]
then
  ROUTER_IP=$(yq e ".router" ${CONFIG_FILE})
  NETMASK=$(yq e ".netmask" ${CONFIG_FILE})
  DOMAIN=${LAB_DOMAIN}
  createEdgeFIles
else
  DOMAIN=${SUB_DOMAIN}.${LAB_DOMAIN}
  GATEWAY=$(yq e ".router" ${CONFIG_FILE})
  ROUTER_IP=$(yq e ".sub-domain-configs.[${INDEX}].router-ip" ${CONFIG_FILE})
  NETWORK=$(yq e ".sub-domain-configs.[${INDEX}].network" ${CONFIG_FILE})
  EDGE_IP=$(yq e ".sub-domain-configs.[${INDEX}].router-edge-ip" ${CONFIG_FILE})
  NETMASK=$(yq e ".sub-domain-configs.[${INDEX}].netmask" ${CONFIG_FILE})
  createDomainFIles
  ${SSH} root@${INIT_IP} "ENTRY=\$(uci add firewall forwarding) ; uci set firewall.\${ENTRY}.src=wan ; uci set firewall.\${ENTRY}.dest=lan ; uci commit firewall"
  ${SSH} root@router.${LAB_DOMAIN} "unset ROUTE ; ROUTE=\$(uci add network route) ; uci set network.\${ROUTE}.interface=lan ; uci set network.\${ROUTE}.target=${NETWORK} ; uci set network.\${ROUTE}.netmask=${NETMASK} ; uci set network.\${ROUTE}.gateway=${EDGE_IP} ; uci commit network"
  cat ${OKD_LAB_PATH}/work-dir/edge-zone | ${SSH} root@router.${LAB_DOMAIN} "cat >> /etc/bind/named.conf"
  ${SSH} root@router.${LAB_DOMAIN} "/etc/init.d/network reload"
  ${SSH} root@router.${LAB_DOMAIN} "/etc/init.d/named stop && /etc/init.d/named start"
fi
echo "Generating SSH keys"
${SSH} root@${INIT_IP} "rm -rf /root/.ssh ; rm -rf /data/* ; mkdir -p /root/.ssh ; dropbearkey -t rsa -s 4096 -f /root/.ssh/id_dropbear"
echo "Copying workstation SSH key to router"
cat ~/.ssh/id_rsa.pub | ${SSH} root@${INIT_IP} "cat >> /etc/dropbear/authorized_keys"
echo "Applying UCI config"
${SCP} ${WORK_DIR}/uci.batch root@${INIT_IP}:/tmp/uci.batch
${SSH} root@${INIT_IP} "cat /tmp/uci.batch | uci batch && passwd -l root && reboot"
