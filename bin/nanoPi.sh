function initNanoPi() {
  
  ${SSH} root@${INIT_IP} "opkg update && opkg install ip-full procps-ng-ps bind-server bind-tools bash sfdisk rsync resize2fs wget block-mount wipefs coreutils-nohup etherwake nginx-full curl"
  ${SCP} ${WORK_DIR}/dns/named-init root@${INIT_IP}:/etc/init.d/named
  ${SSH} root@${INIT_IP} "rm -rf /root/.ssh ; \
  mkdir -p /root/.ssh ; \
  mkdir -p /usr/local/var/named/dynamic ; \
  mkdir /usr/local/var/named/data ; \
  mkdir -p /usr/local/bind ; \
  chown -R bind:bind /usr/local/var/named ; \
  chown -R bind:bind /usr/local/bind ; \
  chmod 755 /etc/init.d/named ; \
  /etc/init.d/named enable ; \
  /etc/init.d/uhttpd disable ; \
  dropbearkey -t ed25519 -f /root/.ssh/id_dropbear"

  createNanoPiConfig
  ${SCP} ${OPENSHIFT_LAB_PATH}/boot-files/ipxe.efi root@${INIT_IP}:/usr/local/tftpboot/ipxe.efi
  ${SCP} ${WORK_DIR}/boot.ipxe root@${INIT_IP}:/usr/local/tftpboot/boot.ipxe
  ${SCP} -r ${WORK_DIR}/dns/conf/* root@${INIT_IP}:/usr/local/bind/
  ${SSH} root@${INIT_IP} "reboot"
  

}

function createNanoPiConfig() {

cat << EOF >> ${WORK_DIR}/uci.batch
set dropbear.@dropbear[0].PasswordAuth=off
set dropbear.@dropbear[0].RootPasswordAuth=off
set network.wan.proto=static
set network.wan.ipaddr=${EDGE_ROUTER_WAN}
set network.wan.netmask=${BRIDGE_NETMASK}
set network.wan.gateway=${BRIDGE_LAN}
set network.wan.hostname=router.${DOMAIN}
set network.wan.dns=${EDGE_ROUTER_LAN}
set network.lan.ipaddr=${EDGE_ROUTER_LAN}
set network.lan.netmask=${EDGE_NETMASK}
set network.lan.hostname=router.${LAB_DOMAIN}
del_list uhttpd.main.listen_http="[::]:80"
del_list uhttpd.main.listen_http="0.0.0.0:80"
del_list uhttpd.main.listen_https="[::]:443"
del_list uhttpd.main.listen_https="0.0.0.0:443"
add_list uhttpd.main.listen_http="${EDGE_ROUTER_LAN}:80"
add_list uhttpd.main.listen_https="${EDGE_ROUTER_LAN}:443"
set uhttpd.main.home='/usr/local/www'
set uhttpd.main.redirect_https='0'
set dhcp.@dnsmasq[0].domain=${LAB_DOMAIN}
set dhcp.@dnsmasq[0].localuse=0
set dhcp.@dnsmasq[0].cachelocal=0
set dhcp.@dnsmasq[0].port=0
set dhcp.lan.leasetime="5m"
set dhcp.lan.start="225"
set dhcp.lan.limit="30"
add_list dhcp.lan.dhcp_option="6,${EDGE_ROUTER_LAN}"
set dhcp.@dnsmasq[0].enable_tftp=1
set dhcp.@dnsmasq[0].tftp_root=/usr/local/tftpboot
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
set dhcp.uefi.serveraddress=${EDGE_ROUTER_LAN}
set dhcp.uefi.servername='pxe'
set dhcp.uefi.force='1'
set dhcp.ipxe=boot
set dhcp.ipxe.filename='tag:ipxe,boot.ipxe'
set dhcp.ipxe.serveraddress=${EDGE_ROUTER_LAN}
set dhcp.ipxe.servername='pxe'
set dhcp.ipxe.force='1'
set system.ntp.enable_server="1"
set nginx.global.uci_enable=false
commit
EOF

cat << EOF > ${WORK_DIR}/dns/named-init
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99

config_file=/usr/local/bind/named.conf
config_dir=\$(dirname \$config_file)
named_options_file=/etc/bind/named-rndc.conf
rndc_conf_file=/etc/bind/rndc.conf
pid_file=/var/run/named/named.pid
rndc_temp=\$(mktemp /tmp/rndc-confgen.XXXXXX)

logdir=/var/log/named/
cachedir=/var/cache/bind
libdir=/var/lib/bind
dyndir=/tmp/bind

conf_local_file=\$dyndir/named.conf.local


fix_perms() {
    for dir in \$libdir \$logdir \$cachedir \$dyndir; do
	test -e "\$dir" || {
            mkdir -p "\$dir"
            chgrp bind "\$dir"
            chmod g+w "\$dir"
	}
    done
}

reload_service() {
    rndc -q reload
}

start_service() {
    user_exists bind 57 || user_add bind 57
    group_exists bind 57 || group_add bind 57
    fix_perms

    rndc-confgen > \$rndc_temp

    sed -r -n -e '/^# options \{$/,/^\};$/{ s/^/# / }' -e p -e '/^# End of rndc\.conf$/q' < \$rndc_temp > \$rndc_conf_file

    sed -r -n -e '1,/^# End of rndc\.conf$/ { b done }' -e '/^# Use with the following in named.conf/ { p ; b done }' -e '/^# End of named\.conf$/ { p ; b done }' -e '/^# key /,$ { s/^# // ; p }' -e ': done' < \$rndc_temp > \$named_options_file

    rm -f \$rndc_temp

    touch \$conf_local_file

    procd_open_instance
    procd_set_param command /usr/sbin/named -u bind -f -4 -c \$config_file
    procd_set_param file \$config_file \$config_dir/bind.keys \$named_options_file \$conf_local_file \$config_dir/db.*
    procd_set_param respawn
    procd_close_instance
}
EOF

cat << EOF > ${WORK_DIR}/dns/conf/named.conf
acl "trusted" {
 ${EDGE_NETWORK}/${EDGE_CIDR};
 ${WAN_NETWORK}/${WAN_CIDR};
 127.0.0.1;
};

options {
 listen-on port 53 { 127.0.0.1; ${EDGE_ROUTER_LAN}; ${EDGE_ROUTER_WAN}; };
 
 directory  "/tmp";
 allow-query     { trusted; };
 recursion yes;
 forwarders="forwarders { ${EDGE_ROUTER}; };"
 auth-nxdomain no;
};

zone "." {
        type hint;
        file "/etc/bind/db.root";
};

zone "${LAB_DOMAIN}" {
    type master;
    file "/usr/local/bind/db.${LAB_DOMAIN}"; # zone file path
};

zone "${EDGE_ARPA}.in-addr.arpa" {
    type master;
    file "/usr/local/bind/db.${EDGE_ARPA}";
};

zone "localhost" {
    type master;
    file "/usr/local/bind/db.local";
};

zone "127.in-addr.arpa" {
    type master;
    file "/usr/local/bind/db.127";
};

zone "0.in-addr.arpa" {
    type master;
    file "/usr/local/bind/db.0";
};

zone "255.in-addr.arpa" {
    type master;
    file "/usr/local/bind/db.255";
};

EOF

cat << EOF > ${WORK_DIR}/dns/conf/db.${LAB_DOMAIN}
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
router.${LAB_DOMAIN}.         IN      A      ${EDGE_ROUTER_LAN}
EOF

cat << EOF > ${WORK_DIR}/dns/conf/db.${EDGE_ARPA}
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

if [[ $(yq ". | has(\"infra-net-config\")" ${LAB_CONFIG_FILE}) == "true" ]]
then
  let host_count=$(yq e ".infra-net-config" ${LAB_CONFIG_FILE} | yq e 'length' -)
  let host_index=0
  while [[ host_index -lt ${host_count} ]]
  do
    host_name=$(yq e ".infra-net-config.[${host_index}].name" ${LAB_CONFIG_FILE})
    host_ip=$(yq e ".infra-net-config.[${host_index}].ip-addr" ${LAB_CONFIG_FILE})
    echo "${host_name}.${LAB_DOMAIN}.         IN      A      ${host_ip}" >> ${WORK_DIR}/dns/conf/db.${LAB_DOMAIN}
    o4=$(echo ${host_ip} | cut -d"." -f4)
    echo "${o4}    IN      PTR     ${host_name}.${LAB_DOMAIN}." >> ${WORK_DIR}/dns/conf/db.${EDGE_ARPA}
    host_index=$(( ${host_index} + 1 ))
  done
fi

cat << EOF > ${WORK_DIR}/chrony.conf
server ${INSTALL_HOST_IP} iburst
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

cat << EOF > ${WORK_DIR}/nginx.conf
user  root;
worker_processes  auto;

pid /var/run/nginx.pid;

events {
    worker_connections  1024;
}

http {
  include       mime.types;
  default_type  application/octet-stream;

  sendfile on;
  keepalive_timeout 5;

  client_body_buffer_size 10K;
  client_header_buffer_size 1k;
  client_max_body_size 1G;
  large_client_header_buffers 2 2k;

  gzip_static on;

  root /www;

  access_log off;
  server {
    listen ${EDGE_ROUTER_LAN}:443 ssl default_server;
    listen ${EDGE_ROUTER_LAN}:80;
    server_name _lan;
    include restrict_locally;
    include conf.d/*.locations;
    ssl_certificate /etc/nginx/conf.d/_lan.crt;
    ssl_certificate_key /etc/nginx/conf.d/_lan.key;
    ssl_session_cache shared:SSL:32k;
    ssl_session_timeout 64m;
    access_log off; # logd openwrt;
  }

  include /etc/nginx/conf.d/*.conf;
}
stream { include /usr/local/nginx/*.conf; }
EOF

}

