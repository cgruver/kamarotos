# kamarótos - καμαρότος

## Note: Major update to simplify and refresh (A lot of the previously supported hardware is EOL)

I am simplifying this project to be very opinionated to bare metal OCP installs with specific hardware configurations.

Look for a new blog post soon.

## Original Content - 

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
