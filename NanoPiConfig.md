

## Format Disk

```bash
ssh root@192.168.1.1

opkg update
opkg install lsblk sfdisk losetup resize2fs
SD_DEV=mmcblk1
SD_PART=mmcblk1p

PART_INFO=$(sfdisk -l /dev/${SD_DEV} | grep ${SD_PART}2)
let P2_START=$(echo ${PART_INFO} | cut -d" " -f2)
sfdisk --no-reread -f --delete /dev/${SD_DEV} 2
sfdisk --no-reread -f -d /dev/${SD_DEV} > /tmp/part.info
echo "/dev/${SD_PART}2 : start= ${P2_START}, type=83" >> /tmp/part.info
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
opkg install ip-full uhttpd shadow bash wget git-http ca-bundle procps-ng-ps rsync curl libstdcpp6 libjpeg libnss lftp block-mount unzip wipefs
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

```bash
new_rule=$(ssh root@router.clg.lab "uci add firewall rule")
ssh root@router.clg.lab "uci set firewall.${new_rule}.enabled=1 ; \
    uci set firewall.${new_rule}.target=REJECT ; \
    uci set firewall.${new_rule}.src=lan ; \
    uci set firewall.${new_rule}.dest=wan ; \
    uci set firewall.${new_rule}.name=${CLUSTER_NAME}-internet-deny ; \
    uci set firewall.${new_rule}.proto=all ; \
    uci set firewall.${new_rule}.family=ipv4"
let node_count=$(yq e ".control-plane.nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
let node_index=0
while [[ node_index -lt ${node_count} ]]
do
  node_ip=$(yq e ".control-plane.nodes.[${node_index}].ip-addr" ${CLUSTER_CONFIG})
  ssh root@router.clg.lab "uci add_list firewall.${new_rule}.src_ip=\"${node_ip}\""
  node_index=$(( ${node_index} + 1 ))
done
let node_count=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
let node_index=0
while [[ node_index -lt ${node_count} ]]
do
  node_ip=$(yq e ".compute-nodes.[${node_index}].ip-addr" ${CLUSTER_CONFIG})
  ssh root@router.clg.lab "uci add_list firewall.${new_rule}.src_ip=\"${node_ip}\""
  node_index=$(( ${node_index} + 1 ))
done
ssh root@router.clg.lab "uci commit firewall && /etc/init.d/firewall restart"
```
