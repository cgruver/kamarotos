# kamarótos - καμαρότος

Greek for Ship's steward or cabin boy...

In the spirit of nautical names for Kubernetes related projects, this is where I am maintaining my home lab helper scripts.

## [OpenShift - (OKD) Home Lab](https://upstreamwithoutapaddle.com/home-lab/lab-intro/)

This project contains a set of cli utilities for my OpenShift Home Lab:

Documentation is here: [`labcli`](https://upstreamwithoutapaddle.com/home-lab/labcli/)

Instructions for building a home lab are here: [Building a Portable Kubernetes Home Lab with OpenShift - OKD4](/home-lab/lab-intro/)

Follow my Blog for other home lab projects: [https://upstreamwithoutapaddle.com](https://upstreamwithoutapaddle.com)

__Note:__ These utilities are very opinionated toward the equipment that I run in my lab.  See the equipment list here: [Lab Equipment](https://upstreamwithoutapaddle.com/home-lab/equipment/)

## Install the Utilities

1. Prepare your lab working directory:

   ```bash
   mkdir ${HOME}/okd-lab
   ```

1. Install the `yq` command for YAML file manipulation.  My lab utilities are dependent on it:

   ```bash
   brew install yq
   ```

1. Clone the utility code repo:

   ```bash
   git clone https://github.com/cgruver/kamarotos.git ${HOME}/okd-lab/kamarotos
   ```

1. Install the utility scripts:

   ```bash
   cp ${HOME}/okd-lab/kamarotos/bin/* ${HOME}/okd-lab/bin
   chmod 700 ${HOME}/okd-lab/bin/*
   ```

1. Edit your shell `rc` (`.bashrc` or `.zshrc`) file to enable the utilities in the path, and load that lab functions into the shell:

   ```bash
   . ${HOME}/okd-lab/bin/labEnv.sh
   ```

1. Log off and back on to set the variables.

## Example Configuration Files

The `examples` directory in this project contains a sample `lab.yaml` file.  This file is the main configuration file for your lab.  It contains references to "sub domains" that contain the configuration for a specific OpenShift cluster.

The OpenShift cluster configuration files are in `examples/cluster-configs`

These files correspond to the following cluster configurations:

| Domain Config File | Description |
| --- | --- |
| `kvm-cluster-basic.yaml` | 3 Node cluster with control-plane & worker combined nodes, deployed on a single KVM host. |
| `kvm-cluster-3-worker.yaml` | 6 Node cluster, 3 control-plane & 3 worker nodes, deployed on 2 KVM hosts. |
| `sno-kvm.yaml` | Single Node Cluster, deployed on a KVM host. |
| `sno-bm.yaml` | Single Node Cluster, deployed on a bare metal server |
| `bare-metal-basic.yaml` | 3 Node cluster with control-plane & worker combined nodes, deployed on 3 bare metal servers |
| `bare-metal-3-worker.yaml` | 6 Node cluster, 3 control-plane & 3 worker nodes, deployed on 6 bare metal servers |

## Config Files Reference:

There are two YAML configuration files that are used by the `labcli` utilities for deploying the infrastructure for you home lab:

The first configuration file defines the networks for your lab, as well as any KVM Hosts that are deployed on the edge LAN network.

```yaml
# Edge LAN Configuration
domain: my.awesome.lab
network: 10.11.12.0
router-ip: 10.11.12.1
bastion-ip: 10.11.12.10 # Omit if no Raspberry Pi
netmask: 255.255.255.0
# CentOS Stream Mirror to pull from
centos-mirror: rsync://mirror.cogentco.com/CentOS/
# Gitea release to install on Bastion Host
gitea-version: 1.15.9 # Omit if no Raspberry Pi
# URL of your git server
git-url: https://gitea.my.awesome.lab:3000 # Omit if no Raspberry Pi
# OpenWRT version to install on the Raspberry Pi Bastion Host
openwrt-version: 21.02.1 # Omit if no Raspberry Pi
# Cluster Configurations
cluster-configs:
- name: okd-dev
  cluster-config-file: dev-cluster.yaml
  domain: dev
- name: okd-qa
  cluster-config-file: qa-cluster.yaml
  domain: qa
- name: okd-prod
  cluster-config-file: prod-cluster.yaml
  domain: prod
# Region Network Configurations
sub-domain-configs:
  # Domain Name, this is prepended to the lab domain. i.e. dev.my.awesome.lab
- name: dev
  # edge network ip address of the domain router
  router-edge-ip: 10.11.12.2
  # internal ip address of the domain router
  router-ip: 10.11.13.1
  # domain network
  network: 10.11.13.0
  # domain netmask
  netmask: 255.255.255.0
  # Name of the OpenShift cluster config file.  These files are in ${OKD_LAB_PATH}/lab-config/domain-configs
- name: qa
  router-edge-ip: 10.11.12.3
  router-ip: 10.11.14.1
  network: 10.11.14.0
  netmask: 255.255.255.0
- name: prod
  router-edge-ip: 10.11.12.4
  router-ip: 10.11.15.1
  network: 10.11.15.0
  netmask: 255.255.255.0
  cluster-config-file: prod-cluster.yaml
# KVM Hosts provisioned on the Edge LAN network
kvm-hosts:
  # hostname to assign to the physical host
- host-name: kvm-host01
  # MAC Address of the NIC that will be used for network booting and configured as the primary NIC on the host
  mac-addr: 1c:69:7a:6f:ab:12
  # IP address to be assigned to the primary NIC
  ip-addr: 10.11.12.200
  # List of up to two disk devices that will be combined into a single volume group for CentOS Stream installation
  disks:
    disk1: nvme0n1
    disk2: NA
- host-name: kvm-host02
  mac-addr: 1c:69:7a:6f:cd:34
  ip-addr: 10.11.12.201
  disks:
    disk1: nvme0n1
    disk2: nvme0n2
```

The second YAML file defines the infrastructure for provisioning an OpenShift Cluster:

```yaml
# Cluster Configuration
cluster:
  # Name of the cluster
  name: okd4
  # CIDR Info for the Cluster
  cluster-cidr: 10.100.0.0/14
  service-cidr: 172.30.0.0/16
  # URL to the registry used to mirror the OpenShift install images
  local-registry: nexus.my.awesome.lab:5001 # Omit if no Raspberry Pi
  # URL to the Nexus group used to proxy remote registries
  proxy-registry: nexus.my.awesome.lab:5000 # Omit if no Raspberry Pi
  # The URL to the registry hosting the OpenShift install images
  remote-registry: quay.io/openshift/okd
  # The version of butane used to configure ignition files for the FCOS nodes
  butane-version: v0.14.0
  # The version of the Butane specification to use for the ignition files
  butane-spec-version: 1.4.0
  # The OpenShift release to install - This entry is created by running: labcli --latest or labcli --latest --scos 
  release: 4.10.0-0.okd-2022-03-07-131213
  # The HA Proxy IP address to assign on the router
  ingress-ip-addr: 10.11.12.2
# KVM Hosts provisioned in the region
kvm-hosts:
    # The hostname to assign to the KVM host
  - host-name: kvm-host01
    # The MAC Address of the machine
    mac-addr: 1c:69:7a:6f:ef:56
    # The IP Address to assign to the KVM host
    ip-addr: 10.11.12.200
    # The physical discs installed on the machine
    disks:
      disk1: nvme0n1
      disk2: NA
  - host-name: kvm-host02
    mac-addr: 1c:69:7a:6f:ba:21
    ip-addr: 10.11.12.201
    disks:
      disk1: nvme0n1
      disk2: NA
# Bootstrap Node configuration for KVM install
bootstrap:
  # If true, install the bootstrap node with Qemu on the local workstation.  If false, install the bootstrap node as a KVM guest
  metal: false
  # KVM host for provisioning the bootstrap guest VM, not needed if metal=true
  kvm-host: kvm-host01
  # The MAC address to assign to the bootstrap node if metal=true, auto-populated if metal=false
  mac-addr: "52:54:00:a1:b2:c3"
  # The IP address to assign to the bootstrap node
  ip-addr: 10.11.12.49
  # The boot device to use if metal=true, not needed if metal=false
  boot-dev: /dev/sda
  # The network bridge device to use if metal=true, not needed if metal=false
  bridge-dev: en6
  # The hostname assigned to the bootstrap node.  Auto-populated by the labcli install utilities.
  name: okd4-bootstrap
  # The specifications to use for the bootstrap node guest VM
  node-spec:
    # RAM in MB
    memory: 12288
    # vCPUs
    cpu: 4
    # Disk size in GB
    root_vol: 50
# Master Node configuration for bare metal install
control-plane:
  metal: true
  node-spec:
    memory: 20480
    cpu: 6
    root_vol: 100
  okd-hosts:
  - name: "okd4-master-0"
    mac-addr: "1c:69:11:22:33:44"
    boot-dev: /dev/sda
    ip-addr: 10.11.12.60
  - name: "okd4-master-1"
    mac-addr: "1c:69:ab:cd:12:34"
    boot-dev: /dev/sda
    ip-addr: 10.11.12.61
  - name: "okd4-master-2"
    mac-addr: "1c:69:fe:dc:ba:21"
    boot-dev: /dev/sda
    ip-addr: 10.11.12.62
# Worker Node configuration for KVM install
compute-nodes:
- metal: false
  name: "okd4-worker-0"
  kvm-host: kvm-host02
  ip-addr: 10.11.12.70
  node-spec:
    memory: 20480
    cpu: 4
    root_vol: 50
  ceph:
    ceph-dev: /dev/sdb
    ceph-vol: 200
    type: disk
- metal: false
  name: "okd4-worker-1"
  kvm-host: kvm-host02
  ip-addr: 10.11.12.71
  node-spec:
    memory: 20480
    cpu: 4
    root_vol: 50
  ceph:
    ceph-dev: /dev/sdb
    ceph-vol: 200
    type: disk
- metal: false
  name: "okd4-worker-2"
  kvm-host: kvm-host02
  ip-addr: 10.11.12.72
  node-spec:
    memory: 20480
    cpu: 4
    root_vol: 50
  ceph:
    ceph-dev: /dev/sdb
    ceph-vol: 200
    type: disk
# Worker Node configuration for bare metal install
compute-nodes:
- metal: true
  name: "okd4-worker-0"
  mac-addr: "1c:69:ab:cd:12:34"
  boot-dev: /dev/sda
  ip-addr: 10.11.12.70
  ceph:
    ceph-dev: /dev/sdb
    type: disk
- metal: true
  name: "okd4-worker-1"
  mac-addr: "1c:69:11:22:33:44"
  boot-dev: /dev/sda
  ip-addr: 10.11.12.71
  ceph:
    ceph-dev: /dev/sdb
    type: disk
- metal: true
  name: "okd4-worker-2"
  mac-addr: "1c:69:fe:dc:ba:21"
  boot-dev: /dev/sda
  ip-addr: 10.11.12.72
  ceph:
    ceph-dev: /dev/sdb
    type: disk
```
