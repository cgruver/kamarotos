function snoIso() {

cat << EOF > ${OKD4_SNC_PATH}/fcos-iso/isolinux/isolinux.cfg
serial 0
default vesamenu.c32
timeout 1
menu clear
menu separator
label linux
  menu label ^Fedora CoreOS (Live)
  menu default
  kernel /images/vmlinuz
  append initrd=/images/initramfs.img,/images/rootfs.img net.ifnames=1 ifname=nic0:${BOOT_MAC} ip=${IP}::${SNC_GATEWAY}:${SNC_NETMASK}:okd4-snc-bootstrap.${SNC_DOMAIN}:nic0:none nameserver=${SNC_NAMESERVER} rd.neednet=1 coreos.inst=yes coreos.inst.install_dev=/dev/sda coreos.inst.ignition_url=${INSTALL_URL}/fcos/ignition/bootstrap.ign coreos.inst.platform_id=qemu console=ttyS0
menu separator
menu end
EOF

  mkisofs -o /tmp/bootstrap.iso -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -J -r ${OKD4_SNC_PATH}/fcos-iso/

}