# NanoPi & Raspberry Pi config

## Init OS

```bash
OPENWRT_VER=$(yq e ".openwrt-version" ${LAB_CONFIG_FILE})
# NanoPi
OPENWRT_PATH=$(echo "${OPENWRT_VER}/targets/rockchip/armv8/openwrt-${OPENWRT_VER}-rockchip-armv8-friendlyarm_nanopi-r4s-ext4-sysupgrade.img.gz")
# Raspberry Pi
OPENWRT_PATH=$(echo "${OPENWRT_VER}/targets/bcm27xx/bcm2711/openwrt-${OPENWRT_VER}-bcm27xx-bcm2711-rpi-4-ext4-factory.img.gz")
```

```bash
diskutil list
export SD_DEV=/dev/disk4
```

```bash
sudo bash
TEMP_DIR=$(sudo mktemp -d)
sudo wget https://downloads.openwrt.org/releases/${OPENWRT_PATH} -O ${TEMP_DIR}/openwrt.img.gz
sudo gunzip ${TEMP_DIR}/openwrt.img.gz
sudo umount ${SD_DEV}s1
sudo dd if=${TEMP_DIR}/openwrt.img of=${SD_DEV} bs=4M conv=fsync
sudo diskutil eject ${SD_DEV}
sudo rm -rf ${TEMP_DIR}
```

## Set Up Network

```bash
cat ${OKD_LAB_PATH}/ssh_key.pub | ssh root@192.168.1.1 "cat >> /etc/dropbear/authorized_keys"
ssh root@192.168.1.1 "uci set dropbear.@dropbear[0].PasswordAuth=off ; \
  uci set dropbear.@dropbear[0].RootPasswordAuth=off ; \
  uci set network.lan.ipaddr="${PI_IP}" ; \
  uci set network.lan.netmask=${EDGE_NETMASK} ; \
  uci set network.lan.hostname=bastion.${LAB_DOMAIN} ; \
  uci set network.lan.gateway=${EDGE_ROUTER} ; \
  uci set network.lan.dns=${EDGE_ROUTER} ; \
  uci commit ; \
  rm -rf /etc/rc.d/*dnsmasq* ; \
  poweroff"
```

## Format Disk

```bash
ssh root@192.168.1.1

opkg update
opkg install lsblk sfdisk losetup resize2fs
SD_DEV=mmcblk1
SD_PART=mmcblk1p

PART_INFO=$(sfdisk -l /dev/${SD_DEV} | grep ${SD_PART}2)
let ROOT_SIZE=20971520
let P2_START=$(echo ${PART_INFO} | cut -d" " -f2)
let P3_START=$(( ${P2_START}+${ROOT_SIZE}+8192 ))
sfdisk --no-reread -f --delete /dev/${SD_DEV} 2
sfdisk --no-reread -f -d /dev/${SD_DEV} > /tmp/part.info
echo "/dev/${SD_PART}2 : start= ${P2_START}, size= ${ROOT_SIZE}, type=83" >> /tmp/part.info
echo "/dev/${SD_PART}3 : start= ${P3_START}, type=83" >> /tmp/part.info
sfdisk --no-reread -f /dev/${SD_DEV} < /tmp/part.info
rm /tmp/part.info
reboot
ssh root@192.168.1.1
LOOP="$(losetup -f)"
losetup ${LOOP} /dev/mmcblk1p2
e2fsck -y -f ${LOOP}
resize2fs ${LOOP}
reboot

ssh root@192.168.1.1
opkg update
opkg install ip-full uhttpd shadow bash wget git-http ca-bundle procps-ng-ps rsync curl libstdcpp6 libjpeg libnss lftp block-mount unzip wipefs kmod-rtl8812au-ct
opkg list | grep "^coreutils-" | while read i
do 
opkg install $(echo ${i} | cut -d" " -f1)
done

echo "Creating SSH keys"
rm -rf /root/.ssh
mkdir -p /root/.ssh
dropbearkey -t ed25519 -f /root/.ssh/id_dropbear

echo "creating /usr/local filesystem"
wipefs -af /dev/mmcblk1p3 
mkfs.ext4 /dev/mmcblk1p3
let RC=0
while [[ ${RC} -eq 0 ]]
do uci delete fstab.@mount[-1]
let RC=$?
done
PART_UUID=$(block info /dev/mmcblk1p3 | cut -d\" -f2)
MOUNT=$(uci add fstab mount)
uci set fstab.${MOUNT}.target=/usr/local
uci set fstab.${MOUNT}.uuid=${PART_UUID}
uci set fstab.${MOUNT}.enabled=1
uci commit fstab
block mount
mkdir -p /usr/local/www/install/kickstart
mkdir /usr/local/www/install/postinstall
mkdir /usr/local/www/install/fcos
mkdir -p /root/bin
for i in BaseOS AppStream
do mkdir -p /usr/local/www/install/repos/${i}/x86_64/os/
done
dropbearkey -y -f /root/.ssh/id_dropbear | grep "ssh-" >> /usr/local/www/install/postinstall/authorized_keys


```

## Raspberry Pi Script

Init SD Card

```bash
sudo -E bash
OPENWRT_VER=$(yq e ".openwrt-version" ${LAB_CONFIG_FILE})
SD_DEV=$(diskutil list | grep external | cut -d" " -f1)
OPENWRT_PATH=$(echo "${OPENWRT_VER}/targets/bcm27xx/bcm2711/openwrt-${OPENWRT_VER}-bcm27xx-bcm2711-rpi-4-ext4-factory.img.gz")
TEMP_DIR=$(mktemp -d)
wget https://downloads.openwrt.org/releases/${OPENWRT_PATH} -O ${TEMP_DIR}/openwrt.img.gz
gunzip ${TEMP_DIR}/openwrt.img.gz
dd if=${TEMP_DIR}/openwrt.img of=${SD_DEV} bs=4M conv=fsync
diskutil eject ${SD_DEV}
rm -rf ${TEMP_DIR}
exit
```

### Set Up Network

```bash
cat ${OKD_LAB_PATH}/ssh_key.pub | ssh root@192.168.1.1 "cat >> /etc/dropbear/authorized_keys"
ssh root@192.168.1.1 "uci set dropbear.@dropbear[0].PasswordAuth=off ; \
  uci set dropbear.@dropbear[0].RootPasswordAuth=off ; \
  uci set network.lan.ipaddr="${PI_IP}" ; \
  uci set network.lan.netmask=${EDGE_NETMASK} ; \
  uci set network.lan.hostname=bastion.${LAB_DOMAIN} ; \
  uci set network.lan.gateway=${EDGE_ROUTER} ; \
  uci set network.lan.dns=${EDGE_ROUTER} ; \
  uci commit ; \
  rm -rf /etc/rc.d/*dnsmasq* ; \
  poweroff"
```

### Initialize Pi

```bash
ssh root@${PI_IP} "opkg update && 
  opkg install lsblk sfdisk losetup resize2fs ip-full uhttpd shadow bash wget git-http ca-bundle procps-ng-ps rsync curl libstdcpp6 libjpeg libnss lftp block-mount unzip wipefs &&
  opkg list | grep \"^coreutils-\" | while read i ; \
  do opkg install \$(echo \${i} | cut -d\" \" -f1) ; \
  done ; \
SD_DEV=mmcblk0 ; \
SD_PART=mmcblk0p ; \
PART_INFO=\$(sfdisk -l /dev/\${SD_DEV} | grep \${SD_PART}2) ; \
let ROOT_SIZE=20971520 ; \
let P2_START=\$(echo \${PART_INFO} | cut -d\" \" -f2) ; \
let P3_START=\$(( \${P2_START}+\${ROOT_SIZE}+8192 )) ; \
sfdisk --no-reread -f --delete /dev/\${SD_DEV} 2 ; \
sfdisk --no-reread -f -d /dev/\${SD_DEV} > /tmp/part.info ; \
echo \"/dev/\${SD_PART}2 : start= \${P2_START}, size= \${ROOT_SIZE}, type=83\" >> /tmp/part.info ; \
echo \"/dev/\${SD_PART}3 : start= \${P3_START}, type=83\" >> /tmp/part.info ; \
sfdisk --no-reread -f /dev/\${SD_DEV} < /tmp/part.info ; \
rm /tmp/part.info ; \
reboot"

ssh root@${PI_IP} "LOOP=\"\$(losetup -f)\" ; \
  losetup \${LOOP} /dev/mmcblk0p2 ; \
  e2fsck -y -f \${LOOP} ; \
  resize2fs \${LOOP} ; \
  reboot"

ssh root@${PI_IP} "echo \"Creating SSH keys\" ; \
  rm -rf /root/.ssh ; \
  mkdir -p /root/.ssh ; \
  dropbearkey -t ed25519 -f /root/.ssh/id_dropbear ; \
  echo \"creating /usr/local filesystem\" ; \
  wipefs -af /dev/mmcblk0p3  ; \
  mkfs.ext4 /dev/mmcblk0p3 ; \
  let RC=0 ; \
  while [[ \${RC} -eq 0 ]] ; \
  do uci delete fstab.@mount[-1] ; \
  let RC=\$? ; \
  done ; \
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
  done ; \
  dropbearkey -y -f /root/.ssh/id_dropbear | grep \"ssh-\" >> /usr/local/www/install/postinstall/authorized_keys ; \
  mkdir /tmp/work-dir ; \
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
```
