
function qnap() {
  
  export QNAP_VERSION=$(yq e ".cluster.qnap.version" ${CLUSTER_CONFIG})
  export QNAP_BACKEND=$(yq e ".cluster.qnap.backend" ${CLUSTER_CONFIG})
  export ISCSI_IP=$(yq e ".cluster.qnap.ip-addr" ${CLUSTER_CONFIG})
  export ISCSI_USER=$(yq e ".cluster.qnap.user" ${CLUSTER_CONFIG})

  for j in "$@"
  do
    case $j in
      -i)
        deployIscsiOperator
      ;;
      -s)
        createIscsiStorageClass
      ;;
      -r)
        createRegistryPvc ${QNAP_BACKEND}
      ;;
    esac
  done
}

function deployIscsiOperator() {

  export QNAP_WORK_DIR=${OPENSHIFT_LAB_PATH}/${CLUSTER_NAME}.${DOMAIN}/qnap-work-dir
  rm -rf ${QNAP_WORK_DIR}
  git clone -b ${QNAP_VERSION} https://github.com/qnap-dev/QNAP-CSI-PlugIn.git ${QNAP_WORK_DIR}
  ${OC} apply -f ${QNAP_WORK_DIR}/Deploy/Trident/namespace.yaml 
  ${OC} apply -f ${QNAP_WORK_DIR}/Deploy/crds/tridentorchestrator_crd.yaml 
  ${OC} apply -f ${QNAP_WORK_DIR}/Deploy/Trident/bundle.yaml 
  ${OC} apply -f ${QNAP_WORK_DIR}/Deploy/Trident/tridentorchestrator.yaml
  ${OC} apply -k ${QNAP_WORK_DIR}/VolumeSnapshot
}

function createIscsiStorageClass() {

${OC} wait --for=condition=Available -n trident --timeout=300s --all deployments

  ISCSI_PWD="red"
  ISCSI_PWD_CHK="green"
  while [[ ${ISCSI_PWD} != ${ISCSI_PWD_CHK} ]]
  do
    echo "Enter the Password for the QNAP user:"
    read -s ISCSI_PWD
    echo "Re-Enter the Password for the QNAP user:"
    read -s ISCSI_PWD_CHK
    if [[ ${ISCSI_PWD} != ${ISCSI_PWD_CHK} ]]
    then
      echo "Passwords do not match. Try Again."
    fi
  done

cat << EOF | ${OC} apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${QNAP_BACKEND}-secret
  namespace: trident
type: Opaque
stringData:
  username: ${ISCSI_USER}
  password: ${ISCSI_PWD}
  storageAddress: ${ISCSI_IP}
---
apiVersion: trident.qnap.io/v1
kind: TridentBackendConfig
metadata:
  name: ${QNAP_BACKEND}
  namespace: trident
spec:
  version: 1
  storageDriverName: qnap-iscsi
  backendName: ${QNAP_BACKEND}
  networkInterfaces: []
  credentials:
    name: ${QNAP_BACKEND}-secret
  debugTraceFlags:
    method: false
  storage:
    - labels:
        storage: ${QNAP_BACKEND}
        serviceLevel: Any
---
apiVersion: storage.k8s.io/v1 
kind: StorageClass 
metadata: 
  name: ${QNAP_BACKEND} 
  annotations:
    storageclass.kubernetes.io/is-default-class: 'true'
provisioner: csi.trident.qnap.io
parameters: 
  selector: "storage=${QNAP_BACKEND}"
  csi.storage.k8s.io/fstype: ext4
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: qnap-snapshotclass
driver: csi.trident.qnap.io
deletionPolicy: Delete
EOF
}

function createRegistryPvc() {

local STORAGE_CLASS=${1}

cat << EOF | ${OC} apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-pvc
  namespace: openshift-image-registry
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
  storageClassName: ${STORAGE_CLASS}
EOF

  ${OC} patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"rolloutStrategy":"Recreate","managementState":"Managed","storage":{"pvc":{"claim":"registry-pvc"}}}}'
}
