function configPi() {
  PI_WORK_DIR=${OKD_LAB_PATH}/work-dir-pi
  rm -rf ${PI_WORK_DIR}
  mkdir -p ${PI_WORK_DIR}/config
  for i in "$@"
  do
    case ${i} in
      -i)
        initPi
      ;;
      -s)
        piSetup
      ;;
      *)
        # catch all
      ;;
    esac
  done
}

function initPi() {

  OPENWRT_VER=$(yq e ".openwrt-version" ${LAB_CONFIG_FILE})

read -r -d '' FILE << EOF
config interface 'loopback'\n
\toption device 'lo'\n
\toption proto 'static'\n
\toption ipaddr '127.0.0.1'\n
\toption netmask '255.0.0.0'\n
\n
config device\n
\toption name 'br-lan'\n
\toption type 'bridge'\n
\tlist ports 'eth0'\n
\n
config interface 'lan'\n
\toption device 'br-lan'\n
\toption proto 'static'\n
\toption ipaddr '${BASTION_HOST}'\n
\toption netmask '${EDGE_NETMASK}'\n
\toption gateway '${EDGE_ROUTER}'\n
\toption dns '${EDGE_ROUTER}'\n
EOF

echo -e ${FILE} > ${PI_WORK_DIR}/config/network

read -r -d '' FILE << EOF
config dropbear\n
\toption PasswordAuth off\n
\toption RootPasswordAuth off\n
\toption Port 22\n
EOF

echo -e ${FILE} > ${PI_WORK_DIR}/config/dropbear

read -r -d '' FILE << EOF
config system\n
\toption timezone 'UTC'\n
\toption ttylogin '0'\n
\toption log_size '64'\n
\toption urandom_seed '0'\n
\toption hostname 'bastion.${LAB_DOMAIN}'\n
\n
config timeserver 'ntp'\n
\toption enabled '1'\n
\toption enable_server '0'\n
\tlist server '0.openwrt.pool.ntp.org'\n
\tlist server '1.openwrt.pool.ntp.org'\n
\tlist server '2.openwrt.pool.ntp.org'\n
\tlist server '3.openwrt.pool.ntp.org'\n
EOF

  echo -e ${FILE} > ${PI_WORK_DIR}/config/system
  SD_DEV=mmcblk1
  SD_PART=mmcblk1p

  checkRouterModel ${EDGE_ROUTER}
  echo "Detected Router Model: ${GL_MODEL}"
  if [[ ${GL_MODEL} == "GL-AR750S"  ]]
  then
    SD_DEV=sda
    SD_PART=sda
    ${SSH} root@${EDGE_ROUTER} "mount | grep /dev/sdb | while read line ; \
    do echo \${line} | cut -d' ' -f1 ; \
    done | while read fs ; \
    do umount \${fs} ;  \
    done ; \
    dd if=/dev/zero of=/dev/sdb bs=4096 count=1 ; \
    echo \"/dev/sdb1 : start=1, type=83\" > /tmp/part.info ; \
    sfdisk --no-reread -f /dev/sdb < /tmp/part.info ; \
    rm /tmp/part.info ; \
    umount /dev/sdb1 ; \
    mkfs.ext4 /dev/sdb1 ; \
    mkdir -p /data/openwrt ; \
    umount /dev/sdb1 ; \
    mount -t ext4 /dev/sdb1 /data/openwrt"
  fi

  ${SSH} root@${EDGE_ROUTER} "echo \"unmounting ${SD_PART} - Safe to ignore errors for non-existent mounts\" ; \
    umount /dev/${SD_PART}1 ; \
    umount /dev/${SD_PART}2 ; \
    umount /dev/${SD_PART}3 ; \
    dd if=/dev/zero of=/dev/${SD_DEV} bs=4096 count=1 ; \
    mkdir -p /data/openwrt ; \
    wget https://downloads.openwrt.org/releases/${OPENWRT_VER}/targets/bcm27xx/bcm2711/openwrt-${OPENWRT_VER}-bcm27xx-bcm2711-rpi-4-ext4-factory.img.gz -O /data/openwrt/openwrt.img.gz ; \
    gunzip /data/openwrt/openwrt.img.gz ; \
    dd if=/data/openwrt/openwrt.img of=/dev/${SD_DEV} bs=4M conv=fsync ; \
    PART_INFO=\$(sfdisk -l /dev/${SD_DEV} | grep ${SD_PART}2) ; \
    let ROOT_SIZE=20971520 ; \
    let P2_START=\$(echo \${PART_INFO} | cut -d\" \" -f2) ; \
    let P3_START=\$(( \${P2_START}+\${ROOT_SIZE}+8192 )) ; \
    sfdisk --no-reread -f --delete /dev/${SD_DEV} 2 ; \
    sfdisk --no-reread -f -d /dev/${SD_DEV} > /tmp/part.info ; \
    echo \"/dev/${SD_PART}2 : start= \${P2_START}, size= \${ROOT_SIZE}, type=83\" >> /tmp/part.info ; \
    echo \"/dev/${SD_PART}3 : start= \${P3_START}, type=83\" >> /tmp/part.info ; \
    sfdisk --no-reread -f /dev/${SD_DEV} < /tmp/part.info ; \
    rm /tmp/part.info ; \
    echo \"unmount /data/openwrt - ignore error if not AR750S\" ; \
    umount /data/openwrt ; \
    rm -rf /data/openwrt ; \
    umount /dev/${SD_PART}2 ; \
    e2fsck -f /dev/${SD_PART}2 ; \
    resize2fs /dev/${SD_PART}2 ; \
    umount /dev/${SD_PART}3 ; \
    mkfs.ext4 /dev/${SD_PART}3 ; \
    mkdir -p /tmp/pi ; \
    mount -t ext4 /dev/${SD_PART}2 /tmp/pi/"

  ${SCP} -r ${PI_WORK_DIR}/config/* root@${EDGE_ROUTER}:/tmp/pi/etc/config
  ${SSH} root@${EDGE_ROUTER} "cat /etc/dropbear/authorized_keys >> /tmp/pi/etc/dropbear/authorized_keys ; \
    dropbearkey -y -f /root/.ssh/id_dropbear | grep \"^ssh-\" >> /tmp/pi/etc/dropbear/authorized_keys ; \
    rm -f /tmp/pi/etc/rc.d/*dnsmasq* ; \
    umount /dev/${SD_PART}1 ; \
    umount /dev/${SD_PART}2 ; \
    umount /dev/${SD_PART}3 ; \
    rm -rf /tmp/pi"
  echo "bastion.${LAB_DOMAIN}.         IN      A      ${BASTION_HOST}" | ${SSH} root@${EDGE_ROUTER} "cat >> /etc/bind/db.${LAB_DOMAIN}"
  echo "10    IN      PTR     bastion.${LAB_DOMAIN}."  | ${SSH} root@${EDGE_ROUTER} "cat >> /etc/bind/db.${EDGE_ARPA}"
  ${SSH} root@${EDGE_ROUTER} "/etc/init.d/named stop && /etc/init.d/named start"

}

function piSetup() {

CENTOS_MIRROR=$(yq e ".centos-mirror" ${LAB_CONFIG_FILE})

cat << EOF > ${PI_WORK_DIR}/MirrorSync.sh
#!/bin/bash

for i in BaseOS AppStream 
do 
  rsync  -avSHP --delete ${CENTOS_MIRROR}9-stream/\${i}/x86_64/os/ /usr/local/www/install/repos/\${i}/x86_64/os/ > /tmp/repo-mirror.\${i}.out 2>&1
done
EOF

cat << EOF > ${PI_WORK_DIR}/local-repos.repo
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

cat << EOF > ${PI_WORK_DIR}/chrony.conf
server ${BASTION_HOST} iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF

cat << EOF > ${PI_WORK_DIR}/uci.batch
del_list uhttpd.main.listen_http="[::]:80"
del_list uhttpd.main.listen_http="0.0.0.0:80"
del_list uhttpd.main.listen_https="[::]:443"
del_list uhttpd.main.listen_https="0.0.0.0:443"
del uhttpd.defaults
del uhttpd.main.cert
del uhttpd.main.key
del uhttpd.main.cgi_prefix
del uhttpd.main.lua_prefix
add_list uhttpd.main.listen_http="${BASTION_HOST}:80"
add_list uhttpd.main.listen_http="127.0.0.1:80"
set uhttpd.main.home='/usr/local/www'
set system.ntp.enable_server="1"
commit
EOF

  echo "Installing packages"
  ${SSH} root@${BASTION_HOST} "opkg update && opkg install ip-full uhttpd shadow bash wget git-http ca-bundle procps-ng-ps rsync curl libstdcpp6 libjpeg libnss lftp block-mount unzip ; \
    opkg list | grep \"^coreutils-\" | while read i ; \
    do opkg install \$(echo \${i} | cut -d\" \" -f1) ; \
    done
    echo \"Creating SSH keys\" ; \
    rm -rf /root/.ssh ; \
    mkdir -p /root/.ssh ; \
    dropbearkey -t rsa -s 4096 -f /root/.ssh/id_dropbear
    echo \"mounting /usr/local filesystem\" ; \
    let RC=0 ; \
    while [[ \${RC} -eq 0 ]] ; \
    do uci delete fstab.@mount[-1] ; \
    let RC=\$? ; \
    done; \
    PART_UUID=\$(block info /dev/mmcblk0p3 | cut -d\\\" -f2) ; \
    MOUNT=\$(uci add fstab mount) ; \
    uci set fstab.\${MOUNT}.target=/usr/local ; \
    uci set fstab.\${MOUNT}.uuid=\${PART_UUID} ; \
    uci set fstab.\${MOUNT}.enabled=1 ; \
    uci commit fstab ; \
    block mount ; \
    mkdir -p /usr/local/www/install/kickstart ; \
    mkdir /usr/local/www/install/postinstall ; \
    mkdir /usr/local/www/install/fcos ; \
    mkdir -p /root/bin ; \
    for i in BaseOS AppStream ; \
    do mkdir -p /usr/local/www/install/repos/\${i}/x86_64/os/ ; \
    done ;\
    dropbearkey -y -f /root/.ssh/id_dropbear | grep \"ssh-\" > /usr/local/www/install/postinstall/authorized_keys"

  echo "Installing Java 8 and 11"
  ${SSH} root@${BASTION_HOST} "mkdir /tmp/work-dir ; \
    cd /tmp/work-dir; \
    PKG=\"openjdk8-8 openjdk8-jre-8 openjdk8-jre-lib-8 openjdk8-jre-base-8 java-cacerts openjdk11-11 openjdk11-jdk-11 openjdk11-jre-headless-11\" ; \
    for package in \${PKG}; 
    do FILE=\$(lftp -e \"cls -1 edge/community/aarch64/\${package}*; quit\" http://dl-cdn.alpinelinux.org) ; \
      curl -LO http://dl-cdn.alpinelinux.org/alpine/\${FILE} ; \
    done ; \
    for i in \$(ls) ; \
    do tar xzf \${i} ; \
    done ; \
    mv ./usr/lib/jvm/java-1.8-openjdk /usr/local/java-1.8-openjdk ; \
    mv ./usr/lib/jvm/java-11-openjdk /usr/local/java-11-openjdk ; \
    opkg update  ; \
    opkg install ca-certificates  ; \
    rm -f /usr/local/java-1.8-openjdk/jre/lib/security/cacerts  ; \
    /usr/local/java-1.8-openjdk/bin/keytool -noprompt -importcert -file /etc/ssl/certs/ca-certificates.crt -keystore /usr/local/java-1.8-openjdk/jre/lib/security/cacerts -keypass changeit -storepass changeit ; \
    for i in \$(find /etc/ssl/certs -type f) ; \
    do ALIAS=\$(echo \${i} | cut -d\"/\" -f5) ; \
      /usr/local/java-1.8-openjdk/bin/keytool -noprompt -importcert -file \${i} -alias \${ALIAS}  -keystore /usr/local/java-1.8-openjdk/jre/lib/security/cacerts -keypass changeit -storepass changeit ; \
    done ; \
    cd ; \
    rm -rf /tmp/work-dir"

  ${SCP} ${PI_WORK_DIR}/local-repos.repo root@${BASTION_HOST}:/usr/local/www/install/postinstall/local-repos.repo
  ${SCP} ${PI_WORK_DIR}/chrony.conf root@${BASTION_HOST}:/usr/local/www/install/postinstall/chrony.conf
  ${SCP} ${PI_WORK_DIR}/MirrorSync.sh root@${BASTION_HOST}:/root/bin/MirrorSync.sh
  ${SSH} root@${BASTION_HOST} "chmod 750 /root/bin/MirrorSync.sh"
  echo "Apply UCI config, disable root password, and reboot"
  ${SCP} ${PI_WORK_DIR}/uci.batch root@${BASTION_HOST}:/tmp/uci.batch
  cat ${OKD_LAB_PATH}/ssh_key.pub | ${SSH} root@${BASTION_HOST} "cat >> /usr/local/www/install/postinstall/authorized_keys"
  ${SSH} root@${BASTION_HOST} "cat /tmp/uci.batch | uci batch ; passwd -l root ; reboot"
  echo "Setup complete."
  echo "After the Pi reboots, run ${SSH} root@${BASTION_HOST} \"nohup /root/bin/MirrorSync.sh &\""
}
