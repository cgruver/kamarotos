
```bash
oc adm upgrade --to-multi-arch
# oc patch featuregate/cluster --type merge -p '{"spec":{"featureSet":"TechPreviewNoUpgrade"}}'
oc patch FeatureGate cluster --type merge --patch '{"spec":{"featureSet":"CustomNoUpgrade","customNoUpgrade":{"enabled":["OSStreams"]}}}'
oc patch mcp worker --type merge -p '{"spec":{"osImageStream":{"name":"rhel-10"}}}'
oc patch mcp master --type merge -p '{"spec":{"osImageStream":{"name":"rhel-10"}}}'
```


Enable Feature Gates - ImageModeStatusReporting, OSStreams, 

```bash
mac="30:c5:99:3f:a7:e7"
ip_addr="10.11.12.76"
cidr="24"
host_name="clg-lab-worker-6"
boot_dev="/dev/disk/by-path/pci-0004:01:00.0-nvme-1"
role="worker"

WORK_DIR=${OPENSHIFT_LAB_PATH}/${CLUSTER_NAME}.${DOMAIN}/gx10
rm -rf ${WORK_DIR}
mkdir -p ${WORK_DIR}/ipxe-work-dir/ignition
mkdir ${WORK_DIR}/dns-work-dir
mkdir ${WORK_DIR}/boot-artifacts

oc extract -n openshift-machine-api secret/worker-user-data --keys=userData --to=- > ${WORK_DIR}/ipxe-work-dir/worker.ign

cat << EOF > ${WORK_DIR}/ipxe-work-dir/${mac//:/-}-config.yml
variant: ${BUTANE_VARIANT}
version: ${BUTANE_SPEC_VERSION}
ignition:
  config:
    merge:
      - local: ${role}.ign
EOF
cat << EOF >> ${WORK_DIR}/ipxe-work-dir/${mac//:/-}-config.yml
storage:
  files:
    - path: /etc/zincati/config.d/90-disable-feature.toml
      mode: 0644
      contents:
        inline: |
          [updates]
          enabled = false
    - path: /etc/systemd/network/25-nic0.link
      mode: 0644
      contents:
        inline: |
          [Match]
          MACAddress=${mac}
          [Link]
          Name=nic0
    - path: /etc/NetworkManager/system-connections/nic0.nmconnection
      mode: 0600
      overwrite: true
      contents:
        inline: |
          [connection]
          type=ethernet
          interface-name=nic0

          [ethernet]
          mac-address=${mac}

          [ipv4]
          method=manual
          addresses=${ip_addr}/${cidr}
          gateway=${DOMAIN_ROUTER}
          dns=${DOMAIN_ROUTER}
          dns-search=${DOMAIN}

          [ipv6]
          method=disabled
    - path: /etc/hostname
      mode: 0420
      overwrite: true
      contents:
        inline: |
          ${host_name}
    - path: /etc/chrony.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          pool ${INSTALL_HOST_IP} iburst 
          driftfile /var/lib/chrony/drift
          makestep 1.0 3
          rtcsync
          logdir /var/log/chrony
kernel_arguments:
  should_exist:
    - logo.nologo
    - console=tty0
EOF

cat ${WORK_DIR}/ipxe-work-dir/${mac//:/-}-config.yml | butane -d ${WORK_DIR}/ipxe-work-dir/ -o ${WORK_DIR}/ipxe-work-dir/ignition/${mac//:/-}.ign

echo "${host_name}.${DOMAIN}.   IN      A      ${ip_addr} ; ${host_name}-${DOMAIN}-wk" >> ${WORK_DIR}/dns-work-dir/forward.zone
o4=$(echo ${ip_addr} | cut -d"." -f4)
echo "${o4}    IN      PTR     ${host_name}.${DOMAIN}. ; ${host_name}-${DOMAIN}-wk" >> ${WORK_DIR}/dns-work-dir/reverse.zone

cat << EOF > ${WORK_DIR}/ipxe-work-dir/${mac//:/-}.ipxe
#!ipxe

kernel http://${INSTALL_HOST_IP}/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/gx10/vmlinuz logo.nologo edd=off net.ifnames=1 ifname=nic0:${mac} ip=${ip_addr}::${DOMAIN_ROUTER}:${DOMAIN_NETMASK}:${host_name}.${DOMAIN}:nic0:none nameserver=${DOMAIN_ROUTER} rd.neednet=1 coreos.inst.install_dev=${boot_dev} coreos.inst.ignition_url=http://${INSTALL_HOST_IP}/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/${mac//:/-}.ign coreos.inst.platform_id=metal initrd=initrd initrd=rootfs.img console=tty0
initrd http://${INSTALL_HOST_IP}/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/gx10/initrd
initrd http://${INSTALL_HOST_IP}/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/gx10/rootfs.img

boot
EOF

scp -r ${WORK_DIR}/ipxe-work-dir/ignition/*.ign root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/
ssh root@${INSTALL_HOST_IP} "chmod 644 /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/*"
scp -r ${WORK_DIR}/ipxe-work-dir/*.ipxe root@${DOMAIN_ROUTER}:/usr/local/tftpboot/ipxe/

cat ${WORK_DIR}/dns-work-dir/forward.zone | ssh root@${DOMAIN_ROUTER} "cat >> /usr/local/bind/db.${DOMAIN}"
cat ${WORK_DIR}/dns-work-dir/reverse.zone | ssh root@${DOMAIN_ROUTER} "cat >> /usr/local/bind/db.${DOMAIN_ARPA}"
ssh root@${DOMAIN_ROUTER} "/etc/init.d/named stop && sleep 2 && /etc/init.d/named start && sleep 2"

for i in kernel initramfs rootfs
do
  URL=$(oc -n openshift-machine-config-operator get configmap/coreos-bootimages -o jsonpath='{.data.streams}' | jq -r ".\"rhel-10\".architectures.aarch64.artifacts.metal.formats.pxe.${i}.location")
  curl -o ${WORK_DIR}/boot-artifacts/${i} ${URL}
done

coreos-installer pxe customize --dest-karg-append "logo.nologo" --output initramfs.new initramfs

ssh root@${INSTALL_HOST_IP} "mkdir -p /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/gx10"
scp ${WORK_DIR}/boot-artifacts/initramfs root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/gx10/initrd
scp ${WORK_DIR}/boot-artifacts/kernel root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/gx10/vmlinuz
scp ${WORK_DIR}/boot-artifacts/rootfs root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/gx10/rootfs.img
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