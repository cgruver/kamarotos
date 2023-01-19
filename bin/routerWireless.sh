function configWwanMV1000W() {

local wifi_ssid=${1}
local wifi_key=${2}
local wwan_channel=${3}

cat << EOF >> ${WORK_DIR}/uci.batch
set wireless.radio2.disabled="0"
set wireless.radio2.repeater="1"
set wireless.radio2.legacy_rates="0"
set wireless.radio2.htmode="HT20"
set wireless.radio2.channel=${wwan_channel}
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
  local wwan_channel=${3}

cat << EOF >> ${WORK_DIR}/uci.batch
set wireless.radio0.repeater="1"
set wireless.radio0.org_htmode='VHT80'
set wireless.radio0.htmode='VHT80'
set wireless.radio0.channel=${wwan_channel}
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
local wlan_channel=${3}

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
set wireless.radio0.channel=${wlan_channel}
EOF

}

function configWlanAR750S() {

local wifi_ssid=${1}
local wifi_key=${2}
local wwan_channel=${3}
local wlan_channel=${4}

cat << EOF >> ${WORK_DIR}/uci.batch
set wireless.default_radio0=wifi-iface
set wireless.default_radio0.device='radio0'
set wireless.default_radio0.network='lan'
set wireless.default_radio0.mode='ap'
set wireless.default_radio0.key="${wifi_key}"
set wireless.default_radio0.disassoc_low_ack='0'
set wireless.default_radio0.ifname='wlan0'
set wireless.default_radio0.wds='1'
set wireless.default_radio0.ssid="${wifi_ssid}-5G"
set wireless.default_radio0.encryption='sae-mixed'
set wireless.default_radio0.disabled='0'
set wireless.default_radio0.channel=${wwan_channel}
set wireless.default_radio1.key="${wifi_key}"
set wireless.default_radio1.wds='1'
set wireless.default_radio1.disassoc_low_ack='0'
set wireless.default_radio1.ifname='wlan1'
set wireless.default_radio1.ssid="${wifi_ssid}-2G"
set wireless.default_radio1.encryption='sae-mixed'
set wireless.default_radio1.device='radio1'
set wireless.default_radio1.disabled='0'
set wireless.radio1.channel=${wlan_channel}
delete wireless.guest5g
delete wireless.guest2g
delete network.guest
delete dhcp.guest
EOF
}

function addWireless() {
  if [[ ${EDGE} == "true" ]]
  then
    ROUTER=${EDGE_ROUTER}
  else
    ROUTER=${DOMAIN_ROUTER}
  fi

  echo "Enter an SSID for you Lab Wireless LAN:"
  read LAB_WIFI_SSID
  echo "Enter a WPA/PSK 2 Passphrase for your Lab Wireless LAN:"
  read LAB_WIFI_KEY

  ${SSH} root@${ROUTER} "uci set wireless.default_radio0.ssid=\"${LAB_WIFI_SSID}\" ; \
    uci set wireless.default_radio0.key=\"${LAB_WIFI_KEY}\" ; \
    uci set wireless.default_radio0.encryption=psk2 ; \
    uci set wireless.radio0.band=2G_5G ; \
    uci set wireless.radio0.channel=153 ; \
    uci set wireless.radio0.htmode=VHT80 ; \
    uci commit wireless ; \
    /etc/init.d/network reload"
}