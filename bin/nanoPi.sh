function initNanoPi() {
  if [[ ${EDGE} == "true" ]]
  then
    initEdge
  else
    initDomain
    ${SSH} root@${INIT_IP} "FW=\$(uci add firewall forwarding) ; \
      uci set firewall.\${FW}.src=wan ; \
      uci set firewall.\${FW}.dest=lan ; \
      uci commit firewall"
    ${SSH} root@${EDGE_ROUTER} "unset ROUTE ; \
      ROUTE=\$(uci add network route) ; \
      uci set network.\${ROUTE}.interface=lan ; \
      uci set network.\${ROUTE}.target=${DOMAIN_NETWORK} ; \
      uci set network.\${ROUTE}.netmask=${DOMAIN_NETMASK} ; \
      uci set network.\${ROUTE}.gateway=${DOMAIN_ROUTER_EDGE} ; \
      uci commit network ; \
      /etc/init.d/network restart"
    pause 30 "Give the Router network time to restart"
    ${SSH} root@${EDGE_ROUTER} "/etc/init.d/named stop && /etc/init.d/named start"
  fi
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

function initEdge() {

cat << EOF > ${WORK_DIR}/uci.batch
set dropbear.@dropbear[0].PasswordAuth="off"
set dropbear.@dropbear[0].RootPasswordAuth="off"
set network.lan.ipaddr="${EDGE_ROUTER}"
set network.lan.netmask=${EDGE_NETMASK}
set network.lan.hostname=router.${LAB_DOMAIN}
EOF
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