

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

local domain=${1}

cat << EOF >> ${WORK_DIR}/uci.batch
set dhcp.@dnsmasq[0].domain=${domain}
set dhcp.@dnsmasq[0].localuse=0
set dhcp.@dnsmasq[0].cachelocal=0
set dhcp.@dnsmasq[0].port=0
set dhcp.lan.leasetime="5m"
set dhcp.lan.start="225"
set dhcp.lan.limit="30"
EOF
}

function createIpxeHostConfig() {

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
del_list uhttpd.main.listen_http="[::]:80"
del_list uhttpd.main.listen_http="0.0.0.0:80"
del_list uhttpd.main.listen_https="[::]:443"
del_list uhttpd.main.listen_https="0.0.0.0:443"
add_list uhttpd.main.listen_http="${router_ip}:80"
add_list uhttpd.main.listen_https="${router_ip}:443"
add_list uhttpd.main.listen_http="127.0.0.1:80"
add_list uhttpd.main.listen_https="127.0.0.1:443"
EOF
}