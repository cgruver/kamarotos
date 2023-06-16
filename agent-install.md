# Notes for Agent Based Install

```bash
cat << EOF > ./install/install-config.yaml
apiVersion: v1
baseDomain: my.awesome.lab
metadata:
  name: okd4-bm
networking:
  networkType: OVNKubernetes
  clusterNetwork:
  - cidr: 10.88.0.0/14
    hostPrefix: 23 
  serviceNetwork: 
  - 172.20.0.0/16
  machineNetwork:
  - cidr: 10.11.12.0/24
compute:
- name: worker
  replicas: 0
controlPlane:
  name: master
  architecture: amd64
  hyperthreading: Enabled
  replicas: 3
platform:
  baremetal:
    apiVIPs:
    - 10.11.12.2
    ingressVIPs:
    - 10.11.12.3
pullSecret: '{"auths": {"fake": {"auth": "Zm9vOmJhcgo="}}}'
sshKey: ${SSH_KEY}
EOF

cat << EOF > ./install/agent-config.yaml
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: okd4-bm
rendezvousIP: 10.11.12.60
EOF

openshift-install --dir ./install agent create image

cat << EOF > ${WORK_DIR}/create-cluster-boot-files.sh
coreos-installer iso extract pxe agent.x86_64.iso
coreos-installer pxe customize --live-ignition <(coreos-installer iso ignition show agent.x86_64.iso) -o agent.initrd.img agent.x86_64-initrd.img
EOF

COREOS_INSTALLER_IMAGE=quay.io/coreos/coreos-installer
COREOS_INSTALLER_VER=v0.17.0

podman run --rm -v ${WORK_DIR}:/data -w /data --entrypoint /data/create-cluster-boot-files.sh ${COREOS_INSTALLER_IMAGE}:${COREOS_INSTALLER_VER}

cat << EOF > ${WORK_DIR}/ipxe-work-dir/${mac//:/-}.ipxe
#!ipxe

kernel http://${INSTALL_HOST_IP}/install/fcos/agent-boot/${CLUSTER_NAME}.${DOMAIN}/${mac//:/-}.vmlinuz edd=off net.ifnames=1 ifname=nic0:${mac} ip=${ip_addr}::${DOMAIN_ROUTER}:${DOMAIN_NETMASK}:${hostname}.${DOMAIN}:nic0:none nameserver=${DOMAIN_ROUTER} rd.neednet=1 ignition.firstboot ignition.platform.id=${platform} initrd=initrd coreos.live.rootfs_url=http://${INSTALL_HOST_IP}/install/fcos/agent-boot/${CLUSTER_NAME}.${DOMAIN}/${mac//:/-}.img ${CONSOLE_OPT}
initrd http://${INSTALL_HOST_IP}/install/fcos/agent-boot/${CLUSTER_NAME}.${DOMAIN}/${mac//:/-}.initrd

boot
EOF

```
