# kamarótos - καμαρότος

Greek for Ship's steward or cabin boy...

In the spirit of nautical names for Kubernetes related projects, this is where I am maintaining my home lab helper scripts.

## [OKD Home Lab](https://upstreamwithoutapaddle.com/home-lab/lab-intro/)

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

1. Clone the utiliy code repo:

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
   export LAB_CONFIG_FILE=${HOME}/okd-lab/lab-config/lab.yaml
   . ${HOME}/okd-lab/bin/labEnv.sh
   ```

1. Log off and back on to set the variables.

## Example Configuration Files

The `examples` directory in this project contains a sample `lab.yaml` file.  This file is the main configuration file for your lab.  It contains references to "sub domains" that contain the configuration for a specific OpenShift cluster.

The OpenShift cluster configuration files are in `examples/domain-configs`

These files correspond to the following cluster configurations:

| Domain Config File | Description |
| --- | --- |
| `kvm-cluster-basic.yaml` | 3 Node cluster with control-plane & worker combined nodes, deployed on a single KVM host. |
| `kvm-cluster-3-worker.yaml` | 6 Node cluster, 3 control-plane & 3 worker nodes, deployed on 2 KVM hosts. |
| `sno-kvm.yaml` | Single Node Cluster, deployed on a KVM host. |
| `sno-bm.yaml` | Single Node Cluster, deployed on a bare metal server |
| `bare-metal-basic.yaml` | 3 Node cluster with control-plane & worker combined nodes, deployed on 3 bare metal servers |
| `bare-metal-3-worker.yaml` | 6 Node cluster, 3 control-plane & 3 worker nodes, deployed on 6 bare metal servers |
