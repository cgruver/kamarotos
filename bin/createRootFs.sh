#!/bin/bash

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
CONFIG_FILE=${LAB_CONFIG_FILE}

for i in "$@"
do
  case $i in
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      shift # past argument=value
    ;;
    -d=*|--domain=*)
      SUB_DOMAIN="${i#*=}"
      shift
    ;;
      *)
            # put usage here:
      ;;
  esac
done

DONE=false
DOMAIN_COUNT=$(yq e ".sub-domain-configs" ${CONFIG_FILE} | yq e 'length' -)
let i=0
while [[ i -lt ${DOMAIN_COUNT} ]]
do
  domain_name=$(yq e ".sub-domain-configs.[${i}].name" ${CONFIG_FILE})
  if [[ ${domain_name} == ${SUB_DOMAIN} ]]
  then
    INDEX=${i}
    DONE=true
    break
  fi
  i=$(( ${i} + 1 ))
done
if [[ ${DONE} == "false" ]]
then
  echo "Domain Entry Not Found In Config File."
  exit 1
fi

SUB_DOMAIN=$(yq e ".sub-domain-configs.[${INDEX}].name" ${CONFIG_FILE})
CLUSTER_CONFIG=$(yq e ".sub-domain-configs.[${INDEX}].cluster-config-file" ${CONFIG_FILE})
CLUSTER_NAME=$(yq e ".cluster-name" ${CLUSTER_CONFIG})
OKD_RELEAE_IMAGE=$(openshift-install version | grep image | cut -d" " -f3)

podman machine init fcos
podman machine start fcos

FCOS_SSH_PORT=$(cat ~/.config/containers/podman/machine/qemu/fcos.json | jq -r '.Port')

${SCP} -i ~/.ssh/fcos -P ${FCOS_SSH_PORT} ${OKD_LAB_PATH}/ipxe-work-dir/fcos/${CLUSTER_NAME}-${SUB_DOMAIN}/rootfs.img core@localhost:/tmp/rootfs.img

cat << EOF > /tmp/createRootFs.sh
#!/bin/bash

set -x

podman pull -q ${OKD_RELEAE_IMAGE}
OS_CONTENT_IMAGE=\$(podman run --quiet --rm --net=none ${OKD_RELEAE_IMAGE} image machine-os-content)
podman pull -q \${OS_CONTENT_IMAGE}
CONTAINER_ID=\$(podman create --net=none --name ostree-container \${OS_CONTENT_IMAGE})
mkdir -p /usr/local/fcos-image/os-content
podman cp \${CONTAINER_ID}:/ /usr/local/fcos-image/os-content
mkdir -p /usr/local/fcos-image/rootfs
cpio --extract -D /usr/local/fcos-image/rootfs < /tmp/rootfs.img
unsquashfs -d /usr/local/fcos-image/new-fs /usr/local/fcos-image/rootfs/root.squashfs
rm -rf /usr/local/fcos-image/new-fs/ostree/repo
mv /usr/local/fcos-image/os-content/srv/repo /usr/local/fcos-image/new-fs/ostree/repo
rm -f /usr/local/fcos-image/rootfs/root.squashfs
mksquashfs /usr/local/fcos-image/new-fs/ /usr/local/fcos-image/rootfs/root.squashfs -comp zstd
rm -rf /usr/local/fcos-image/new-fs/ /usr/local/fcos-image/os-content
ls /usr/local/fcos-image/rootfs > /usr/local/fcos-image/cpio.list
cpio -D /usr/local/fcos-image/rootfs --create < /usr/local/fcos-image/cpio.list > /usr/local/fcos-image/rootfs.img
EOF

${SCP} -i ~/.ssh/fcos -P ${FCOS_SSH_PORT} /tmp/createRootFs.sh core@localhost:/tmp/createRootFs.sh

${SSH} -i ~/.ssh/fcos -p ${FCOS_SSH_PORT} core@localhost "sudo chmod 755 /tmp/createRootFs.sh"
${SSH} -i ~/.ssh/fcos -p ${FCOS_SSH_PORT} core@localhost "sudo /tmp/createRootFs.sh"

${SCP} -i ~/.ssh/fcos -P ${FCOS_SSH_PORT} core@localhost:/usr/local/fcos-image/rootfs.img ${OKD_LAB_PATH}/ipxe-work-dir/fcos/okd4-sno-${SUB_DOMAIN}/bootstrap-rootfs.img 

# ${SSH} -i ~/.ssh/fcos -p ${FCOS_SSH_PORT} core@localhost "sudo podman pull -q ${OKD_RELEAE_IMAGE}"
# OS_CONTENT_IMAGE=$(${SSH} -i ~/.ssh/fcos -p ${FCOS_SSH_PORT} core@localhost  "sudo podman run --quiet --rm --net=none ${OKD_RELEAE_IMAGE} image machine-os-content")
# ${SSH} -i ~/.ssh/fcos -p ${FCOS_SSH_PORT} core@localhost "sudo podman pull -q ${OS_CONTENT_IMAGE}"
# CONTAINER_ID=$(${SSH} -i ~/.ssh/fcos -p ${FCOS_SSH_PORT} core@localhost "sudo podman create --net=none --name ostree-container ${OS_CONTENT_IMAGE}")

# ${SSH} -i ~/.ssh/fcos -p ${FCOS_SSH_PORT} core@localhost "sudo mkdir -p /usr/local/fcos-image/os-content && sudo podman cp ${CONTAINER_ID}:/ /usr/local/fcos-image/os-content"

# ${SCP} -i ~/.ssh/fcos -P ${FCOS_SSH_PORT} ${OKD_LAB_PATH}/ipxe-work-dir/fcos/okd4-sno-${SUB_DOMAIN}/rootfs.img core@localhost:/tmp/rootfs.img

# ${SSH} -i ~/.ssh/fcos -p ${FCOS_SSH_PORT} core@localhost "sudo mkdir -p /usr/local/fcos-image/rootfs && sudo cpio --extract -D /usr/local/fcos-image/rootfs < /tmp/rootfs.img"

# ${SSH} -i ~/.ssh/fcos -p ${FCOS_SSH_PORT} core@localhost "sudo unsquashfs -d /usr/local/fcos-image/new-fs /usr/local/fcos-image/rootfs/root.squashfs"

# ${SSH} -i ~/.ssh/fcos -p ${FCOS_SSH_PORT} core@localhost "sudo rm -rf /usr/local/fcos-image/new-fs/ostree/repo && sudo mv /usr/local/fcos-image/os-content/srv/repo /usr/local/fcos-image/new-fs/ostree/repo"

# ${SSH} -i ~/.ssh/fcos -p ${FCOS_SSH_PORT} core@localhost "sudo rm -f /usr/local/fcos-image/rootfs/root.squashfs && sudo mksquashfs /usr/local/fcos-image/new-fs/ /usr/local/fcos-image/rootfs/root.squashfs"

# ${SSH} -i ~/.ssh/fcos -p ${FCOS_SSH_PORT} core@localhost "sudo rm -rf /usr/local/fcos-image/new-fs/ /usr/local/fcos-image/os-content"

# ${SSH} -i ~/.ssh/fcos -p ${FCOS_SSH_PORT} core@localhost "sudo ls /usr/local/fcos-image/rootfs > /usr/local/fcos-image/cpio.list && sudo cpio -D /usr/local/fcos-image/rootfs --create < /usr/local/fcos-image/cpio.list > /usr/local/fcos-image/rootfs.img"

# ${SCP} -i ~/.ssh/fcos -P ${FCOS_SSH_PORT} core@localhost:/usr/local/fcos-image/rootfs.img ${OKD_LAB_PATH}/ipxe-work-dir/fcos/okd4-sno-${SUB_DOMAIN}/bootstrap-rootfs.img 

# podman machine stop fcos
# sleep 10
# podman machine rm --force fcos
