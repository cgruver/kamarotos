
rm -rf /root/.ssh
mkdir -p /root/.ssh
dropbearkey -t ed25519 -f /root/.ssh/id_dropbear

PART_UUID=$(block info /dev/mmcblk0p1 | cut -d\" -f2)
MOUNT=$(uci add fstab mount)
uci set fstab.${MOUNT}.target=/usr/local
uci set fstab.${MOUNT}.uuid=${PART_UUID}
uci set fstab.${MOUNT}.enabled=1
uci commit fstab
block mount

