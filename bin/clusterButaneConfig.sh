function createButaneConfig() {
    
  local ip_addr=${1}
  local host_name=${2}
  local mac=${3}
  local role=${4}
  local platform=${5}
  local config_ceph=${6}
  local boot_dev=${7}
  local mc_version="$(${OC} version --client -o yaml | yq e ".releaseClientVersion" | cut -d"-" -f1 | cut -d"." -f "-2" ).0"

  writeButaneHeader ${mac} ${role}
  writeButaneFiles ${ip_addr} ${host_name} ${mac} ${role}
  if [[ ${config_ceph} == "true" ]]
  then
    writeButaneCeph ${mac} ${boot_dev}
  fi
  if [[ ${platform} == "metal" ]]
  then
    writeButaneMetal ${mac}
  fi
  cat ${WORK_DIR}/ipxe-work-dir/${mac//:/-}-config.yml | butane -d ${WORK_DIR}/ipxe-work-dir/ -o ${WORK_DIR}/ipxe-work-dir/ignition/${mac//:/-}.ign
}

function writeButaneHeader() {

  local mac=${1}
  local role=${2}

cat << EOF > ${WORK_DIR}/ipxe-work-dir/${mac//:/-}-config.yml
variant: ${BUTANE_VARIANT}
version: ${BUTANE_SPEC_VERSION}
ignition:
  config:
    merge:
      - local: ${role}.ign
EOF
}

function writeButaneFiles() {

  local ip_addr=${1}
  local host_name=${2}
  local mac=${3}
  local cidr=$(mask2cidr ${DOMAIN_NETMASK})

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
EOF
}

function writeButaneCeph() {

local mac=${1}
local boot_dev=${2}

cat << EOF >> ${WORK_DIR}/ipxe-work-dir/${mac//:/-}-config.yml
  disks:
    - device: ${boot_dev}
      wipe_table: false
      partitions:
        - label: root
          number: 4
          size_mib: 102400
          resize: true
        - number: 5
          size_mib: 0
EOF
}

function writeButaneMetal() {

local mac=${1}

cat << EOF >> ${WORK_DIR}/ipxe-work-dir/${mac//:/-}-config.yml
kernel_arguments:
  should_exist:
    - mitigations=auto
  should_not_exist:
    - mitigations=auto,nosmt
    - mitigations=off
EOF
}

function createClusterCustomMC() {

local mc_version="$(${OC} version --client -o yaml | yq e ".releaseClientVersion" | cut -d"-" -f1 | cut -d"." -f "-2" ).0"

cat << EOF | butane > ${WORK_DIR}/98-cluster-config.yaml
variant: openshift
version: ${mc_version}
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 98-cluster-config
storage:
  files:
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
EOF
cp ${WORK_DIR}/98-cluster-config.yaml ${WORK_DIR}/okd-install-dir/openshift/98-cluster-config.yaml
}

function createClusterCephMC() {

local mc_version="$(${OC} version --client -o yaml | yq e ".releaseClientVersion" | cut -d"-" -f1 | cut -d"." -f "-2" ).0"
local boot_dev=$(yq e ".control-plane.boot-dev" ${CLUSTER_CONFIG})

cat << EOF | butane > ${WORK_DIR}/98-cluster-config.yaml
variant: openshift
version: ${mc_version}
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 98-cluster-ceph-config
storage:
  disks:
  - device: ${boot_dev} 
    partitions:
    - label: ceph
      start_mib: 102400 
      size_mib: 0
EOF
cp ${WORK_DIR}/98-cluster-ceph-config.yaml ${WORK_DIR}/okd-install-dir/openshift/98-cluster-ceph-config.yaml
}

function createHostPathMC() {

  local hostpath_dev=$(yq e ".control-plane.hostpath-dev" ${CLUSTER_CONFIG})
  local systemd_svc_name=$(echo ${hostpath_dev//\//-} | cut -d"-" -f2-)
  local mc_version="$(${OC} version --client -o yaml | yq e ".releaseClientVersion" | cut -d"-" -f1 | cut -d"." -f "-2" ).0"

cat << EOF | butane > ${WORK_DIR}/98-hostpath-config.yaml
variant: openshift
version: ${mc_version}
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 98-hostpath-config
systemd:
  units:
  - contents: |
      [Unit]
      Description=Make File System on ${hostpath_dev}
      DefaultDependencies=no
      BindsTo=${systemd_svc_name}.device
      After=${systemd_svc_name}.device var.mount
      Before=systemd-fsck@${systemd_svc_name}.service

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/lib/systemd/systemd-makefs ext4 ${hostpath_dev}
      TimeoutSec=0

      [Install]
      WantedBy=hostpath.mount
    enabled: true
    name: systemd-mkfs@${systemd_svc_name}.service
  - contents: |
      [Unit]
      Description=Mount ${hostpath_dev} to /var/hostpath
      Before=local-fs.target
      Requires=systemd-mkfs@${systemd_svc_name}.service
      After=systemd-mkfs@${systemd_svc_name}.service

      [Mount]
      What=${hostpath_dev}
      Where=/var/hostpath
      Type=ext4
      Options=defaults

      [Install]
      WantedBy=local-fs.target
    enabled: true
    name: var-hostpath.mount
EOF
cp ${WORK_DIR}/98-hostpath-config.yaml ${WORK_DIR}/okd-install-dir/openshift/98-hostpath-config.yaml
}
