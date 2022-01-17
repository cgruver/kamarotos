#!/bin/bash
. ${OKD_LAB_PATH}/bin/labctx.env

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
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      shift
    ;;
    *)
          echo "USAGE: initPi.sh [-c|--config=path/to/config/file] "
    ;;
  esac
done

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

OPENWRT_VER=$(yq e ".openwrt-version" ${CONFIG_FILE})

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
\toption PasswordAuth off\n
\toption RootPasswordAuth off\n
\toption Port 22\n
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

${SSH} root@${ROUTER} "umount /dev/mmcblk1p1 ; \
  umount /dev/mmcblk1p2 ; \
  umount /dev/mmcblk1p3 ; \
  dd if=/dev/zero of=/dev/mmcblk1 bs=4096 count=1 ; \
  wget https://downloads.openwrt.org/releases/${OPENWRT_VER}/targets/bcm27xx/bcm2711/openwrt-${OPENWRT_VER}-bcm27xx-bcm2711-rpi-4-ext4-factory.img.gz -O /data/openwrt.img.gz ; \
  gunzip /data/openwrt.img.gz ; \
  dd if=/data/openwrt.img of=/dev/mmcblk1 bs=4M conv=fsync ; \
  PART_INFO=\$(sfdisk -l /dev/mmcblk1 | grep mmcblk1p2) ; \
  let ROOT_SIZE=41943040 ; \
  let P2_START=\$(echo \${PART_INFO} | cut -d\" \" -f2) ; \
  let P3_START=\$(( \${P2_START}+\${ROOT_SIZE}+8192 )) ; \
  sfdisk --no-reread -f --delete /dev/mmcblk1 2 ; \
  sfdisk --no-reread -f -d /dev/mmcblk1 > /tmp/part.info ; \
  echo \"/dev/mmcblk1p2 : start= \${P2_START}, size= \${ROOT_SIZE}, type=83\" >> /tmp/part.info ; \
  echo \"/dev/mmcblk1p3 : start= \${P3_START}, type=83\" >> /tmp/part.info ; \
  sfdisk --no-reread -f /dev/mmcblk1 < /tmp/part.info ; \
  rm /tmp/part.info ; \
  rm /data/openwrt.img ; \
  e2fsck -f /dev/mmcblk1p2 ; \
  resize2fs /dev/mmcblk1p2 ; \
  mkfs.ext4 /dev/mmcblk1p3 ; \
  mkdir -p /tmp/pi ; \
  mount -t ext4 /dev/mmcblk1p2 /tmp/pi/"

${SCP} -r ${WORK_DIR}/config/* root@${ROUTER}:/tmp/pi/etc/config
${SSH} root@${ROUTER} "cat /etc/dropbear/authorized_keys >> /tmp/pi/etc/dropbear/authorized_keys ; \
  dropbearkey -y -f /root/.ssh/id_dropbear | grep \"^ssh-\" >> /tmp/pi/etc/dropbear/authorized_keys ; \
  rm -f /tmp/pi/etc/rc.d/*dnsmasq* ; \
  umount /dev/mmcblk1p1 ; \
  umount /dev/mmcblk1p2 ; \
  umount /dev/mmcblk1p3 ; \
  rm -rf /tmp/pi"
echo "bastion.${DOMAIN}.         IN      A      ${BASTION_HOST}" | ${SSH} root@${ROUTER} "cat >> /etc/bind/db.${DOMAIN}"
echo "10    IN      PTR     bastion.${DOMAIN}."  | ${SSH} root@${ROUTER} "cat >> /etc/bind/db.${NET_PREFIX_ARPA}"
${SSH} root@${ROUTER} "/etc/init.d/named stop && /etc/init.d/named start"
