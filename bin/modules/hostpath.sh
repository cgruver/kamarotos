

function deploySnoHostPath() {

deployCertManagerOperator

local HPP_VER=$(basename $(curl -Ls -o /dev/null -w %{url_effective} https://github.com/kubevirt/hostpath-provisioner-operator/releases/latest))

${OC} wait --for=condition=Available -n cert-manager-operator --timeout=300s --all deployments
${OC} wait --for=condition=Available -n cert-manager --timeout=300s --all deployments
${OC} create -f https://github.com/kubevirt/hostpath-provisioner-operator/releases/download/${HPP_VER}/namespace.yaml
${OC} create -f https://github.com/kubevirt/hostpath-provisioner-operator/releases/download/${HPP_VER}/webhook.yaml -n hostpath-provisioner
${OC} create -f https://github.com/kubevirt/hostpath-provisioner-operator/releases/download/${HPP_VER}/operator.yaml -n hostpath-provisioner
${OC} wait --for=condition=Available -n hostpath-provisioner --timeout=300s --all deployments

cat << EOF | ${OC} apply -f -
apiVersion: hostpathprovisioner.kubevirt.io/v1beta1
kind: HostPathProvisioner
metadata:
  name: hostpath-provisioner
spec:
  imagePullPolicy: Always
  storagePools:
    - name: "local"
      path: "/var/hostpath"
  workload:
    nodeSelector:
      kubernetes.io/os: linux
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: hostpath-csi
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubevirt.io.hostpath-provisioner
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
parameters:
  storagePool: local
---
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
  storageClassName: hostpath-csi
EOF

${OC} patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"rolloutStrategy":"Recreate","managementState":"Managed","storage":{"pvc":{"claim":"registry-pvc"}}}}'

}