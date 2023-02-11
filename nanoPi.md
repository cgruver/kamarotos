# NanoPi 

```bash
diskutil list

sudo bash
TEMP_DIR=$(mktemp -d)
wget https://downloads.openwrt.org/releases/22.03.3/targets/rockchip/armv8/openwrt-22.03.3-rockchip-armv8-friendlyarm_nanopi-r4s-ext4-sysupgrade.img.gz -O ${TEMP_DIR}/openwrt.img.gz
gunzip ${TEMP_DIR}/openwrt.img.gz
dd if=${TEMP_DIR}/openwrt.img of=/dev/disk4 bs=4M conv=fsync
diskutil eject /dev/disk4
rm -rf ${TEMP_DIR}
exit
```

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
