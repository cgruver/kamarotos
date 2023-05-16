function deleteControlPlane() {
  local p_cmd=${1}

  #Delete Control Plane Nodes:
  RESET_LB="true"
  CP_COUNT=$(yq e ".control-plane.okd-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
  if [[ ${CP_COUNT} == "1" ]]
  then
    SNO="true"
    RESET_LB="false"
    if [[ $(yq e ". | has(\"bootstrap\")" ${CLUSTER_CONFIG}) == "false" ]]
    then
      BIP="true"
    fi
  fi
  metal=$(yq e ".control-plane.metal" ${CLUSTER_CONFIG})
  if [[ ${SNO} == "true" ]]
  then
    mac_addr=$(yq e ".control-plane.okd-hosts.[0].mac-addr" ${CLUSTER_CONFIG})
    host_name=$(yq e ".control-plane.okd-hosts.[0].name" ${CLUSTER_CONFIG})
    if [[ ${metal} == "true" ]]
    then
      install_dev=$(yq e ".control-plane.okd-hosts.[0].sno-install-dev" ${CLUSTER_CONFIG})
      destroyMetal core ${host_name} ${install_dev} na ${p_cmd}
    else
      kvm_host=$(yq e ".control-plane.okd-hosts.[0].kvm-host" ${CLUSTER_CONFIG})
      deleteNodeVm ${host_name} ${kvm_host}.${DOMAIN}
    fi
    deletePxeConfig ${mac_addr}
    if [[ ${BIP} == "true" ]]
    then
      deleteBipIpRes ${mac_addr}
    fi
  else
    for node_index in 0 1 2
    do
      mac_addr=$(yq e ".control-plane.okd-hosts.[${node_index}].mac-addr" ${CLUSTER_CONFIG})
      host_name=$(yq e ".control-plane.okd-hosts.[${node_index}].name" ${CLUSTER_CONFIG})
      if [[ ${metal} == "true" ]]
      then
        boot_dev=$(yq e ".control-plane.okd-hosts.[${node_index}].boot-dev" ${CLUSTER_CONFIG})
        destroyMetal core ${host_name} ${boot_dev} na ${p_cmd}
      else
        kvm_host=$(yq e ".control-plane.okd-hosts.[${node_index}].kvm-host" ${CLUSTER_CONFIG})
        deleteNodeVm ${host_name} ${kvm_host}.${DOMAIN}
      fi
      deletePxeConfig ${mac_addr}
    done
  fi
  if [[ ${RESET_LB} == "true" ]]
  then
    INTERFACE=$(echo "${CLUSTER_NAME//-/_}" | tr "[:upper:]" "[:lower:]")
    if [[ ${GL_MODEL} == "GL-AXT1800" ]]
    then
      ${SSH} root@${DOMAIN_ROUTER} "rm /usr/local/nginx/nginx-${CLUSTER_NAME}.conf ; \
      /etc/init.d/nginx restart"
    else
    ${SSH} root@${DOMAIN_ROUTER} "/etc/init.d/haproxy-${CLUSTER_NAME} stop ; \
      /etc/init.d/haproxy-${CLUSTER_NAME} disable ; \
      rm -f /etc/init.d/haproxy-${CLUSTER_NAME} ; \
      rm -f /etc/haproxy-${CLUSTER_NAME}.cfg"
    fi
    ${SSH} root@${DOMAIN_ROUTER} "uci delete network.${INTERFACE}_lb ; \
      uci commit ; \
      /etc/init.d/network reload; \
      sleep 10"
  fi
  deleteDns ${CLUSTER_NAME}-${DOMAIN}-cp
}

function destroy() {
  P_CMD="poweroff"
  SNO="false"
  checkRouterModel ${DOMAIN_ROUTER}

  for i in "$@"
  do
    case $i in
      -b|--bootstrap)
        DELETE_BOOTSTRAP=true
      ;;
      -w=*|--worker=*)
        DELETE_WORKER=true
        W_HOST_NAME="${i#*=}"
      ;;
      -c|--cluster)
        DELETE_CLUSTER=true
        DELETE_WORKER=true
        W_HOST_NAME="all"
      ;;
      -k=*|--kvm-host=*)
        DELETE_KVM_HOST=true
        K_HOST_NAME="${i#*=}"
      ;;
      -m=*|--master=*)
        M_HOST_NAME="${i#*=}"
      ;;
      -r)
        P_CMD="reboot"
      ;;
      *)
        # catch all
      ;;
    esac
  done

  WORK_DIR=${OKD_LAB_PATH}/${CLUSTER_NAME}.${DOMAIN}

  if [[ ${DELETE_WORKER} == "true" ]]
  then
    if [[ ${W_HOST_NAME} == "" ]]
    then
      echo "-w | --worker must have a value"
      exit 1
    fi
    if [[ ${W_HOST_NAME} == "all" ]] # Delete all Nodes
    then
      let j=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
      let i=0
      while [[ i -lt ${j} ]]
      do
        deleteWorker ${i} ${P_CMD}
        i=$(( ${i} + 1 ))
      done
    else
      let i=0
      DONE=false
      let NODE_COUNT=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
      while [[ i -lt ${NODE_COUNT} ]]
      do
        host_name=$(yq e ".compute-nodes.[${i}].name" ${CLUSTER_CONFIG})
        if [[ ${host_name} == ${W_HOST_NAME} ]]
        then
          W_HOST_INDEX=${i}
          DONE=true
          break;
        fi
        i=$(( ${i} + 1 ))
      done
      if [[ ${W_HOST_INDEX} == "" ]]
      then
        echo "Host: ${W_HOST_NAME} not found in config file."
        exit 1
      fi
      deleteWorker ${W_HOST_INDEX} ${P_CMD}
    fi
  fi

  if [[ ${DELETE_KVM_HOST} == "true" ]]
  then
    if [[ ${K_HOST_NAME} == "" ]]
    then
      echo "-k"
      exit 1
    fi
    if [[ ${K_HOST_NAME} == "all" ]] # Delete all Nodes
    then
      let j=$(yq e ".kvm-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
      let i=0
      while [[ i -lt ${j} ]]
      do
        deleteKvmHost ${i} ${P_CMD}
        i=$(( ${i} + 1 ))
      done
    else
      let i=0
      DONE=false
      let NODE_COUNT=$(yq e ".kvm-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
      while [[ i -lt ${NODE_COUNT} ]]
      do
        host_name=$(yq e ".kvm-hosts.[${i}].host-name" ${CLUSTER_CONFIG})
        if [[ ${host_name} == ${K_HOST_NAME} ]]
        then
          K_HOST_INDEX=${i}
          DONE=true
          break;
        fi
        i=$(( ${i} + 1 ))
      done
      if [[ ${K_HOST_INDEX} == "" ]]
      then
        echo "Host: ${K_HOST_NAME} not found in config file."
        exit 1
      fi
      deleteKvmHost ${K_HOST_INDEX} ${P_CMD}
    fi
  fi

  if [[ ${DELETE_BOOTSTRAP} == "true" ]]
  then
    if [[ $(yq e ".bootstrap.metal" ${CLUSTER_CONFIG}) == "true" ]]
    then
      kill $(ps -ef | grep qemu | grep bootstrap | awk '{print $2}')
      rm -rf ${WORK_DIR}/bootstrap
    else
      host_name="${CLUSTER_NAME}-bootstrap"
      kvm_host=$(yq e ".bootstrap.kvm-host" ${CLUSTER_CONFIG})
      deleteNodeVm ${host_name} ${kvm_host}.${BOOTSTRAP_KVM_DOMAIN}
    fi
    deletePxeConfig $(yq e ".bootstrap.mac-addr" ${CLUSTER_CONFIG})
    deleteDns ${CLUSTER_NAME}-${DOMAIN}-bs
    CP_COUNT=$(yq e ".control-plane.okd-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
    if [[ ${CP_COUNT} == "1" ]]
    then
      SNO="true"
      if [[ $(yq e ". | has(\"bootstrap\")" ${CLUSTER_CONFIG}) == "false" ]]
      then
        BIP="true"
      fi
    fi
    if [[ ${SNO} == "false" ]]
    then
      if [[ ${GL_MODEL} == "GL-AXT1800" ]]
      then
        ${SSH} root@${DOMAIN_ROUTER} "cat /usr/local/nginx/nginx-${CLUSTER_NAME}.conf | grep -v bootstrap > /usr/local/nginx/nginx-${CLUSTER_NAME}.no-bootstrap ; \
          mv /usr/local/nginx/nginx-${CLUSTER_NAME}.no-bootstrap /usr/local/nginx/nginx-${CLUSTER_NAME}.conf ; \
          /etc/init.d/nginx restart"
      else
        ${SSH} root@${DOMAIN_ROUTER} "cat /etc/haproxy-${CLUSTER_NAME}.cfg | grep -v bootstrap > /etc/haproxy-${CLUSTER_NAME}.no-bootstrap ; \
        mv /etc/haproxy-${CLUSTER_NAME}.no-bootstrap /etc/haproxy-${CLUSTER_NAME}.cfg ; \
        /etc/init.d/haproxy-${CLUSTER_NAME} stop ; \
        /etc/init.d/haproxy-${CLUSTER_NAME} start"
      fi
    fi
  fi

  if [[ ${DELETE_CLUSTER} == "true" ]]
  then
    deleteControlPlane ${P_CMD}
  fi

  ${SSH} root@${DOMAIN_ROUTER} "/etc/init.d/named stop && sleep 2 && /etc/init.d/named start && sleep 2"
  ${SSH} root@${EDGE_ROUTER} "/etc/init.d/named stop && sleep 2 && /etc/init.d/named start"
}
