function deleteControlPlane() {
  local p_cmd=${1}

  #Delete Control Plane Nodes:
  RESET_LB="true"
  CP_COUNT=$(yq e ".control-plane.nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  if [[ ${CP_COUNT} == "1" ]]
  then
    RESET_LB="false"
  fi
  metal=$(yq e ".control-plane.metal" ${CLUSTER_CONFIG})
  let node_count=$(yq e ".control-plane.nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    mac_addr=$(yq e ".control-plane.nodes.[${node_index}].mac-addr" ${CLUSTER_CONFIG})
    host_name=$(yq e ".control-plane.nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    if [[ ${metal} == "true" ]]
    then
      boot_dev=$(yq e ".control-plane.boot-dev" ${CLUSTER_CONFIG})
      storage_dev=na
      if [[ $(yq ".control-plane | has(\"hostpath-dev\")" ${CLUSTER_CONFIG}) == "true" ]]
      then
        storage_dev=$(yq e ".control-plane.hostpath-dev" ${CLUSTER_CONFIG})
      fi
      destroyMetal core ${host_name} ${boot_dev} ${storage_dev} ${p_cmd}
    else
      kvm_host=$(yq e ".control-plane.nodes.[${node_index}].kvm-host" ${CLUSTER_CONFIG})
      deleteNodeVm ${host_name} ${kvm_host}.${DOMAIN}
    fi
    deletePxeConfig ${mac_addr}
    node_index=$(( ${node_index} + 1 ))
  done
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
      uci delete network.${INTERFACE}_api_lb ; \
      uci delete network.${INTERFACE}_ingress_lb ; \
      uci commit ; \
      /etc/init.d/network reload; \
      sleep 10"
  fi
  deleteDns ${CLUSTER_NAME}-${DOMAIN}-cp
}

function destroy() {
  P_CMD="poweroff"
  checkRouterModel ${DOMAIN_ROUTER}

  for i in "$@"
  do
    case $i in
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

  WORK_DIR=${OPENSHIFT_LAB_PATH}/${CLUSTER_NAME}.${DOMAIN}

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

  if [[ ${DELETE_CLUSTER} == "true" ]]
  then
    deleteControlPlane ${P_CMD}
    if [[ -f  ${PULL_SECRET} ]]
    then
      rm ${PULL_SECRET}
    fi
  fi

  ${SSH} root@${DOMAIN_ROUTER} "/etc/init.d/named stop && sleep 2 && /etc/init.d/named start && sleep 2"
  ${SSH} root@${EDGE_ROUTER} "/etc/init.d/named stop && sleep 2 && /etc/init.d/named start"
  rm -f ${KUBE_INIT_CONFIG}
}
