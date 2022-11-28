export OKD_LAB_PATH=${HOME}/okd-lab
export PATH=$PATH:${OKD_LAB_PATH}/bin
if [[ -z ${LAB_CONFIG_FILE} ]]
then
  export LAB_CONFIG_FILE=${OKD_LAB_PATH}/lab-config/lab.yaml
fi

function labenv() {

  for i in "$@"
  do
    case $i in
      -d=*|--domain=*)
        sub_domain="${i#*=}"
        labctx ${sub_domain}
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
        if [[ -z ${SUB_DOMAIN} ]]
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

function setDomainIndex() {

  local sub_domain=${1}
  SUB_DOMAIN=""
  INDEX=""
  export LAB_CTX_ERROR="true"

  if [[ -z ${LAB_CONFIG_FILE} ]]
  then
    echo "ENV VAR LAB_CONFIG_FILE must be set to the path to a lab config yaml."
  else
    DONE=false
    DOMAIN_COUNT=$(yq e ".sub-domain-configs" ${LAB_CONFIG_FILE} | yq e 'length' -)
    if [[ ${DOMAIN_COUNT} -eq 0 ]]
    then
      INDEX=""
      DONE="true"
    elif [[ -z ${sub_domain} ]]
    then
      let array_index=0
      while [[ array_index -lt ${DOMAIN_COUNT} ]]
      do
        domain_name=$(yq e ".sub-domain-configs.[${array_index}].name" ${LAB_CONFIG_FILE})
        echo "$(( ${array_index} + 1 )) - ${domain_name}"
        array_index=$(( ${array_index} + 1 ))
      done
      unset array_index
      echo "Enter the index of the domain that you want to work with:"
      read ENTRY
      INDEX=$(( ${ENTRY} - 1 ))
      DONE="true"
    else
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
    fi
    if [[ ${DONE} == "true" ]]
    then
      export LAB_CTX_ERROR="false"
      DOMAIN_INDEX=${INDEX}
    else
      echo "Domain Entry Not Found In Config File."
      DOMAIN_INDEX=""
    fi
  fi
}

function labctx() {

  local sub_domain=${1}
  SUB_DOMAIN=""
  setDomainIndex ${sub_domain}

  if [[ ${LAB_CTX_ERROR} == "false" ]]
  then
    setEdgeEnv
    if [[ ${DOMAIN_INDEX} != "" ]]
    then
      setDomainEnv
    fi
  fi
}

function mask2cidr() {
   local x=${1##*255.}
   set -- 0^^^128^192^224^240^248^252^254^ $(( (${#1} - ${#x})*2 )) ${x%%.*}
   x=${1%%$3*}
   echo $(( $2 + (${#x}/4) ))
}

function setDomainEnv() {

  export CLUSTER_CONFIG=${OKD_LAB_PATH}/lab-config/domain-configs/$(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].cluster-config-file" ${LAB_CONFIG_FILE})
  export SUB_DOMAIN=$(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].name" ${LAB_CONFIG_FILE})
  export DOMAIN="${SUB_DOMAIN}.${LAB_DOMAIN}"
  export DOMAIN_ROUTER=$(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].router-ip" ${LAB_CONFIG_FILE})
  export DOMAIN_ROUTER_EDGE=$(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].router-edge-ip" ${LAB_CONFIG_FILE})
  export DOMAIN_NETWORK=$(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].network" ${LAB_CONFIG_FILE})
  export DOMAIN_NETMASK=$(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].netmask" ${LAB_CONFIG_FILE})
  export LOCAL_REGISTRY=$(yq e ".cluster.local-registry" ${CLUSTER_CONFIG})
  export PROXY_REGISTRY=$(yq e ".cluster.proxy-registry" ${CLUSTER_CONFIG})
  export CLUSTER_NAME=$(yq e ".cluster.name" ${CLUSTER_CONFIG})
  export KUBE_INIT_CONFIG=${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}/kubeconfig
  export INSTALL_DIR=${OKD_LAB_PATH}/${CLUSTER_NAME}-${SUB_DOMAIN}-${LAB_DOMAIN}/okd-install-dir
  export DOMAIN_CIDR=$(mask2cidr ${DOMAIN_NETMASK})
  export CLUSTER_CIDR=$(yq e ".cluster.cluster-cidr" ${CLUSTER_CONFIG})
  export SERVICE_CIDR=$(yq e ".cluster.service-cidr" ${CLUSTER_CONFIG})
  export BUTANE_VERSION=$(yq e ".cluster.butane-version" ${CLUSTER_CONFIG})
  export BUTANE_SPEC_VERSION=$(yq e ".cluster.butane-spec-version" ${CLUSTER_CONFIG})
  export OKD_REGISTRY=$(yq e ".cluster.remote-registry" ${CLUSTER_CONFIG})
  export PULL_SECRET=${OKD_LAB_PATH}/pull-secrets/${CLUSTER_NAME}-pull-secret.json
  IFS="." read -r i1 i2 i3 i4 <<< "${DOMAIN_NETWORK}"
  export DOMAIN_ARPA=${i3}.${i2}.${i1}
  release_set=$(yq ".cluster | has(\"release\")" ${CLUSTER_CONFIG})
  if [[ ${release_set} == "true" ]]
  then
    export OKD_RELEASE=$(yq e ".cluster.release" ${CLUSTER_CONFIG})
    if [[ ! -d ${OKD_LAB_PATH}/okd-cmds/${OKD_RELEASE} ]]
    then
      getOkdCmds
    fi
    for i in $(ls ${OKD_LAB_PATH}/okd-cmds/${OKD_RELEASE})
    do
      rm -f ${OKD_LAB_PATH}/bin/${i}
      ln -s ${OKD_LAB_PATH}/okd-cmds/${OKD_RELEASE}/${i} ${OKD_LAB_PATH}/bin/${i}
    done
    i=""
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
    export EDGE_NETMASK=$(yq e ".netmask" ${LAB_CONFIG_FILE})
    export EDGE_NETWORK=$(yq e ".network" ${LAB_CONFIG_FILE})
    export EDGE_CIDR=$(mask2cidr ${EDGE_NETMASK})
    export BASTION_HOST=$(yq e ".bastion-ip" ${LAB_CONFIG_FILE})
    export GIT_SERVER=$(yq e ".git-url" ${LAB_CONFIG_FILE})
    IFS="." read -r i1 i2 i3 i4 <<< "${EDGE_NETWORK}"
    export EDGE_ARPA=${i3}.${i2}.${i1}
  fi
}

function fixMacArmCodeSign() {

  if [[ $(uname) == "Darwin" ]] && [[ $(uname -m) == "arm64" ]]
  then
    echo "Applying workaround for corrupt signiture on OpenShift CLI binaries"
    codesign --force -s - ${OKD_LAB_PATH}/okd-cmds/${OKD_RELEASE}/oc
    codesign --force -s - ${OKD_LAB_PATH}/okd-cmds/${OKD_RELEASE}/openshift-install
  fi
}

function getOkdCmds() {
  CONTINUE="true"
  local sub_domain=${1}
  SYS_ARCH=$(uname)
  PROC_ARCH=x86_64
  if [[ ${SYS_ARCH} == "Darwin" ]]
  then
    BUTANE_DLD=apple-darwin
    if [[ $(uname -m) == "arm64" ]]
    then
      OS_VER=mac-arm64
      PROC_ARCH=aarch64
    else
      OS_VER=mac
    fi
  elif [[ ${SYS_ARCH} == "Linux" ]]
  then
    OS_VER=linux
    BUTANE_DLD=unknown-linux-gnu
  else
    echo "Unsupported OS: Cannot pull openshift commands"
    CONTINUE="false"
  fi
  if [[ ${CONTINUE} == "true" ]]
  then
    mkdir -p ${OKD_LAB_PATH}/okd-cmds/${OKD_RELEASE}
    mkdir -p ${OKD_LAB_PATH}/tmp
    wget -O ${OKD_LAB_PATH}/tmp/oc.tar.gz https://github.com/openshift/okd/releases/download/${OKD_RELEASE}/openshift-client-${OS_VER}-${OKD_RELEASE}.tar.gz
    wget -O ${OKD_LAB_PATH}/tmp/oc-install.tar.gz https://github.com/openshift/okd/releases/download/${OKD_RELEASE}/openshift-install-${OS_VER}-${OKD_RELEASE}.tar.gz
    wget -O ${OKD_LAB_PATH}/okd-cmds/${OKD_RELEASE}/butane https://github.com/coreos/butane/releases/download/${BUTANE_VERSION}/butane-${PROC_ARCH}-${BUTANE_DLD}
    tar -xzf ${OKD_LAB_PATH}/tmp/oc.tar.gz -C ${OKD_LAB_PATH}/okd-cmds/${OKD_RELEASE}
    tar -xzf ${OKD_LAB_PATH}/tmp/oc-install.tar.gz -C ${OKD_LAB_PATH}/okd-cmds/${OKD_RELEASE}
    chmod 700 ${OKD_LAB_PATH}/okd-cmds/${OKD_RELEASE}/*
    rm -rf ${OKD_LAB_PATH}/tmp
    fixMacArmCodeSign
    for i in $(ls ${OKD_LAB_PATH}/okd-cmds/${OKD_RELEASE})
    do
      rm -f ${OKD_LAB_PATH}/bin/${i}
      ln -s ${OKD_LAB_PATH}/okd-cmds/${OKD_RELEASE}/${i} ${OKD_LAB_PATH}/bin/${i}
    done
  fi
}

function clearLabEnv() {
  if [[ ! -z ${OKD_RELEASE} ]]
  then
    for i in $(ls ${OKD_LAB_PATH}/okd-cmds/${OKD_RELEASE})
    do
      rm -f ${OKD_LAB_PATH}/bin/${i}
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
  unset INSTALL_DIR
  unset OKD_RELEASE
  unset DOMAIN_CIDR
  unset CLUSTER_CIDR
  unset SERVICE_CIDR
  unset BUTANE_VERSION
  unset BUTANE_SPEC_VERSION
  unset OKD_REGISTRY
  unset PULL_SECRET
  unset DOMAIN_ARPA
  unset LAB_DOMAIN
  unset EDGE_ROUTER
  unset EDGE_NETMASK
  unset EDGE_NETWORK
  unset EDGE_CIDR
  unset BASTION_HOST
  unset GIT_SERVER
  unset EDGE_ARPA
  unset KUBECONFIG
}