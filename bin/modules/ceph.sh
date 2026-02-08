function mirrorCeph() {

  echo "Enter the credentials for the openshift mirrir service account in Nexus:"
  podman login ${LOCAL_REGISTRY}

  echo "Pulling Rook/Ceph Images..."
  podman pull --arch=amd64 quay.io/cephcsi/cephcsi:${CEPH_CSI_VER}
  podman pull --arch=amd64 registry.k8s.io/sig-storage/csi-node-driver-registrar:${CSI_NODE_DRIVER_REG_VER}
  podman pull --arch=amd64 registry.k8s.io/sig-storage/csi-resizer:${CSI_RESIZER_VER}
  podman pull --arch=amd64 registry.k8s.io/sig-storage/csi-provisioner:${CSI_PROVISIONER_VER}
  podman pull --arch=amd64 registry.k8s.io/sig-storage/csi-snapshotter:${CSI_SNAPSHOTTER_VER}
  podman pull --arch=amd64 registry.k8s.io/sig-storage/csi-attacher:${CSI_ATTACHER_VER}
  podman pull --arch=amd64 docker.io/rook/ceph:${ROOK_CEPH_VER}
  podman pull --arch=amd64 quay.io/ceph/ceph:${CEPH_VER}

  echo "Tagging Rook/Ceph Images..."
  podman tag quay.io/cephcsi/cephcsi:${CEPH_CSI_VER} ${LOCAL_REGISTRY}/cephcsi/cephcsi:${CEPH_CSI_VER}
  podman tag registry.k8s.io/sig-storage/csi-node-driver-registrar:${CSI_NODE_DRIVER_REG_VER} ${LOCAL_REGISTRY}/sig-storage/csi-node-driver-registrar:${CSI_NODE_DRIVER_REG_VER}
  podman tag registry.k8s.io/sig-storage/csi-resizer:${CSI_RESIZER_VER} ${LOCAL_REGISTRY}/sig-storage/csi-resizer:${CSI_RESIZER_VER}
  podman tag registry.k8s.io/sig-storage/csi-provisioner:${CSI_PROVISIONER_VER} ${LOCAL_REGISTRY}/sig-storage/csi-provisioner:${CSI_PROVISIONER_VER}
  podman tag registry.k8s.io/sig-storage/csi-snapshotter:${CSI_SNAPSHOTTER_VER} ${LOCAL_REGISTRY}/sig-storage/csi-snapshotter:${CSI_SNAPSHOTTER_VER}
  podman tag registry.k8s.io/sig-storage/csi-attacher:${CSI_ATTACHER_VER} ${LOCAL_REGISTRY}/sig-storage/csi-attacher:${CSI_ATTACHER_VER}
  podman tag docker.io/rook/ceph:${ROOK_CEPH_VER} ${LOCAL_REGISTRY}/rook/ceph:${ROOK_CEPH_VER}
  podman tag quay.io/ceph/ceph:${CEPH_VER} ${LOCAL_REGISTRY}/ceph/ceph:${CEPH_VER}

  echo "Pushing Rook/Ceph Images..."
  podman push ${LOCAL_REGISTRY}/cephcsi/cephcsi:${CEPH_CSI_VER} --tls-verify=false
  podman push ${LOCAL_REGISTRY}/sig-storage/csi-node-driver-registrar:${CSI_NODE_DRIVER_REG_VER} --tls-verify=false
  podman push ${LOCAL_REGISTRY}/sig-storage/csi-resizer:${CSI_RESIZER_VER} --tls-verify=false
  podman push ${LOCAL_REGISTRY}/sig-storage/csi-provisioner:${CSI_PROVISIONER_VER} --tls-verify=false
  podman push ${LOCAL_REGISTRY}/sig-storage/csi-snapshotter:${CSI_SNAPSHOTTER_VER} --tls-verify=false
  podman push ${LOCAL_REGISTRY}/sig-storage/csi-attacher:${CSI_ATTACHER_VER} --tls-verify=false
  podman push ${LOCAL_REGISTRY}/rook/ceph:${ROOK_CEPH_VER} --tls-verify=false
  podman push ${LOCAL_REGISTRY}/ceph/ceph:${CEPH_VER} --tls-verify=false

  echo "Cleaning up local Rook/Ceph Images..."
  podman image rm -a
}

function installCeph() {

  ${OC} apply -f ${CEPH_WORK_DIR}/install/crds.yaml
  ${OC} apply -f ${CEPH_WORK_DIR}/install/common.yaml
  # ${OC} apply -f ${CEPH_WORK_DIR}/install/rbac.yaml
  envsubst < ${CEPH_OPERATOR_FILE} | ${OC} apply -f -
}

function createCephCluster() {

  if [[ $(yq ". | has(\"compute-nodes\")" ${CLUSTER_CONFIG}) == "true" ]]
  then
    createWorkerCephCluster
  else
    createControlPlaneCephCluster
  fi
  envsubst < ${CEPH_CLUSTER_FILE} | ${OC} apply -f -
  ${OC} patch configmap rook-ceph-operator-config -n rook-ceph --type merge --patch '"data": {"CSI_PLUGIN_TOLERATIONS": "- key: \"node-role.kubernetes.io/master\"\n  operator: \"Exists\"\n  effect: \"NoSchedule\"\n"}'
  ${OC} apply -f ${CEPH_WORK_DIR}/configure/ceph-storage-class.yaml
}

function createControlPlaneCephCluster() {
  for node_index in 0 1 2
  do
    node_name=$(yq e ".control-plane.nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    ceph_dev=$(yq e ".control-plane.ceph.ceph-dev" ${CLUSTER_CONFIG})
    yq e ".spec.storage.nodes.[${node_index}].name = \"${node_name}\"" -i ${CEPH_CLUSTER_FILE}
    yq e ".spec.storage.nodes.[${node_index}].devices.[0].name = \"${ceph_dev}\"" -i ${CEPH_CLUSTER_FILE}
    yq e ".spec.storage.nodes.[${node_index}].devices.[0].config.osdsPerDevice = \"1\"" -i ${CEPH_CLUSTER_FILE}
    ${SSH} -o ConnectTimeout=5 core@${node_name}.${DOMAIN} "sudo wipefs -a -f ${ceph_dev} && sudo dd if=/dev/zero of=${ceph_dev} bs=4096 count=100"
    ${OC} label nodes ${node_name} role=storage-node
  done
}

function createWorkerCephCluster() {
  let NODE_COUNT=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${NODE_COUNT} ]]
  do
    node_name=$(yq e ".compute-nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    ceph_node=$(yq ".compute-nodes.[${node_index}] | has(\"ceph\")" ${CLUSTER_CONFIG})
    if [[ ${ceph_node} == "true" ]]
    then
      ceph_dev=$(yq e ".compute-nodes.[${node_index}].ceph.ceph-dev" ${CLUSTER_CONFIG})
      yq e ".spec.storage.nodes.[${node_index}].name = \"${node_name}\"" -i ${CEPH_CLUSTER_FILE}
      yq e ".spec.storage.nodes.[${node_index}].devices.[0].name = \"${ceph_dev}\"" -i ${CEPH_CLUSTER_FILE}
      yq e ".spec.storage.nodes.[${node_index}].devices.[0].config.osdsPerDevice = \"1\"" -i ${CEPH_CLUSTER_FILE}
      ${SSH} -o ConnectTimeout=5 core@${node_name}.${DOMAIN} "sudo wipefs -a -f ${ceph_dev} && sudo dd if=/dev/zero of=${ceph_dev} bs=4096 count=100"
    fi
    node_index=$(( ${node_index} + 1 ))
    ${OC} label nodes ${node_name} role=storage-node
  done
}

function regPvc() {
  ${OC} apply -f ${CEPH_WORK_DIR}/configure/registry-pvc.yaml
  ${OC} patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"rolloutStrategy":"Recreate","managementState":"Managed","storage":{"pvc":{"claim":"registry-pvc"}}}}'
}

function initCephVars() {
  export CEPH_WORK_DIR=${OPENSHIFT_LAB_PATH}/${CLUSTER_NAME}.${DOMAIN}/ceph-work-dir
  rm -rf ${CEPH_WORK_DIR}
  git clone https://github.com/cgruver/lab-ceph.git ${CEPH_WORK_DIR}

  export CEPH_CSI_VER=$(yq e ".cephcsi" ${CEPH_WORK_DIR}/install/versions.yaml)
  export CSI_NODE_DRIVER_REG_VER=$(yq e ".csi-node-driver-registrar" ${CEPH_WORK_DIR}/install/versions.yaml)
  export CSI_RESIZER_VER=$(yq e ".csi-resizer" ${CEPH_WORK_DIR}/install/versions.yaml)
  export CSI_PROVISIONER_VER=$(yq e ".csi-provisioner" ${CEPH_WORK_DIR}/install/versions.yaml)
  export CSI_SNAPSHOTTER_VER=$(yq e ".csi-snapshotter" ${CEPH_WORK_DIR}/install/versions.yaml)
  export CSI_ATTACHER_VER=$(yq e ".csi-attacher" ${CEPH_WORK_DIR}/install/versions.yaml)
  export ROOK_CEPH_VER=$(yq e ".rook-ceph" ${CEPH_WORK_DIR}/install/versions.yaml)
  export CEPH_VER=$(yq e ".ceph" ${CEPH_WORK_DIR}/install/versions.yaml)

  # if [[ ${DISCONNECTED_CLUSTER} == "true" ]]
  # then
  #   CEPH_OPERATOR_FILE=${CEPH_WORK_DIR}/install/operator-openshift.yaml
  #   CEPH_CLUSTER_FILE=${CEPH_WORK_DIR}/install/cluster.yaml
  # else
  CEPH_OPERATOR_FILE=${CEPH_WORK_DIR}/install/operator-openshift.yaml
  CEPH_CLUSTER_FILE=${CEPH_WORK_DIR}/install/cluster.yaml
  # fi

  for j in "$@"
  do
    case $j in
      -m)
        mirrorCeph
      ;;
      -i)     
        installCeph
      ;;
      -c)
        createCephCluster
      ;;
      -r)
        regPvc
      ;;
      *)
        # catch all
      ;;
    esac
  done
}