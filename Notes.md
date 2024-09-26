# Notes

## Configure Edge Router for PXE

```bash
WORK_DIR=$(mktemp -d)
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedAlgorithms=+ssh-rsa"
SCP="scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedAlgorithms=+ssh-rsa"

cat << EOF > ${WORK_DIR}/boot.ipxe
#!ipxe
   
echo ========================================================
echo UUID: \${uuid}
echo Manufacturer: \${manufacturer}
echo Product name: \${product}
echo Hostname: \${hostname}
echo
echo MAC address: \${net0/mac}
echo IP address: \${net0/ip}
echo IPv6 address: \${net0.ndp.0/ip6:ipv6}
echo Netmask: \${net0/netmask}
echo
echo Gateway: \${gateway}
echo DNS: \${dns}
echo IPv6 DNS: \${dns6}
echo Domain: \${domain}
echo ========================================================
   
chain --replace --autofree ipxe/\${mac:hexhyp}.ipxe
EOF

cat << EOF > ${WORK_DIR}/uci.batch
set dhcp.lan.leasetime="5m"
set dhcp.@dnsmasq[0].enable_tftp=1
set dhcp.@dnsmasq[0].tftp_root=/data/tftpboot
set dhcp.efi64_boot_1=match
set dhcp.efi64_boot_1.networkid='set:efi64'
set dhcp.efi64_boot_1.match='60,PXEClient:Arch:00007'
set dhcp.efi64_boot_2=match
set dhcp.efi64_boot_2.networkid='set:efi64'
set dhcp.efi64_boot_2.match='60,PXEClient:Arch:00009'
set dhcp.ipxe_boot=userclass
set dhcp.ipxe_boot.networkid='set:ipxe'
set dhcp.ipxe_boot.userclass='iPXE'
set dhcp.uefi=boot
set dhcp.uefi.filename='tag:efi64,tag:!ipxe,ipxe.efi'
set dhcp.uefi.serveraddress="${EDGE_ROUTER}"
set dhcp.uefi.servername='pxe'
set dhcp.uefi.force='1'
set dhcp.ipxe=boot
set dhcp.ipxe.filename='tag:ipxe,boot.ipxe'
set dhcp.ipxe.serveraddress="${EDGE_ROUTER}"
set dhcp.ipxe.servername='pxe'
set dhcp.ipxe.force='1'
del_list uhttpd.main.listen_http="[::]:80"
del_list uhttpd.main.listen_http="0.0.0.0:80"
del_list uhttpd.main.listen_https="[::]:443"
del_list uhttpd.main.listen_https="0.0.0.0:443"
add_list uhttpd.main.listen_http="${EDGE_ROUTER}:80"
add_list uhttpd.main.listen_https="${EDGE_ROUTER}:443"
add_list uhttpd.main.listen_http="127.0.0.1:80"
add_list uhttpd.main.listen_https="127.0.0.1:443"
commit
EOF

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedAlgorithms=+ssh-rsa root@${EDGE_ROUTER} "opkg update && opkg install bash shadow uhttpd ; \
  /etc/init.d/lighttpd disable ; \
  /etc/init.d/lighttpd stop ; \
  /etc/init.d/uhttpd enable ; \
  mkdir -p /data/tftpboot/ipxe ; \
  mkdir /data/tftpboot/networkboot"

scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedAlgorithms=+ssh-rsa ${OPENSHIFT_LAB_PATH}/boot-files/ipxe.efi root@${EDGE_ROUTER}:/data/tftpboot/ipxe.efi
scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedAlgorithms=+ssh-rsa ${OPENSHIFT_LAB_PATH}/boot-files/vmlinuz root@${EDGE_ROUTER}:/data/tftpboot/networkboot/vmlinuz
scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedAlgorithms=+ssh-rsa ${OPENSHIFT_LAB_PATH}/boot-files/initrd.img root@${EDGE_ROUTER}:/data/tftpboot/networkboot/initrd.img
scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedAlgorithms=+ssh-rsa ${WORK_DIR}/boot.ipxe root@${EDGE_ROUTER}:/data/tftpboot/boot.ipxe
scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedAlgorithms=+ssh-rsa ${WORK_DIR}/uci.batch root@${EDGE_ROUTER}:/tmp/uci.batch
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedAlgorithms=+ssh-rsa root@${EDGE_ROUTER} "cat /tmp/uci.batch | uci batch ; reboot"
```

```bash
cat << EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    telemeterClient:
      enabled: false
EOF
```

```bash
git clone https://github.com/qnap-dev/QNAP-CSI-PlugIn.git 

cd QNAP-CSI-PlugIn
oc apply -f Deploy/Trident/namespace.yaml 
oc apply -f Deploy/crds/tridentorchestrator_crd.yaml 
oc apply -f Deploy/Trident/bundle.yaml 
oc apply -f Deploy/Trident/tridentorchestrator.yaml 
```

```bash
cat << EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: nas-01-iscsi-secret
  namespace: trident
type: Opaque
stringData:
  username: ${ISCSI_USER}
  password: ${ISCSI_PWD}
  storageAddress: ${ISCSI_IP}
---
apiVersion: trident.qnap.io/v1
kind: TridentBackendConfig
metadata:
  name: nas-01-iscsi
  namespace: trident
spec:
  version: 1
  storageDriverName: qnap-iscsi
  backendName: nas-01-iscsi
  networkInterfaces: []
  credentials:
    name: nas-01-iscsi-secret
  debugTraceFlags:
    method: false
  storage:
    - labels:
        storage: nas-01-iscsi
        serviceLevel: Any
EOF
```

```bash
cat << EOF | oc apply -f -
apiVersion: storage.k8s.io/v1 
kind: StorageClass 
metadata: 
  name: nas-01-iscsi 
provisioner: csi.trident.qnap.io
parameters: 
  selector: "storage=nas-01-iscsi" 
allowVolumeExpansion: true
EOF
```

```bash
cat << EOF | oc apply -f -
kind: PersistentVolumeClaim  
apiVersion: v1  
metadata:  
  name: pvc-nas-test
  namespace: trident
  annotations:  
    trident.qnap.io/ThinAllocate: "true"  
spec:  
  accessModes:  
    - ReadWriteOnce  
  resources:  
    requests:  
      storage: 5Gi  
  storageClassName: nas-01-iscsi 
EOF
```

## Install Nexus on Dev Tools Host

```bash
dnf install -y java-17-openjdk.x86_64
mkdir -p /usr/local/nexus/home
cd /usr/local/nexus
wget https://download.sonatype.com/nexus/3/latest-unix.tar.gz -O latest-unix.tar.gz
groupadd nexus
useradd -g nexus -d /usr/local/nexus/home nexus
chown -R nexus:nexus /usr/local/nexus
keytool -genkeypair -keystore /usr/local/nexus/nexus-3/etc/ssl/keystore.jks -deststoretype pkcs12 -storepass password -keypass password -alias jetty -keyalg RSA -keysize 4096 -validity 5000 -dname "CN=nexus.clg.lab, OU=clg-lab, O=clg-lab, L=City, ST=State, C=US" -ext "SAN=DNS:nexus.clg.lab,IP:10.11.12.20" -ext "BC=ca:true"

cat /usr/local/nexus/sonatype-work/nexus3/admin.password
```

## Trust Nexus in OCP

```bash
NEXUS_CERT=$(openssl s_client -showcerts -connect nexus.${LAB_DOMAIN}:8443 </dev/null 2>/dev/null|openssl x509 -outform PEM | while read line; do echo "    $line"; done)
```

```bash
cat << EOF | oc apply -n openshift-config -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: lab-ca
data:
  ca-bundle.crt: |
    # Nexus Cert
${NEXUS_CERT}

EOF
```

```bash
oc patch proxy cluster --type=merge --patch '{"spec":{"trustedCA":{"name":"lab-ca"}}}'
```

```bash
NEXUS_CERT=$(openssl s_client -showcerts -connect nexus.${LAB_DOMAIN}:8443 </dev/null 2>/dev/null|openssl x509 -outform PEM | base64)
```

```bash
cat << EOF | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 50-developer-ca-certs-worker
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,${GITEA_CERT}
        filesystem: root
        mode: 0644
        path: /etc/pki/ca-trust/source/anchors/gitea-ca.crt
      - contents:
          source: data:text/plain;charset=utf-8;base64,${NEXUS_CERT}
        filesystem: root
        mode: 0644
        path: /etc/pki/ca-trust/source/anchors/nexus-ca.crt
EOF
```

```bash
cat << EOF | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 50-developer-ca-certs-master
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,${GITEA_CERT}
        filesystem: root
        mode: 0644
        path: /etc/pki/ca-trust/source/anchors/gitea-ca.crt
      - contents:
          source: data:text/plain;charset=utf-8;base64,${NEXUS_CERT}
        filesystem: root
        mode: 0644
        path: /etc/pki/ca-trust/source/anchors/nexus-ca.crt
EOF
```
