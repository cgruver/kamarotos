export OPENSHIFT_LAB_PATH=${HOME}/openshift-lab
export PATH=${OPENSHIFT_LAB_PATH}/bin:$PATH
export OC_INIT=${OPENSHIFT_LAB_PATH}/openshift-cmds/init/oc

if [[ -z ${LAB_CONFIG_FILE} ]]
then
  export LAB_CONFIG_FILE=${OPENSHIFT_LAB_PATH}/lab-config/lab.yaml
fi

if [[ -z ${LAB_CONFIG_LIST} ]]
then
  export LAB_CONFIG_LIST=${OPENSHIFT_LAB_PATH}/lab-config/lab-list.yaml
fi

function labenv() {

  for i in "$@"
  do
    case $i in
      -c=*|--cluster=*)
        cluster="${i#*=}"
        labctx ${cluster}
      ;;
    esac
  done

  for i in "$@"
  do
    case $i in
      -e)
        setEdgeEnv
      ;;
      -k)
        if [[ -z ${CLUSTER} ]]
        then
          labctx
        fi
        export KUBECONFIG=${KUBE_INIT_CONFIG}
      ;;
      -c)
        clearLabEnv
      ;;
    esac
  done
  i=""
}

function setLabConfig() {
  
  local config_count=0
  local array_index=0

  DONE=false
  config_count=$(yq e ".lab-configs" ${LAB_CONFIG_LIST} | yq e 'length' -)
  if [[ ${config_count} -eq 0 ]]
  then
    echo "Lab Entries Not Found In Config File."
  else
    let array_index=0
    while [[ array_index -lt ${config_count} ]]
    do
      lab_name=$(yq e ".lab-configs.[${array_index}].name" ${LAB_CONFIG_LIST})
      echo "$(( ${array_index} + 1 )) - ${lab_name}"
      array_index=$(( ${array_index} + 1 ))
    done
    unset array_index
    echo "Enter the index of the lab that you want to work with:"
    read ENTRY
    INDEX=$(( ${ENTRY} - 1 ))
    config_file=$(yq e ".lab-configs.[${INDEX}].config" ${LAB_CONFIG_LIST})
    ln -sf ${OPENSHIFT_LAB_PATH}/lab-config/lab-config-files/${config_file} ${LAB_CONFIG_FILE}
  fi
}

function setClusterIndex() {

  local cluster=${1}
  if [[ -z ${LAB_CONFIG_FILE} ]]
  then
    echo "ENV VAR LAB_CONFIG_FILE must be set to the path to a lab config yaml."
  else
    DONE=false
    CLUSTER_COUNT=$(yq e ".cluster-configs" ${LAB_CONFIG_FILE} | yq e 'length' -)
    if [[ ${CLUSTER_COUNT} -eq 0 ]]
    then
      INDEX=""
      DONE="true"
    elif [[ -z ${cluster} ]]
    then
      let array_index=0
      while [[ array_index -lt ${CLUSTER_COUNT} ]]
      do
        cluster_name=$(yq e ".cluster-configs.[${array_index}].name" ${LAB_CONFIG_FILE})
        echo "$(( ${array_index} + 1 )) - ${cluster_name}"
        array_index=$(( ${array_index} + 1 ))
      done
      unset array_index
      echo "Enter the index of the cluster that you want to work with:"
      read ENTRY
      INDEX=$(( ${ENTRY} - 1 ))
      DONE="true"
    else
      let array_index=0
      while [[ array_index -lt ${CLUSTER_COUNT} ]]
      do
        cluster_name=$(yq e ".cluster-configs.[${array_index}].name" ${LAB_CONFIG_FILE})
        if [[ ${cluster_name} == ${cluster} ]]
        then
          INDEX=${array_index}
          DONE=true
          break
        fi
        array_index=$(( ${array_index} + 1 ))
      done
      unset array_index
    fi
    if [[ ${DONE} == "true" ]]
    then
      export LAB_CTX_ERROR="false"
      CLUSTER_INDEX=${INDEX}
    else
      echo "Cluster Entry Not Found In Config File."
      CLUSTER_INDEX=""
    fi
  fi
}

function setDomainIndex() {

  local sub_domain=${1}
  SUB_DOMAIN=""
  INDEX=""
  export LAB_CTX_ERROR="true"

  DONE=false
  DOMAIN_COUNT=$(yq e ".sub-domain-configs" ${LAB_CONFIG_FILE} | yq e 'length' -)
  let array_index=0
  while [[ array_index -lt ${DOMAIN_COUNT} ]]
  do
    domain_name=$(yq e ".sub-domain-configs.[${array_index}].name" ${LAB_CONFIG_FILE})
    if [[ ${domain_name} == ${sub_domain} ]]
    then
      INDEX=${array_index}
      DONE=true
      break
    fi
    array_index=$(( ${array_index} + 1 ))
  done
  unset array_index
  if [[ ${DONE} == "true" ]]
  then
    export LAB_CTX_ERROR="false"
    DOMAIN_INDEX=${INDEX}
  else
    echo "Domain Entry Not Found In Config File."
    DOMAIN_INDEX=""
  fi
}

function labctx() {

  local cluster=${1}
  SUB_DOMAIN=""
  CLUSTER=""

  for i in "$@"
  do
    case $i in
      -s)
        setLabConfig
        cluster=""
      ;;
    esac
  done

  setClusterIndex ${cluster}

  if [[ ${LAB_CTX_ERROR} == "false" ]]
  then
    setEdgeEnv
    if [[ ${CLUSTER_INDEX} != "" ]]
    then
      setClusterEnv
    fi
    echo "Your shell environment is set up for Cluster: ${CLUSTER_NAME}.${DOMAIN}"
  fi
}

function mask2cidr() {
   local x=${1##*255.}
   set -- 0^^^128^192^224^240^248^252^254^ $(( (${#1} - ${#x})*2 )) ${x%%.*}
   x=${1%%$3*}
   echo $(( $2 + (${#x}/4) ))
}

function setDomainEnv() {

  export SUB_DOMAIN=$(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].name" ${LAB_CONFIG_FILE})
  export DOMAIN="${SUB_DOMAIN}.${LAB_DOMAIN}"
  export DOMAIN_ROUTER=$(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].router-ip" ${LAB_CONFIG_FILE})
  export DOMAIN_ROUTER_EDGE=$(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].router-edge-ip" ${LAB_CONFIG_FILE})
  export DOMAIN_NETWORK=$(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].network" ${LAB_CONFIG_FILE})
  export DOMAIN_NETMASK=$(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].netmask" ${LAB_CONFIG_FILE})
  export DOMAIN_CIDR=$(mask2cidr ${DOMAIN_NETMASK})
  IFS="." read -r i1 i2 i3 i4 <<< "${DOMAIN_NETWORK}"
  export DOMAIN_ARPA=${i3}.${i2}.${i1}
}

function setEdgeCluster() {
  export DOMAIN=${LAB_DOMAIN}
  export SUB_DOMAIN="edge-cluster"
  export DOMAIN_ARPA=${EDGE_ARPA}
  export DOMAIN_ROUTER=${EDGE_ROUTER}
  export DOMAIN_NETMASK=${EDGE_NETMASK}
  export DOMAIN_NETWORK=${EDGE_NETWORK}
}

function setClusterEnv() {

  if [[ $(yq e ".cluster-configs.[${CLUSTER_INDEX}].domain" ${LAB_CONFIG_FILE}) == "edge" ]]
  then
    setEdgeCluster
  else
    setDomainIndex $(yq e ".cluster-configs.[${CLUSTER_INDEX}].domain" ${LAB_CONFIG_FILE})
    setDomainEnv
  fi
  export CLUSTER_CONFIG=${OPENSHIFT_LAB_PATH}/lab-config/cluster-configs/$(yq e ".cluster-configs.[${CLUSTER_INDEX}].cluster-config-file" ${LAB_CONFIG_FILE})
  export CLUSTER=$(yq e ".cluster-configs.[${CLUSTER_INDEX}].name" ${LAB_CONFIG_FILE})
  export CLUSTER_NAME=$(yq e ".cluster.name" ${CLUSTER_CONFIG})
  export KUBE_INIT_CONFIG=${OPENSHIFT_LAB_PATH}/lab-config/kubeconfigs/${CLUSTER_NAME}-${DOMAIN}-kubeconfig
  export CLUSTER_CIDR=$(yq e ".cluster.cluster-cidr" ${CLUSTER_CONFIG})
  export SERVICE_CIDR=$(yq e ".cluster.service-cidr" ${CLUSTER_CONFIG})
  export BUTANE_VARIANT=$(yq e ".cluster.butane-variant" ${CLUSTER_CONFIG})
  export BUTANE_SPEC_VERSION=$(yq e ".cluster.butane-spec-version" ${CLUSTER_CONFIG})
  export OPENSHIFT_REGISTRY=$(yq e ".cluster.remote-registry" ${CLUSTER_CONFIG})
  export PULL_SECRET=${OPENSHIFT_LAB_PATH}/pull-secrets/${CLUSTER_NAME}-pull-secret.json
  export DISCONNECTED_CLUSTER=$(yq e ".cluster.disconnected" ${CLUSTER_CONFIG})
  export INSTALL_METHOD=$(yq e ".cluster.install-method" ${CLUSTER_CONFIG})
  setOpenShiftRelease
  setButaneRelease
  if [[ $(yq e ".bootstrap.metal" ${CLUSTER_CONFIG}) != "true" ]]
  then
    if [[ $(yq ".bootstrap | has(\"kvm-domain\")" ${CLUSTER_CONFIG}) == "true" ]]
    then
      export BOOTSTRAP_KVM_DOMAIN=$(yq e ".bootstrap.kvm-domain" ${CLUSTER_CONFIG})
    else
      export BOOTSTRAP_KVM_DOMAIN=${DOMAIN}
    fi
  fi
}

function setEdgeEnv() {
  if [[ -z ${LAB_CONFIG_FILE} ]]
  then
    echo "ENV VAR LAB_CONFIG_FILE must be set to the path to a lab config yaml."
    export LAB_CTX_ERROR="true"
  else
    export LAB_DOMAIN=$(yq e ".domain" ${LAB_CONFIG_FILE})
    export EDGE_ROUTER=$(yq e ".router-ip" ${LAB_CONFIG_FILE})
    export INSTALL_HOST_IP=${EDGE_ROUTER}
    export INSTALL_HOST=router
    export EDGE_NETMASK=$(yq e ".netmask" ${LAB_CONFIG_FILE})
    export EDGE_NETWORK=$(yq e ".network" ${LAB_CONFIG_FILE})
    export EDGE_CIDR=$(mask2cidr ${EDGE_NETMASK})
    export GIT_SERVER=$(yq e ".git-url" ${LAB_CONFIG_FILE})
    IFS="." read -r i1 i2 i3 i4 <<< "${EDGE_NETWORK}"
    export EDGE_ARPA=${i3}.${i2}.${i1}
    if [[ $(yq ". | has(\"pi-ip\")" ${LAB_CONFIG_FILE}) == "true" ]]
    then
      export PI_IP=$(yq e ".pi-ip" ${LAB_CONFIG_FILE})
      if [[ $(yq e ".install-host" ${LAB_CONFIG_FILE}) == "raspberry-pi" ]]
      then
        export INSTALL_HOST_IP=${PI_IP}
        export INSTALL_HOST=raspberry-pi
      fi
    fi
    if [[ $(yq ". | has(\"local-registry\")" ${LAB_CONFIG_FILE}) == "true" ]]
    then
      export LOCAL_REGISTRY=$(yq e ".local-registry" ${LAB_CONFIG_FILE})
    fi
    if [[ $(yq ". | has(\"proxy-registry\")" ${LAB_CONFIG_FILE}) == "true" ]]
    then
      export PROXY_REGISTRY=$(yq e ".proxy-registry" ${LAB_CONFIG_FILE})
    fi
  fi
}

function fixMacArmCodeSign() {

  if [[ $(uname) == "Darwin" ]] && [[ $(uname -m) == "arm64" ]]
  then
    echo "Applying workaround for corrupt signiture on OpenShift CLI binaries"
    codesign --force -s - ${OPENSHIFT_LAB_PATH}/openshift-cmds/${OPENSHIFT_RELEASE}/oc
    codesign --force -s - ${OPENSHIFT_LAB_PATH}/openshift-cmds/${OPENSHIFT_RELEASE}/openshift-install
  fi
}

function setOpenShiftRelease() {
  
  local release_set=$(yq ".cluster | has(\"release\")" ${CLUSTER_CONFIG})
  if [[ ${release_set} == "true" ]]
  then
    export OPENSHIFT_RELEASE=$(yq e ".cluster.release" ${CLUSTER_CONFIG})
    if [[ ! -f ${OPENSHIFT_LAB_PATH}/openshift-cmds/${OPENSHIFT_RELEASE}/oc ]]
    then
      getCliCmds 
    fi
    for i in $(ls ${OPENSHIFT_LAB_PATH}/openshift-cmds/${OPENSHIFT_RELEASE})
    do
      rm -f ${OPENSHIFT_LAB_PATH}/bin/${i}
      ln -sf ${OPENSHIFT_LAB_PATH}/openshift-cmds/${OPENSHIFT_RELEASE}/${i} ${OPENSHIFT_LAB_PATH}/bin/${i}
    done
    i=""
  fi
}

function setButaneRelease() {

  local release_set=$(yq ".cluster | has(\"butane-version\")" ${CLUSTER_CONFIG})
  if [[ ${release_set} == "true" ]]
  then
    export BUTANE_VERSION=$(yq e ".cluster.butane-version" ${CLUSTER_CONFIG})
    if [[ ! -d ${OPENSHIFT_LAB_PATH}/butane/${BUTANE_VERSION} ]]
    then
      getButane
    fi
    rm ${OPENSHIFT_LAB_PATH}/bin/butane
    ln -sf ${OPENSHIFT_LAB_PATH}/butane/${BUTANE_VERSION}/butane ${OPENSHIFT_LAB_PATH}/bin/butane
  fi
}

function getInitCli() {
  
  OKD_RELEASE=$(basename $(curl -Ls -o /dev/null -w %{url_effective} https://github.com/okd-project/okd/releases/latest))

  local CONTINUE="true"
  local SYS_ARCH=$(uname)
  if [[ ${SYS_ARCH} == "Darwin" ]]
  then
    if [[ $(uname -m) == "arm64" ]]
    then
      OS_VER=mac-arm64
    else
      OS_VER=mac
    fi
  elif [[ ${SYS_ARCH} == "Linux" ]]
  then
    OS_VER=linux
  else
    echo "Unsupported OS: Cannot pull openshift commands"
    CONTINUE="false"
  fi
  if [[ ${CONTINUE} == "true" ]]
  then
    WORK_DIR=$(mktemp -d)
    mkdir -p ${OPENSHIFT_LAB_PATH}/openshift-cmds/init
    wget -O ${WORK_DIR}/oc.tar.gz https://github.com/okd-project/okd/releases/download/${OKD_RELEASE}/openshift-client-${OS_VER}-${OKD_RELEASE}.tar.gz
    tar -xzf ${WORK_DIR}/oc.tar.gz -C ${OPENSHIFT_LAB_PATH}/openshift-cmds/init
    chmod 700 ${OPENSHIFT_LAB_PATH}/openshift-cmds/init/*
    rm -rf ${WORK_DIR}
    # fixMacArmCodeSign
  fi
}

function getCliCmds() {

  if [[ ! -d ${OPENSHIFT_LAB_PATH}/openshift-cmds/init ]]
  then
    getInitCli
  fi

  local release_type=$(yq e ".cluster.release-type" ${CLUSTER_CONFIG})
  local tools_uri="$(yq e ".cluster.tools-uri" ${CLUSTER_CONFIG}):${OPENSHIFT_RELEASE}"
  local registry_config=""

  # case ${release_type} in
  #   okd)
  #     tools_uri=registry.ci.openshift.org/origin/release:${OPENSHIFT_RELEASE}
  #   ;;
  #   okd-scos)
  #     tools_uri=quay.io/okd/scos-release:${OPENSHIFT_RELEASE}
  #   ;;
  #   ocp)
  #     tools_uri=quay.io/openshift-release-dev/ocp-release:${OPENSHIFT_RELEASE}
  #     registry_config="--registry-config=${OPENSHIFT_LAB_PATH}/ocp-pull-secret"
  #   ;;
  #   ocp-nightly)
  #     tools_uri=quay.io/openshift-release-dev/ocp-release:${OPENSHIFT_RELEASE}
  #     registry_config="--registry-config=${OPENSHIFT_LAB_PATH}/ocp-pull-secret"
  #   ;;
  # esac
  if [[ ${release_type} == "ocp" ]]
  then
    registry_config="--registry-config=${OPENSHIFT_LAB_PATH}/lab-config/ocp-pull-secret"
  fi
  mkdir -p ${OPENSHIFT_LAB_PATH}/openshift-cmds/${OPENSHIFT_RELEASE}
  WORK_DIR=$(mktemp -d)
  ${OC_INIT} adm release extract ${registry_config} --to="${WORK_DIR}" --tools ${tools_uri}
  for i in $(ls ${WORK_DIR}/*.tar.gz)
  do
    tar -xzf ${i} -C ${OPENSHIFT_LAB_PATH}/openshift-cmds/${OPENSHIFT_RELEASE}
  done
  rm -rf ${WORK_DIR}
  # fixMacArmCodeSign
}

function getButane() {
  local CONTINUE="true"
  local SYS_ARCH=$(uname)
  local PROC_ARCH=x86_64
  if [[ ${SYS_ARCH} == "Darwin" ]]
  then
    BUTANE_DLD=apple-darwin
    if [[ $(uname -m) == "arm64" ]]
    then
      PROC_ARCH=aarch64
    fi
  elif [[ ${SYS_ARCH} == "Linux" ]]
  then
    BUTANE_DLD=unknown-linux-gnu
  else
    echo "Unsupported OS: Cannot pull openshift commands"
    CONTINUE="false"
  fi
  if [[ ${CONTINUE} == "true" ]]
  then
    mkdir -p ${OPENSHIFT_LAB_PATH}/butane/${BUTANE_VERSION}
    wget -O ${OPENSHIFT_LAB_PATH}/butane/${BUTANE_VERSION}/butane https://github.com/coreos/butane/releases/download/${BUTANE_VERSION}/butane-${PROC_ARCH}-${BUTANE_DLD}
  fi
}

function clearLabEnv() {
  if [[ ! -z ${OPENSHIFT_RELEASE} ]]
  then
    for i in $(ls ${OPENSHIFT_LAB_PATH}/openshift-cmds/${OPENSHIFT_RELEASE})
    do
      rm -f ${OPENSHIFT_LAB_PATH}/bin/${i}
    done
  fi
  unset CLUSTER_CONFIG
  unset SUB_DOMAIN
  unset DOMAIN
  unset DOMAIN_ROUTER
  unset DOMAIN_ROUTER_EDGE
  unset DOMAIN_NETWORK
  unset DOMAIN_NETMASK
  unset LOCAL_REGISTRY
  unset PROXY_REGISTRY
  unset CLUSTER_NAME
  unset KUBE_INIT_CONFIG
  unset OPENSHIFT_RELEASE
  unset DOMAIN_CIDR
  unset CLUSTER_CIDR
  unset SERVICE_CIDR
  unset BUTANE_VERSION
  unset BUTANE_SPEC_VERSION
  unset OPENSHIFT_REGISTRY
  unset PULL_SECRET
  unset DOMAIN_ARPA
  unset LAB_DOMAIN
  unset EDGE_ROUTER
  unset EDGE_NETMASK
  unset EDGE_NETWORK
  unset EDGE_CIDR
  unset PI_IP
  unset GIT_SERVER
  unset EDGE_ARPA
  unset KUBECONFIG
}