

```bash
oc adm upgrade --to-multi-arch
oc patch FeatureGate cluster --type merge --patch '{"spec":{"featureSet":"CustomNoUpgrade","customNoUpgrade":{"enabled":["OSStreams"]}}}'
oc patch mcp worker --type merge -p '{"spec":{"osImageStream":{"name":"rhel-10"}}}'
oc patch mcp master --type merge -p '{"spec":{"osImageStream":{"name":"rhel-10"}}}'
```

## Fix QNAP Trident on RHEL 10.2 CoreOS

```bash
cat << EOF | butane | oc apply -f -
variant: openshift
version: 4.22.0
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: enable-multipath
storage:
  files:
  - path: /etc/multipath.conf
    mode: 0644
    overwrite: true
    contents:
      inline: |
        defaults {
          user_friendly_names yes
          find_multipaths no
        }
EOF
```

```bash
cat << EOF | butane | oc apply -f -
variant: openshift
version: 4.22.0
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: enable-multipath-worker
storage:
  files:
  - path: /etc/multipath.conf
    mode: 0644
    overwrite: true
    contents:
      inline: |
        defaults {
          user_friendly_names yes
          find_multipaths no
        }
EOF
```

```bash
mac="30:c5:99:3f:a7:e7"
ip_addr="10.11.12.63"
cidr="24"
host_name="clg-lab-gx10"
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

# coreos-installer pxe customize --dest-karg-append "logo.nologo" --output initramfs.new initramfs

ssh root@${INSTALL_HOST_IP} "mkdir -p /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/gx10"
scp ${WORK_DIR}/boot-artifacts/initramfs root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/gx10/initrd
scp ${WORK_DIR}/boot-artifacts/kernel root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/gx10/vmlinuz
scp ${WORK_DIR}/boot-artifacts/rootfs root@${INSTALL_HOST_IP}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}.${DOMAIN}/gx10/rootfs.img
```

```yaml
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  enableTaints: false
  instance: ''
  operand:
    imagePullPolicy: IfNotPresent
    servicePort: 12000
  prunerOnDelete: false
  topologyUpdater: false
  workerConfig:
    configData: |
      core:
        sleepInterval: 60s
      sources:
        pci:
          deviceClassWhitelist:
            - "0200"
            - "0300"
            - "03"
            - "12"
          deviceLabelFields:
            - "vendor"
```


## Not Needed

```yaml
apiVersion: nfd.k8s-sigs.io/v1alpha1
kind: NodeFeatureRule
metadata:
  name: nfd-nvidia-gpu-rule
  namespace: openshift-nfd
spec:
  rules:
    - labels:
        feature.node.kubernetes.io/pci-10de.present: 'true'
        feature.node.kubernetes.io/system-os_release.ID: rhel
        feature.node.kubernetes.io/system-os_release.OSTREE_VERSION: 10.2.20260630-0
        feature.node.kubernetes.io/system-os_release.VERSION_ID: '10.2'
      matchFeatures:
        - feature: pci.device
          matchExpressions:
            vendor:
              op: In
              value:
                - 10de
      name: nvidia-gpu-vendor-detection
```
