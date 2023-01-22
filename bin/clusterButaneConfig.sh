function createButaneConfig() {
    
  local ip_addr=${1}
  local host_name=${2}
  local mac=${3}
  local role=${4}
  local platform=${5}
  local config_ceph=${6}
  local boot_dev=${7}

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
  local role=${4}

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
          addresses=${ip_addr}/${DOMAIN_NETMASK}
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
          pool ${BASTION_HOST} iburst 
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
variant: ${BUTANE_VARIANT}
version: ${BUTANE_SPEC_VERSION}
ignition:
  config:
    merge:
      - local: ${mac//:/-}.ign
storage:
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