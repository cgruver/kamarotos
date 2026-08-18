


Put the DGX in headless mode
```bash
systemctl set-default multi-user.target
```

```bash
# uci set dhcp.efi64_boot_3=match
# uci set dhcp.efi64_boot_3.networkid='set:efi64'
# uci set dhcp.efi64_boot_3.match='60,PXEClient:Arch:0000B'
# uci commit
```

Get the Aarch64 compatible ipxe.efi

```bash
wget http://boot.ipxe.org/arm64-efi/ipxe.efi
```

Kernel command line: BOOT_IMAGE=/boot/vmlinuz-6.17.0-1014-nvidia root=UUID=7ca20240-3f1d-4c4a-888b-efdb1e5e2023 ro init_on_alloc=0 iommu.passthrough=0 console=tty0 plymouth.ignore-serial-consoles plymouth.use-simpledrm earlycon=uart,mmio32,0x16A00000 console=tty0 console=ttyS0,921600 crashkernel=1G-:0M quiet splash initcall_blacklist=tegra234_cbb_init pci=pcie_bus_safe vt.handoff=7

#!ipxe

initrd --name initrd http://10.11.12.1/install/fcos/ignition/sno-dgx.clg.lab/initrd
initrd --name rootfs http://10.11.12.1/install/fcos/ignition/sno-dgx.clg.lab/rootfs.img
kernel http://10.11.12.1/install/fcos/ignition/sno-dgx.clg.lab/vmlinuz logo.nologo ignition.firstboot ignition.platform.id=metal initrd=initrd initrd=rootfs init_on_alloc=0 iommu.passthrough=0 console=tty0 plymouth.ignore-serial-consoles plymouth.use-simpledrm earlycon=uart,mmio32,0x16A00000 crashkernel=1G-:0M initcall_blacklist=tegra234_cbb_init pci=pcie_bus_safe vt.handoff=7

boot

#!ipxe

kernel http://10.11.12.1/install/fcos/ignition/clg-lab.clg.lab/gx10/vmlinuz logo.nologo nomodset net.ifnames=1 ifname=nic0:30:c5:99:3f:a7:e7 ip=10.11.12.76::10.11.12.1:255.255.255.0:clg-lab-worker-6.clg.lab:nic0:none nameserver=10.11.12.1 rd.neednet=1 coreos.inst.install_dev=/dev/disk/by-path/pci-0004:01:00.0-nvme-1 coreos.inst.ignition_url=http://10.11.12.1/install/fcos/ignition/clg-lab.clg.lab/30-c5-99-3f-a7-e7.ign coreos.inst.platform_id=metal initrd=initrd.img initrd=rootfs.img console=tty0
initrd http://10.11.12.1/install/fcos/ignition/clg-lab.clg.lab/gx10/initrd.img
initrd http://10.11.12.1/install/fcos/ignition/clg-lab.clg.lab/gx10/rootfs.img

boot

```
openshift-install coreos print-stream-json | jq
oc -n openshift-machine-config-operator get configmap/coreos-bootimages -o jsonpath='{.data.stream}' | jq -r '.architectures.aarch64.artifacts.metal.formats.pxe.kernel.location'
```

```bash
WORK_DIR=${HOME}/openshift-lab/sno-dgx.clg.lab/openshift-install-dir/boot-artifacts

kernel=https://rhcos.mirror.openshift.com/art/storage/prod/streams/rhel-10.2/builds/10.2.20260405-0/aarch64/rhcos-10.2.20260405-0-live-kernel.aarch64
initramfs=https://rhcos.mirror.openshift.com/art/storage/prod/streams/rhel-10.2/builds/10.2.20260405-0/aarch64/rhcos-10.2.20260405-0-live-initramfs.aarch64.img
rootfs=https://rhcos.mirror.openshift.com/art/storage/prod/streams/rhel-10.2/builds/10.2.20260405-0/aarch64/rhcos-10.2.20260405-0-live-rootfs.aarch64.img

# for i in kernel initramfs rootfs
# do
#   URL=$(openshift-install coreos print-stream-json --stream rhel-10 | jq -r ".architectures.aarch64.artifacts.metal.formats.pxe.${i}.location")
#   curl -o ${WORK_DIR}/rhel-10-${i} ${URL}
# done
# mv rhel-10-initramfs rhel-10-initramfs.tmp
```

```bash
podman run -it --rm -v ${WORK_DIR}:/data:Z -w /data --entrypoint /bin/bash quay.io/coreos/coreos-installer:release

coreos-installer pxe customize --live-ignition <(coreos-installer pxe ignition unwrap agent.aarch64-initrd.img) -o rhel-10-initramfs rhel-10-initramfs.tmp
```

```bash
scp ${WORK_DIR}/rhel-10-initramfs root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/initrd
scp ${WORK_DIR}/rhel-10-kernel root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/vmlinuz
scp ${WORK_DIR}/rhel-10-rootfs root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/rootfs.img
```

```
coreos-installer install -I http://10.11.12.1/install/fcos/ignition/clg-lab.clg.lab/30-c5-99-3f-a7-e7.ign --console tty0 --append-karg logo.nologo -n --insecure-ignition --insecure
```

 /etc/containers/policy.json

{
    "default": [
        {
            "type": "insecureAcceptAnything"
        }
    ]
}


