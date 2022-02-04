function labenv() {
  for i in "$@"
  do
    case $i in
      -d=*|--domain=*)
        sub_domain="${i#*=}"
        labctx ${sub_domain}
      ;;
      --edge)
        setEdgeEnv
      ;;
      --kube)
        labcli --kube
        export KUBECONFIG
      ;;
      *)
        usage
      ;;
    esac
  done
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
    if [[ -z ${sub_domain} ]]
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
    setDomainEnv
  fi
  echo "Your shell environment is now set up to control lab domain: ${DOMAIN}"
}

function mask2cidr() {
   local x=${1##*255.}
   set -- 0^^^128^192^224^240^248^252^254^ $(( (${#1} - ${#x})*2 )) ${x%%.*}
   x=${1%%$3*}
   echo $(( $2 + (${#x}/4) ))
}

function setDomainEnv() {

  export CLUSTER_CONFIG=$(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].cluster-config-file" ${LAB_CONFIG_FILE})
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
  export OKD_RELEASE=$(yq e ".cluster.release" ${CLUSTER_CONFIG})
  export DOMAIN_CIDR=$(mask2cidr ${DOMAIN_NETMASK})
  export CLUSTER_CIDR=$(yq e ".cluster.cluster-cidr" ${CLUSTER_CONFIG})
  export SERVICE_CIDR=$(yq e ".cluster.service-cidr" ${CLUSTER_CONFIG})
  export BUTANE_VERSION=$(yq e ".cluster.butane-version" ${CLUSTER_CONFIG})
  export BUTANE_SPEC_VERSION=$(yq e ".cluster.butane-spec-version" ${CLUSTER_CONFIG})
  export OKD_REGISTRY=$(yq e ".cluster.remote-registry" ${CLUSTER_CONFIG})
  export PULL_SECRET=$(yq e ".cluster.secret-file" ${CLUSTER_CONFIG})
  IFS="." read -r i1 i2 i3 i4 <<< "${DOMAIN_NETWORK}"
  export DOMAIN_ARPA=${i3}.${i2}.${i1}
  if [[ ! -d ${OKD_LAB_PATH}/okd-cmds/${OKD_RELEASE} ]]
  then
    getOkdCmds
  fi
  for i in $(ls ${OKD_LAB_PATH}/okd-cmds/${OKD_RELEASE})
  do
    rm -f ${OKD_LAB_PATH}/bin/${i}
    ln -s ${OKD_LAB_PATH}/okd-cmds/${OKD_RELEASE}/${i} ${OKD_LAB_PATH}/bin/${i}
  done
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
    IFS="." read -r i1 i2 i3 i4 <<< "${EDGE_NETWORK}"
    export EDGE_ARPA=${i3}.${i2}.${i1}
  fi
}

