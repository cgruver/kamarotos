#!/bin/bash
. ${OKD_LAB_PATH}/bin/labctx.env

EDGE="false"
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
INDEX=""
CONFIG_FILE=${LAB_CONFIG_FILE}

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
    *)
          echo "USAGE: configRouter.sh -e -c=path/to/config/file -d=sub-domain-name"
    ;;
  esac
done

function mask2cidr () {
   local x=${1##*255.}
   set -- 0^^^128^192^224^240^248^252^254^ $(( (${#1} - ${#x})*2 )) ${x%%.*}
   x=${1%%$3*}
   echo $(( $2 + (${#x}/4) ))
}

function setNetVars() {

CIDR=$(mask2cidr ${NETMASK})
IFS=. read -r i1 i2 i3 i4 << EOF
${ROUTER}
EOF
net_addr=$(( ((1<<32)-1) & (((1<<32)-1) << (32 - ${CIDR})) ))
o1=$(( ${i1} & (${net_addr}>>24) ))
o2=$(( ${i2} & (${net_addr}>>16) ))
o3=$(( ${i3} & (${net_addr}>>8) ))
o4=$(( ${i4} & ${net_addr} ))
NETWORK=${o1}.${o2}.${o3}.${o4}
NET_PREFIX=${o1}.${o2}.${o3}
NET_PREFIX_ARPA=${o3}.${o2}.${o1}
}

function createUciEdge() {

cat << EOF > ${WORK_DIR}/uci.batch
set dhcp.@dnsmasq[0].domain=${DOMAIN}
set dhcp.@dnsmasq[0].localuse=0
set dhcp.@dnsmasq[0].cachelocal=0
set dhcp.@dnsmasq[0].port=0
commit
EOF

}

function createUciDomain() {

cat << EOF > ${WORK_DIR}/uci.batch
add_list dhcp.lan.dhcp_option="6,${ROUTER}"
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
set dhcp.uefi.serveraddress="${ROUTER}"
set dhcp.uefi.servername='pxe'
set dhcp.uefi.force='1'
set dhcp.ipxe=boot
set dhcp.ipxe.filename='tag:ipxe,boot.ipxe'
set dhcp.ipxe.serveraddress="${ROUTER}"
set dhcp.ipxe.servername='pxe'
set dhcp.ipxe.force='1'
set dhcp.@dnsmasq[0].domain=${DOMAIN}
set dhcp.@dnsmasq[0].localuse=0
set dhcp.@dnsmasq[0].cachelocal=0
set dhcp.@dnsmasq[0].port=0
del_list uhttpd.main.listen_http="[::]:80"
del_list uhttpd.main.listen_http="0.0.0.0:80"
del_list uhttpd.main.listen_https="[::]:443"
del_list uhttpd.main.listen_https="0.0.0.0:443"
add_list uhttpd.main.listen_http="${ROUTER}:80"
add_list uhttpd.main.listen_https="${ROUTER}:443"
add_list uhttpd.main.listen_http="127.0.0.1:80"
add_list uhttpd.main.listen_https="127.0.0.1:443"
set network.lan_lb01=interface
set network.lan_lb01.ifname="@lan"
set network.lan_lb01.proto="static"
set network.lan_lb01.hostname="okd4-lb01.${DOMAIN}"
set network.lan_lb01.ipaddr="${LB_IP}/${NETMASK}"
commit
EOF

}

function createEdgeDnsConfig() {

cat << EOF > ${WORK_DIR}/dns/named.conf
acl "trusted" {
 ${NETWORK}/${CIDR};
 127.0.0.1;
};

options {
listen-on port 53 { 127.0.0.1; ${ROUTER}; };
   
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

zone "${DOMAIN}" {
   type master;
   file "/etc/bind/db.${DOMAIN}"; # zone file path
};

zone "${NET_PREFIX_ARPA}.in-addr.arpa" {
   type master;
   file "/etc/bind/db.${NET_PREFIX_ARPA}";
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

cat << EOF > ${WORK_DIR}/dns/db.${DOMAIN}
@       IN      SOA     router.${DOMAIN}. admin.${DOMAIN}. (
            3          ; Serial
            604800     ; Refresh
            86400     ; Retry
            2419200     ; Expire
            604800 )   ; Negative Cache TTL
;
; name servers - NS records
   IN      NS     router.${DOMAIN}.

; name servers - A records
router.${DOMAIN}.         IN      A      ${ROUTER}

; ${NETWORK}/${CIDR} - A records
EOF

cat << EOF > ${WORK_DIR}/dns/db.${NET_PREFIX_ARPA}
@       IN      SOA     router.${DOMAIN}. admin.${DOMAIN}. (
                              3         ; Serial
                        604800         ; Refresh
                        86400         ; Retry
                        2419200         ; Expire
                        604800 )       ; Negative Cache TTL

; name servers - NS records
      IN      NS      router.${DOMAIN}.

; PTR Records
1    IN      PTR     router.${DOMAIN}.
EOF

}

function createDomainDnsConfig() {

cat << EOF > ${WORK_DIR}/edge-zone
zone "${DOMAIN}" {
    type stub;
    masters { ${ROUTER}; };
    file "stub.${DOMAIN}";
};

EOF

cat << EOF > ${WORK_DIR}/dns/named.conf
acl "trusted" {
 ${NETWORK}/${CIDR};
 ${EDGE_NETWORK}/${CIDR};
 127.0.0.1;
};

options {
 listen-on port 53 { 127.0.0.1; ${ROUTER}; };
 
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

zone "${DOMAIN}" {
    type master;
    file "/etc/bind/db.${DOMAIN}"; # zone file path
};

zone "${NET_PREFIX_ARPA}.in-addr.arpa" {
    type master;
    file "/etc/bind/db.${NET_PREFIX_ARPA}";
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

cat << EOF > ${WORK_DIR}/dns/db.${DOMAIN}
@       IN      SOA     router.${DOMAIN}. admin.${DOMAIN}. (
             3          ; Serial
             604800     ; Refresh
              86400     ; Retry
            2419200     ; Expire
             604800 )   ; Negative Cache TTL
;
; name servers - NS records
    IN      NS     router.${DOMAIN}.

; name servers - A records
router.${DOMAIN}.         IN      A      ${ROUTER}

; ${NETWORK}/${CIDR} - A records
EOF

cat << EOF > ${WORK_DIR}/dns/db.${NET_PREFIX_ARPA}
@       IN      SOA     router.${DOMAIN}. admin.${DOMAIN}. (
                            3         ; Serial
                        604800         ; Refresh
                        86400         ; Retry
                        2419200         ; Expire
                        604800 )       ; Negative Cache TTL

; name servers - NS records
    IN      NS      router.${DOMAIN}.

; PTR Records
1    IN      PTR     router.${DOMAIN}.
EOF
}

function createLbConfig() {

cat << EOF > ${WORK_DIR}/haproxy.cfg
global

    log         127.0.0.1 local2

    chroot      /data/haproxy
    pidfile     /var/run/haproxy.pid
    maxconn     50000
    user        haproxy
    group       haproxy
    daemon

    stats socket /data/haproxy/stats

defaults
    mode                    http
    log                     global
    option                  dontlognull
    option                  redispatch
    retries                 3
    timeout http-request    10s
    timeout queue           1m
    timeout connect         10s
    timeout client          10m
    timeout server          10m
    timeout http-keep-alive 10s
    timeout check           10s
    maxconn                 50000

listen okd4-api 
    bind ${LB_IP}:6443
    balance roundrobin
    option                  tcplog
    mode tcp
    option tcpka
    option tcp-check
    server okd4-bootstrap ${NET_PREFIX}.49:6443 check weight 1
    server okd4-master-0 ${NET_PREFIX}.60:6443 check weight 1
    server okd4-master-1 ${NET_PREFIX}.61:6443 check weight 1
    server okd4-master-2 ${NET_PREFIX}.62:6443 check weight 1

listen okd4-mc 
    bind ${LB_IP}:22623
    balance roundrobin
    option                  tcplog
    mode tcp
    option tcpka
    server okd4-bootstrap ${NET_PREFIX}.49:22623 check weight 1
    server okd4-master-0 ${NET_PREFIX}.60:22623 check weight 1
    server okd4-master-1 ${NET_PREFIX}.61:22623 check weight 1
    server okd4-master-2 ${NET_PREFIX}.62:22623 check weight 1

listen okd4-apps 
    bind ${LB_IP}:80
    balance source
    option                  tcplog
    mode tcp
    option tcpka
    server okd4-master-0 ${NET_PREFIX}.60:80 check weight 1
    server okd4-master-1 ${NET_PREFIX}.61:80 check weight 1
    server okd4-master-2 ${NET_PREFIX}.62:80 check weight 1

listen okd4-apps-ssl 
    bind ${LB_IP}:443
    balance source
    option                  tcplog
    mode tcp
    option tcpka
    option tcp-check
    server okd4-master-0 ${NET_PREFIX}.60:443 check weight 1
    server okd4-master-1 ${NET_PREFIX}.61:443 check weight 1
    server okd4-master-2 ${NET_PREFIX}.62:443 check weight 1
EOF

}

function validateVars() {

  if [[ ${CONFIG_FILE} == "" ]]
  then
    echo "You must specify a lab configuration YAML file."
    exit 1
  fi

  if [[ ${EDGE} == "false" ]]
  then
    if [[ ! -z ${sub_domain} ]]
    then
      SUB_DOMAIN=${sub_domain}
    elif [[ -z "${SUB_DOMAIN}" ]]
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
  fi
}

validateVars

LAB_DOMAIN=$(yq e ".domain" ${CONFIG_FILE})
EDGE_ROUTER=$(yq e ".router" ${CONFIG_FILE})

WORK_DIR=${OKD_LAB_PATH}/work-dir-router
rm -rf ${WORK_DIR}
mkdir -p ${WORK_DIR}/dns

if [[ ${EDGE} == "true" ]]
then
  ROUTER=${EDGE_ROUTER}
  DOMAIN=${LAB_DOMAIN}
  setNetVars
  createEdgeDnsConfig
  createUciEdge
  ${SSH} root@${ROUTER} "opkg update && opkg install ip-full procps-ng-ps bind-server bind-tools sfdisk rsync resize2fs wget"
else
  ROUTER=$(yq e ".sub-domain-configs.[${INDEX}].router-ip" ${CONFIG_FILE})
  NETWORK=$(yq e ".sub-domain-configs.[${INDEX}].network" ${CONFIG_FILE})
  EDGE_IP=$(yq e ".sub-domain-configs.[${INDEX}].router-edge-ip" ${CONFIG_FILE})
  EDGE_NETWORK=$(yq e ".network" ${CONFIG_FILE})
  NETMASK=$(yq e ".sub-domain-configs.[${INDEX}].netmask" ${CONFIG_FILE})
  DOMAIN=${SUB_DOMAIN}.${LAB_DOMAIN}
  setNetVars
  createDomainDnsConfig
  createLbConfig
  createUciDomain
  ${SSH} root@${EDGE_ROUTER} "unset ROUTE ; ROUTE=\$(uci add network route) ; uci set network.\${ROUTE}.interface=lan ; uci set network.\${ROUTE}.target=${NETWORK} ; uci set network.\${ROUTE}.netmask=${NETMASK} ; uci set network.\${ROUTE}.gateway=${EDGE_IP} ; uci commit network"
  ${SSH} root@${EDGE_ROUTER} "/etc/init.d/network reload ; sleep 3"
  ${SSH} root@${ROUTER} "opkg update && opkg install ip-full procps-ng-ps bind-server bind-tools haproxy bash shadow uhttpd wget"
  ${SSH} root@${ROUTER} "mv /etc/haproxy.cfg /etc/haproxy.cfg.orig ; /etc/init.d/lighttpd disable ; /etc/init.d/lighttpd stop ; groupadd haproxy ; useradd -d /data/haproxy -g haproxy haproxy ; mkdir -p /data/haproxy ; chown -R haproxy:haproxy /data/haproxy"
  ${SCP} ${WORK_DIR}/haproxy.cfg root@${ROUTER}:/etc/haproxy.cfg
  ${SSH} root@${ROUTER} "cp /etc/haproxy.cfg /etc/haproxy.bootstrap && cat /etc/haproxy.cfg | grep -v bootstrap > /etc/haproxy.no-bootstrap"
  ${SSH} root@${ROUTER} "/etc/init.d/uhttpd enable ; /etc/init.d/haproxy enable"
  cat ${WORK_DIR}/edge-zone | ${SSH} root@${EDGE_ROUTER} "cat >> /etc/bind/named.conf"
fi

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

wget http://boot.ipxe.org/ipxe.efi -O ${WORK_DIR}/ipxe.efi
wget http://mirror.centos.org/centos/8-stream/BaseOS/x86_64/os/isolinux/vmlinuz -O ${WORK_DIR}/vmlinuz
wget http://mirror.centos.org/centos/8-stream/BaseOS/x86_64/os/isolinux/initrd.img -O ${WORK_DIR}/initrd.img

${SSH} root@${ROUTER} "mkdir -p /data/tftpboot/ipxe ; \
  mkdir /data/tftpboot/networkboot ; \
  wget http://boot.ipxe.org/ipxe.efi -O /data/tftpboot/ipxe.efi ; \
  wget http://mirror.centos.org/centos/8-stream/BaseOS/x86_64/os/isolinux/vmlinuz -O /data/tftpboot/networkboot/vmlinuz ; \
  wget http://mirror.centos.org/centos/8-stream/BaseOS/x86_64/os/isolinux/initrd.img -O /data/tftpboot/networkboot/initrd.img"
${SCP} ${WORK_DIR}/boot.ipxe root@${ROUTER}:/data/tftpboot/boot.ipxe
${SSH} root@${ROUTER} "mv /etc/bind/named.conf /etc/bind/named.conf.orig"
${SCP} -r ${WORK_DIR}/dns/* root@${ROUTER}:/etc/bind/
${SSH} root@${ROUTER} "mkdir -p /data/var/named/dynamic ; \
  mkdir /data/var/named/data ; \
  chown -R bind:bind /data/var/named ; \
  chown -R bind:bind /etc/bind ; \
  /etc/init.d/named enable ; \
  uci set network.wan.dns=${ROUTER} ; \
  uci set network.wan.peerdns=0 ; \
  uci show network.wwan ; \
  if [[ \$? -eq 0 ]] ; \
  then uci set network.wwan.dns=${ROUTER} ; \
    uci set network.wwan.peerdns=0 ; \
  fi ; \
  uci commit"
${SCP} ${WORK_DIR}/uci.batch root@${ROUTER}:/tmp/uci.batch
${SSH} root@${ROUTER} "cat /tmp/uci.batch | uci batch && reboot"

if [[ ${EDGE} == "false" ]]
then
  ${SSH} root@${EDGE_ROUTER} "/etc/init.d/named restart"
fi

