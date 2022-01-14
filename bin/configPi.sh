SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
INIT=false
SETUP=false
NEXUS=false
GITEA=false
CONFIG_FILE=${LAB_CONFIG_FILE}

for i in "$@"
do
  case ${i} in
    -i|--init)
      INIT=true
      shift
    ;;
    -s|--setup)
      SETUP=true
      shift
    ;;
    -n|--nexus)
      NEXUS=true
      shift
    ;;
    -g|--gitea)
      GITEA=true
      shift
    ;;
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      shift
    ;;
    *)
          echo "USAGE: configPi.sh [[-i|--init] | -s|--setup [-n|--nexus] [-g|--gitea]] [-c|--config=path/to/config/file] "
    ;;
  esac
done

function initPi() {

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
\toption netmask '${NETMASK}'\n
\toption gateway '${ROUTER}'\n
\toption dns '${ROUTER}'\n
EOF

echo -e ${FILE} > ${WORK_DIR}/config/network

read -r -d '' FILE << EOF
config dropbear\n
\toption PasswordAuth 'off'\n
\toption RootPasswordAuth 'off'\n
\toption Port '22'\n
EOF

echo -e ${FILE} > ${WORK_DIR}/config/dropbear

read -r -d '' FILE << EOF
config system\n
\toption timezone 'UTC'\n
\toption ttylogin '0'\n
\toption log_size '64'\n
\toption urandom_seed '0'\n
\toption hostname 'bastion.${DOMAIN}'\n
\n
config timeserver 'ntp'\n
\toption enabled '1'\n
\toption enable_server '0'\n
\tlist server '0.openwrt.pool.ntp.org'\n
\tlist server '1.openwrt.pool.ntp.org'\n
\tlist server '2.openwrt.pool.ntp.org'\n
\tlist server '3.openwrt.pool.ntp.org'\n
EOF

echo -e ${FILE} > ${WORK_DIR}/config/system

}

function setupPi() {

cat << EOF > ${WORK_DIR}/MirrorSync.sh
#!/bin/bash

for i in BaseOS AppStream PowerTools extras
do 
  rsync  -avSHP --delete ${CENTOS_MIRROR}8-stream/\${i}/x86_64/os/ /usr/local/www/install/repos/\${i}/x86_64/os/ > /tmp/repo-mirror.\${i}.out 2>&1
done
EOF

cat << EOF > ${WORK_DIR}/local-repos.repo
[local-appstream]
name=AppStream
baseurl=http://${BASTION_HOST}/install/repos/AppStream/x86_64/os/
gpgcheck=0
enabled=1

[local-extras]
name=extras
baseurl=http://${BASTION_HOST}/install/repos/extras/x86_64/os/
gpgcheck=0
enabled=1

[local-baseos]
name=BaseOS
baseurl=http://${BASTION_HOST}/install/repos/BaseOS/x86_64/os/
gpgcheck=0
enabled=1

[local-powertools]
name=PowerTools
baseurl=http://${BASTION_HOST}/install/repos/PowerTools/x86_64/os/
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

cat << EOF > ${WORK_DIR}/uci.batch
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
}

function installNexus() {

cat <<EOF > ${WORK_DIR}/nexus
#!/bin/sh /etc/rc.common

START=99
STOP=80
SERVICE_USE_PID=0

start() {
   ulimit -Hn 65536
   ulimit -Sn 65536
    service_start /usr/local/nexus/nexus-3/bin/nexus start
}

stop() {
    service_stop /usr/local/nexus/nexus-3/bin/nexus stop
}
EOF

cat <<EOF > ${WORK_DIR}/nexus.properties
nexus-args=\${jetty.etc}/jetty.xml,\${jetty.etc}/jetty-https.xml,\${jetty.etc}/jetty-requestlog.xml
application-port-ssl=8443
EOF

}

function installGitea() {

cat << EOF > ${WORK_DIR}/app.ini
RUN_USER = gitea
RUN_MODE = prod

[repository]
ROOT = /usr/local/gitea/git
SCRIPT_TYPE = sh
DEFAULT_BRANCH = main
DEFAULT_PUSH_CREATE_PRIVATE = true
ENABLE_PUSH_CREATE_USER = true
ENABLE_PUSH_CREATE_ORG = true

[server]
PROTOCOL = https
ROOT_URL = https://gitea.${DOMAIN}:3000/
HTTP_PORT = 3000
CERT_FILE = cert.pem
KEY_FILE  = key.pem
STATIC_ROOT_PATH = /usr/local/gitea/web
APP_DATA_PATH    = /usr/local/gitea/data
LFS_START_SERVER = true

[service]
DISABLE_REGISTRATION = true

[database]
DB_TYPE = sqlite3
PATH = /usr/local/gitea/db/gitea.db

[security]
INSTALL_LOCK = true
SECRET_KEY = ${SECRET_KEY}
INTERNAL_TOKEN = ${INTERNAL_TOKEN}

[oauth2]
JWT_SECRET = ${JWT_SECRET}

[session]
PROVIDER = file

[log]
ROOT_PATH = /usr/local/gitea/log
MODE = file
LEVEL = Info
EOF

cat <<EOF > ${WORK_DIR}/gitea
#!/bin/sh /etc/rc.common

START=99
STOP=80
SERVICE_USE_PID=0

start() {
   service_start /usr/bin/su - gitea -c 'GITEA_WORK_DIR=/usr/local/gitea /usr/bin/nohup /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini web > /dev/null 2>&1 &'
}

restart() {
   /usr/bin/su - gitea -c 'GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini manager restart'
}

stop() {
   /usr/bin/su - gitea -c 'GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini manager shutdown'
}
EOF

cat <<EOF > ${WORK_DIR}/giteaInit.sh
su - gitea -c 'GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini migrate'
su - gitea -c "GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini admin user create --admin --username gitea --password password --email gitea@gitea.${DOMAIN} --must-change-password"
su - gitea -c "GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini admin user create --username devuser --password password --email devuser@gitea.${DOMAIN} --must-change-password"
EOF

}

if [[ ${CONFIG_FILE} == "" ]]
then
echo "You must specify a lab configuration YAML file."
exit 1
fi

DOMAIN=$(yq e ".domain" ${CONFIG_FILE})
ROUTER=$(yq e ".router" ${CONFIG_FILE})
NETWORK=$(yq e ".network" ${CONFIG_FILE})
NETMASK=$(yq e ".netmask" ${CONFIG_FILE})
BASTION_HOST=$(yq e ".bastion-ip" ${CONFIG_FILE})


IFS=. read -r i1 i2 i3 i4 << EOF
${NETWORK}
EOF
NET_PREFIX=${i1}.${i2}.${i3}
NET_PREFIX_ARPA=${i3}.${i2}.${i1}
WORK_DIR=${OKD_LAB_PATH}/work-dir-pi
rm -rf ${WORK_DIR}
mkdir -p ${WORK_DIR}/config

if [[ ${INIT} == "true" ]]
then
  OPENWRT_VER=$(yq e ".openwrt-version" ${CONFIG_FILE})
  
  wget https://downloads.openwrt.org/releases/${OPENWRT_VER}/targets/bcm27xx/bcm2711/openwrt-${OPENWRT_VER}-bcm27xx-bcm2711-rpi-4-ext4-factory.img.gz -O ${WORK_DIR}/openwrt-${OPENWRT_VER}-bcm27xx-bcm2711-rpi-4-ext4-factory.img.gz
  gunzip ${WORK_DIR}/openwrt-${OPENWRT_VER}-bcm27xx-bcm2711-rpi-4-ext4-factory.img.gz
  ${SCP} ${WORK_DIR}/openwrt-${OPENWRT_VER}-bcm27xx-bcm2711-rpi-4-ext4-factory.img root@${ROUTER}:/data/openwrt.img
  
  ${SSH} root@${ROUTER} "umount /dev/mmcblk1p1 ; dd if=/data/openwrt.img of=/dev/mmcblk1 bs=4M conv=fsync ; rm /data/openwrt.img"
  ${SSH} root@${ROUTER} "PART_INFO=\$(sfdisk -l /dev/mmcblk1 | grep mmcblk1p2) ; \
    let ROOT_SIZE=41943040 ; \
    let P2_START=$(echo \${PART_INFO} | cut -d" " -f2) ; \
    let P3_START=$(( \${P2_START}+\${ROOT_SIZE}+8192 )) ; \
    sfdisk --delete /dev/mmcblk1 2 ; \
    sfdisk -d /dev/mmcblk1 > /tmp/part.info ; \
    echo "/dev/mmcblk1p2 : start= \${P2_START}, size= \${ROOT_SIZE}, type=83" >> /tmp/part.info ; \
    echo "/dev/mmcblk1p3 : start= \${P3_START}, type=83" >> /tmp/part.info ; \
    umount /dev/mmcblk1p1 ; \
    sfdisk /dev/mmcblk1 < /tmp/part.info ; \
    rm /tmp/part.info"
  ${SSH} root@${ROUTER} "e2fsck -f /dev/mmcblk1p2 ; resize2fs /dev/mmcblk1p2 ; mkfs.ext4 /dev/mmcblk1p3"
  ${SSH} root@${ROUTER} "mkdir /tmp/pi ; mount -t ext4 /dev/mmcblk1p2 /tmp/pi/"
  initPi
  ${SCP} -r ${WORK_DIR}/config/* root@${ROUTER}:/tmp/pi/etc/config
  ${SSH} root@${ROUTER} "cat /etc/dropbear/authorized_keys >> /tmp/pi/etc/dropbear/authorized_keys ; \
    dropbearkey -y -f /root/.ssh/id_dropbear | grep "^ssh-" >> /tmp/pi/etc/dropbear/authorized_keys ; \
    rm -f /tmp/pi/etc/rc.d/*dnsmasq* ; \
    umount /dev/mmcblk1p1 ; \
    umount /dev/mmcblk1p2 ; \
    umount /dev/mmcblk1p3"
  echo "bastion.${DOMAIN}.         IN      A      ${BASTION_HOST}" | ${SSH} root@${ROUTER} "cat >> /etc/bind/db.${DOMAIN}"
  echo "10    IN      PTR     bastion.${DOMAIN}."  | ${SSH} root@${ROUTER} "cat >> /etc/bind/db.${NET_PREFIX_ARPA}"
  ${SSH} root@${ROUTER} "/etc/init.d/named stop && /etc/init.d/named start"
fi

if [[ ${SETUP} == "true" ]]
then
  CENTOS_MIRROR=$(yq e ".centos-mirror" ${CONFIG_FILE})

  echo "Installing packages"
  ${SSH} root@${BASTION_HOST} "opkg update && opkg install ip-full uhttpd shadow bash wget git-http ca-bundle procps-ng-ps rsync curl libstdcpp6 libjpeg libnss lftp block-mount"
  ${SSH} root@${BASTION_HOST} "opkg list | grep "^coreutils-" | while read i ; do opkg install $(echo ${i} | cut -d" " -f1) ; done"
  echo "Creating SSH keys"
  ${SSH} root@${BASTION_HOST} "rm -rf /root/.ssh ; mkdir -p /root/.ssh ; dropbearkey -t rsa -s 4096 -f /root/.ssh/id_dropbear"
  echo "mounting /usr/local filesystem"
  ${SSH} root@${BASTION_HOST} "let RC=0 ; \
    while [[ \${RC} -eq 0 ]] ; \
    do uci delete fstab.@mount[-1] ; \
    let RC=\$? ; \
    done; \
    PART_UUID=\$(block info /dev/mmcblk0p3 | cut -d\" -f2) ; \
    MOUNT=\$(uci add fstab mount) ; \
    uci set fstab.\${MOUNT}.target=/usr/local ; \
    uci set fstab.\${MOUNT}.uuid=\${PART_UUID} ; \
    uci set fstab.\${MOUNT}.enabled=1 ; \
    uci commit fstab ; \
    block mount"
  ${SSH} root@${BASTION_HOST} "mkdir -p /usr/local/www/install/kickstart ; mkdir /usr/local/www/install/postinstall ; mkdir /usr/local/www/install/fcos ; mkdir -p /root/bin"
  ${SSH} root@${BASTION_HOST} "for i in BaseOS AppStream PowerTools extras ; do mkdir -p /usr/local/www/install/repos/${i}/x86_64/os/ ; done"
  ${SSH} root@${BASTION_HOST} "dropbearkey -y -f /root/.ssh/id_dropbear | grep \"ssh-\" > /usr/local/www/install/postinstall/authorized_keys"
  ${SCP} ${WORK_DIR}/local-repos.repo root@${BASTION_HOST}:/usr/local/www/install/postinstall/local-repos.repo
  ${SCP} ${WORK_DIR}/chrony.conf root@${BASTION_HOST}:/usr/local/www/install/postinstall/chrony.conf
  ${SSH} root@${BASTION_HOST} "mkdir -p /root/bin"
  ${SCP} ${WORK_DIR}/MirrorSync.sh root@${BASTION_HOST}:/root/bin/MirrorSync.sh
  ${SSH} root@${BASTION_HOST} "chmod 750 /root/bin/MirrorSync.sh"
  echo "Apply UCI config, disable root password, and reboot"
  ${SCP} ${WORK_DIR}/uci.batch root@${BASTION_HOST}:/tmp/uci.batch
  ${SSH} root@${BASTION_HOST} "uci batch << /tmp/uci.batch && passwd -l root && reboot"
  echo "Setup complete."
  echo "After the Pi reboots, run ${SSH} root@${BASTION_HOST} \"nohup /root/bin/MirrorSync.sh &\""
fi

if [[ ${NEXUS} == "true" ]]
then
  installNexus
  ${SSH} root@${BASTION_HOST} "mkdir /tmp/work-dir ; \
    cd /tmp/work-dir; \
    PKG=\"openjdk8-8 openjdk8-jre-8 openjdk8-jre-lib-8 openjdk8-jre-base-8 java-cacerts\" ; \
    for package in \${PKG}; do
      FILE=\$(lftp -e \"cls -1 alpine/edge/community/aarch64/${package}*; quit\" http://dl-cdn.alpinelinux.org) ; \
      curl -LO http://dl-cdn.alpinelinux.org/\${FILE} ; \
    done ; \
    for i in \$(ls) ; \
    do tar xzf \${i} ; \
    done ; \
    mv ./usr/lib/jvm/java-1.8-openjdk /usr/local/java-1.8-openjdk ; \
    echo \"export PATH=\\\$PATH:/root/bin:/usr/local/java-1.8-openjdk/bin\" >> /root/.profile ; \
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

  ${SSH} root@${BASTION_HOST} "mkdir -p /usr/local/nexus/home ; \
    cd /usr/local/nexus ; \
    wget https://download.sonatype.com/nexus/3/latest-unix.tar.gz -O latest-unix.tar.gz ; \
    tar -xzf latest-unix.tar.gz ; \
    NEXUS=\$(ls -d nexus-*) ; \
    ln -s \${NEXUS} nexus-3 ; \
    rm -f latest-unix.tar.gz ; \
    groupadd nexus ; \
    useradd -g nexus -d /usr/local/nexus/home nexus ; \
    chown -R nexus:nexus /usr/local/nexus"
  ${SSH} root@${BASTION_HOST} 'sed -i "s|#run_as_user=\"\"|run_as_user=\"nexus\"|g" /usr/local/nexus/nexus-3/bin/nexus.rc'
  
  ${SCP} ${WORK_DIR}/nexus root@${BASTION_HOST}:/etc/init.d/nexus
  ${SSH} root@${BASTION_HOST} "chmod 755 /etc/init.d/nexus"

  ${SSH} root@${BASTION_HOST} 'sed -i "s|# INSTALL4J_JAVA_HOME_OVERRIDE=|INSTALL4J_JAVA_HOME_OVERRIDE=/usr/local/java-1.8-openjdk|g" /usr/local/nexus/nexus-3/bin/nexus'

  ${SSH} root@${BASTION_HOST} "/usr/local/java-1.8-openjdk/bin/keytool -genkeypair -keystore /usr/local/nexus/nexus-3/etc/ssl/keystore.jks -deststoretype pkcs12 -storepass password -keypass password -alias jetty -keyalg RSA -keysize 4096 -validity 5000 -dname \"CN=nexus.${DOMAIN}, OU=okd4-lab, O=okd4-lab, L=City, ST=State, C=US\" -ext \"SAN=DNS:nexus.${DOMAIN},IP:${BASTION_HOST}\" -ext \"BC=ca:true\" ; \
    /usr/local/java-1.8-openjdk/bin/keytool -importkeystore -srckeystore /usr/local/nexus/nexus-3/etc/ssl/keystore.jks -destkeystore /usr/local/nexus/nexus-3/etc/ssl/keystore.jks -deststoretype pkcs12 -srcstorepass password  ; \
    rm -f /usr/local/nexus/nexus-3/etc/ssl/keystore.jks.old  ; \
    chown nexus:nexus /usr/local/nexus/nexus-3/etc/ssl/keystore.jks  ; \
    mkdir /usr/local/nexus/sonatype-work/nexus3/etc"
  cat ${WORK_DIR}/nexus.properties | ${SSH} root@${BASTION_HOST} "cat >> /usr/local/nexus/sonatype-work/nexus3/etc/nexus.properties"
  ${SSH} root@${BASTION_HOST} "chown -R nexus:nexus /usr/local/nexus/sonatype-work/nexus3/etc ; /etc/init.d/nexus enable ; reboot"
  echo "nexus.${DOMAIN}.           IN      A      ${BASTION_HOST}" | ${SSH} root@${ROUTER} "cat >> /etc/bind/db.${DOMAIN}"
  ${SSH} root@${ROUTER} "/etc/init.d/named stop && /etc/init.d/named start"
fi

if [[ ${GITEA} == "true" ]]
then
  GITEA_VERSION=$(yq e ".gitea-version" ${CONFIG_FILE})

  ${SSH} root@${BASTION_HOST} "opkg update && opkg install sqlite3-cli openssh-keygen ; \
    mkdir -p /usr/local/gitea ; \
    for i in bin etc custom data db git ; \
    do mkdir /usr/local/gitea/\${i} ; \
    done ; \
    wget -O /usr/local/gitea/bin/gitea https://dl.gitea.io/gitea/${GITEA_VERSION}/gitea-${GITEA_VERSION}-linux-arm64 ; \
    chmod 750 /usr/local/gitea/bin/gitea ; \
    cd /usr/local/gitea/custom ; \
    /usr/local/gitea/bin/gitea cert --host gitea.${DOMAIN} ; \
    groupadd gitea ; \
    useradd -g gitea -d /usr/local/gitea gitea ; \
    chown -R gitea:gitea /usr/local/gitea"
  INTERNAL_TOKEN=$(${SSH} root@${BASTION_HOST} "/usr/local/gitea/bin/gitea generate secret INTERNAL_TOKEN")
  SECRET_KEY=$(${SSH} root@${BASTION_HOST} "/usr/local/gitea/bin/gitea generate secret SECRET_KEY")
  JWT_SECRET=$(${SSH} root@${BASTION_HOST} "/usr/local/gitea/bin/gitea generate secret JWT_SECRET")
  installGitea

  ${SCP} ${WORK_DIR}/app.ini root@${BASTION_HOST}:/usr/local/gitea/etc/app.ini
  ${SCP} ${WORK_DIR}/gitea root@${BASTION_HOST}:/etc/init.d/gitea
  ${SSH} root@${BASTION_HOST} "chmod 755 /etc/init.d/gitea"
  ${SCP} ${WORK_DIR}/giteaInit.sh root@${BASTION_HOST}:/tmp/giteaInit.sh
  ${SSH} root@${BASTION_HOST} "chmod 755 /tmp/giteaInit.sh ; /tmp/giteaInit.sh ; /etc/init.d/gitea enable ; /etc/init.d/gitea start"
  echo "gitea.${DOMAIN}.           IN      A      ${BASTION_HOST}" | ${SSH} root@${ROUTER} "cat >> /etc/bind/db.${DOMAIN}"
  ${SSH} root@${ROUTER} "/etc/init.d/named stop && /etc/init.d/named start"
fi

