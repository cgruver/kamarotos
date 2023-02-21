

function createRouterDnsConfig() {

local router_ip=${1}
local net_domain=${2}
local arpa=${3}
local type=${4}
local forwarders=""

if [[ ${type} == "domain" ]]
then

cat << EOF > ${WORK_DIR}/edge-zone
zone "${net_domain}" {
    type stub;
    masters { ${router_ip}; };
    file "stub.${net_domain}";
};

EOF

forwarders="forwarders { ${EDGE_ROUTER}; };"

cat << EOF > ${WORK_DIR}/dns/named.conf
acl "trusted" {
 ${DOMAIN_NETWORK}/${DOMAIN_CIDR};
 ${EDGE_NETWORK}/${EDGE_CIDR};
 127.0.0.1;
};
EOF

else

cat << EOF > ${WORK_DIR}/dns/named.conf
acl "trusted" {
 ${EDGE_NETWORK}/${EDGE_CIDR};
 127.0.0.1;
};
EOF

fi

cat << EOF >> ${WORK_DIR}/dns/named.conf
options {
 listen-on port 53 { 127.0.0.1; ${router_ip}; };
 
 directory  "/data/var/named";
 dump-file  "/data/var/named/data/cache_dump.db";
 statistics-file "/data/var/named/data/named_stats.txt";
 memstatistics-file "/data/var/named/data/named_mem_stats.txt";
 allow-query     { trusted; };

 recursion yes;

 ${forwarders}

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

zone "${net_domain}" {
    type master;
    file "/etc/bind/db.${net_domain}"; # zone file path
};

zone "${arpa}.in-addr.arpa" {
    type master;
    file "/etc/bind/db.${arpa}";
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

cat << EOF > ${WORK_DIR}/dns/db.${net_domain}
@       IN      SOA     router.${net_domain}. admin.${net_domain}. (
             3          ; Serial
             604800     ; Refresh
              86400     ; Retry
            2419200     ; Expire
             604800 )   ; Negative Cache TTL
;
; name servers - NS records
    IN      NS     router.${net_domain}.

; name servers - A records
router.${net_domain}.         IN      A      ${router_ip}
EOF

cat << EOF > ${WORK_DIR}/dns/db.${arpa}
@       IN      SOA     router.${net_domain}. admin.${net_domain}. (
                            3         ; Serial
                        604800         ; Refresh
                        86400         ; Retry
                        2419200         ; Expire
                        604800 )       ; Negative Cache TTL

; name servers - NS records
    IN      NS      router.${net_domain}.

; PTR Records
1    IN      PTR     router.${net_domain}.
EOF
}

function createDhcpConfig() {

local router_ip=${1}
local domain=${2}

cat << EOF >> ${WORK_DIR}/uci.batch
set dhcp.@dnsmasq[0].domain=${domain}
set dhcp.@dnsmasq[0].localuse=0
set dhcp.@dnsmasq[0].cachelocal=0
set dhcp.@dnsmasq[0].port=0
set dhcp.lan.leasetime="5m"
set dhcp.lan.start="225"
set dhcp.lan.limit="30"
add_list dhcp.lan.dhcp_option="6,${EDGE_ROUTER}"
EOF
}

function createIpxeHostConfig() {

  local router_ip=${1}
  
  if [[ ${GL_MODEL} != "GL-AXT1800" ]]
  then
  ${SSH} root@${router_ip} "opkg update ; \
    opkg install uhttpd ; \
    /etc/init.d/uhttpd enable"

cat << EOF >> ${WORK_DIR}/uci.batch
del_list uhttpd.main.listen_http="[::]:80"
del_list uhttpd.main.listen_http="0.0.0.0:80"
del_list uhttpd.main.listen_https="[::]:443"
del_list uhttpd.main.listen_https="0.0.0.0:443"
add_list uhttpd.main.listen_http="${router_ip}:80"
add_list uhttpd.main.listen_https="${router_ip}:443"
set uhttpd.main.home='/www'
set uhttpd.main.redirect_https='0'
EOF
fi

CENTOS_MIRROR=$(yq e ".centos-mirror" ${LAB_CONFIG_FILE})

cat << EOF > ${WORK_DIR}/MirrorSync.sh
#!/bin/bash

for i in BaseOS AppStream 
do 
  rsync  -avSHP --delete ${CENTOS_MIRROR}9-stream/\${i}/x86_64/os/ /usr/local/www/install/repos/\${i}/x86_64/os/ > /tmp/repo-mirror.\${i}.out 2>&1
done
EOF

cat << EOF > ${WORK_DIR}/local-repos.repo
[local-appstream]
name=AppStream
baseurl=http://${BASTION_HOST}/install/repos/AppStream/x86_64/os/
gpgcheck=0
enabled=1

[local-baseos]
name=BaseOS
baseurl=http://${BASTION_HOST}/install/repos/BaseOS/x86_64/os/
gpgcheck=0
enabled=1

EOF

cat << EOF > ${WORK_DIR}/chrony.conf
server ${BASTION_HOST} iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF

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

cat << EOF >> ${WORK_DIR}/uci.batch
add_list dhcp.lan.dhcp_option="6,${router_ip}"
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
set dhcp.uefi.serveraddress="${router_ip}"
set dhcp.uefi.servername='pxe'
set dhcp.uefi.force='1'
set dhcp.ipxe=boot
set dhcp.ipxe.filename='tag:ipxe,boot.ipxe'
set dhcp.ipxe.serveraddress="${router_ip}"
set dhcp.ipxe.servername='pxe'
set dhcp.ipxe.force='1'
set system.ntp.enable_server="1"
EOF
}

function configHaProxy() {

  local lb_ip=${1}
  local cp_0=$(yq e ".control-plane.okd-hosts.[0].ip-addr" ${CLUSTER_CONFIG})
  local cp_1=$(yq e ".control-plane.okd-hosts.[1].ip-addr" ${CLUSTER_CONFIG})
  local cp_2=$(yq e ".control-plane.okd-hosts.[2].ip-addr" ${CLUSTER_CONFIG})
  local bs=$(yq e ".bootstrap.ip-addr" ${CLUSTER_CONFIG})

cat << EOF > ${WORK_DIR}/haproxy-${CLUSTER_NAME}.init
#!/bin/sh /etc/rc.common
# Copyright (C) 2009-2010 OpenWrt.org

START=99
STOP=80

SERVICE_USE_PID=1
EXTRA_COMMANDS="check"

HAPROXY_BIN="/usr/sbin/haproxy"
HAPROXY_CONFIG="/etc/haproxy-${CLUSTER_NAME}.cfg"
HAPROXY_PID="/var/run/haproxy-${CLUSTER_NAME}.pid"

start() {
	service_start \$HAPROXY_BIN -q -D -f "\$HAPROXY_CONFIG" -p "\$HAPROXY_PID"
}

stop() {
	kill -9 \$(cat \$HAPROXY_PID)
	service_stop \$HAPROXY_BIN
}

reload() {
	\$HAPROXY_BIN -D -q -f \$HAPROXY_CONFIG -p \$HAPROXY_PID -sf \$(cat \$HAPROXY_PID)
}

check() {
        \$HAPROXY_BIN -c -q -V -f \$HAPROXY_CONFIG
}
EOF

cat << EOF > ${WORK_DIR}/haproxy-${CLUSTER_NAME}.cfg
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
    bind ${lb_ip}:6443
    balance roundrobin
    option                  tcplog
    mode tcp
    option tcpka
    option tcp-check
    server okd4-bootstrap ${bs}:6443 check weight 1
    server okd4-master-0 ${cp_0}:6443 check weight 1
    server okd4-master-1 ${cp_1}:6443 check weight 1
    server okd4-master-2 ${cp_2}:6443 check weight 1

listen okd4-mc 
    bind ${lb_ip}:22623
    balance roundrobin
    option                  tcplog
    mode tcp
    option tcpka
    server okd4-bootstrap ${bs}:22623 check weight 1
    server okd4-master-0 ${cp_0}:22623 check weight 1
    server okd4-master-1 ${cp_1}:22623 check weight 1
    server okd4-master-2 ${cp_2}:22623 check weight 1

listen okd4-apps 
    bind ${lb_ip}:80
    balance source
    option                  tcplog
    mode tcp
    option tcpka
    server okd4-master-0 ${cp_0}:80 check weight 1
    server okd4-master-1 ${cp_1}:80 check weight 1
    server okd4-master-2 ${cp_2}:80 check weight 1

listen okd4-apps-ssl 
    bind ${lb_ip}:443
    balance source
    option                  tcplog
    mode tcp
    option tcpka
    option tcp-check
    server okd4-master-0 ${cp_0}:443 check weight 1
    server okd4-master-1 ${cp_1}:443 check weight 1
    server okd4-master-2 ${cp_2}:443 check weight 1
EOF

}

function configNginx() {

  local lb_ip=${1}
  local cp_0=$(yq e ".control-plane.okd-hosts.[0].ip-addr" ${CLUSTER_CONFIG})
  local cp_1=$(yq e ".control-plane.okd-hosts.[1].ip-addr" ${CLUSTER_CONFIG})
  local cp_2=$(yq e ".control-plane.okd-hosts.[2].ip-addr" ${CLUSTER_CONFIG})
  local bs=$(yq e ".bootstrap.ip-addr" ${CLUSTER_CONFIG})

cat << EOF > ${WORK_DIR}/nginx-${CLUSTER_NAME}.conf
stream {
    upstream okd4-api {
        server ${bs}:6443 max_fails=3 fail_timeout=1s;  # bootstrap
        server ${cp_0}:6443 max_fails=3 fail_timeout=1s;
        server ${cp_1}:6443 max_fails=3 fail_timeout=1s;
        server ${cp_2}:6443 max_fails=3 fail_timeout=1s;
    }
    upstream okd4-mc {
        server ${bs}:22623 max_fails=3 fail_timeout=1s; # bootstrap
        server ${cp_0}:22623 max_fails=3 fail_timeout=1s;
        server ${cp_1}:22623 max_fails=3 fail_timeout=1s;
        server ${cp_2}:22623 max_fails=3 fail_timeout=1s;
    }
    upstream okd4-https {
        server ${cp_0}:443 max_fails=3 fail_timeout=1s;
        server ${cp_1}:443 max_fails=3 fail_timeout=1s;
        server ${cp_2}:443 max_fails=3 fail_timeout=1s;
    }
    upstream okd4-http {
        server ${cp_0}:80 max_fails=3 fail_timeout=1s;
        server ${cp_1}:80 max_fails=3 fail_timeout=1s;
        server ${cp_2}:80 max_fails=3 fail_timeout=1s;
    }
    server {
        listen ${lb_ip}:6443;
        proxy_pass okd4-api;
    }
    server {
        listen ${lb_ip}:22623;
        proxy_pass okd4-mc;
    }
    server {
        listen ${lb_ip}:443;
        proxy_pass okd4-https;
    }
    server {
        listen ${lb_ip}:80;
        proxy_pass okd4-http;
    }
}
EOF
}