#!/bin/bash

. ${OKD_LAB_PATH}/bin/labctx.env

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

CONFIG_FILE=${LAB_CONFIG_FILE}
PAUSE=60

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

if [[ -z ${SUB_DOMAIN} ]]
then
  labctx
fi
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

LAB_DOMAIN=$(yq e ".domain" ${CONFIG_FILE})
SUB_DOMAIN=$(yq e ".sub-domain-configs.[${INDEX}].name" ${CONFIG_FILE})
CLUSTER_CONFIG=$(yq e ".sub-domain-configs.[${INDEX}].cluster-config-file" ${CONFIG_FILE})
CLUSTER_NAME=$(yq e ".cluster.name" ${CLUSTER_CONFIG})
DOMAIN="${SUB_DOMAIN}.${LAB_DOMAIN}"
export KUBECONFIG="${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}.${DOMAIN}/kubeconfig"

ID=$(oc whoami)
if [[ ${ID} != "system:admin" ]]
then
  echo "ERROR: Invalid kube_config: ${KUBECONFIG}"
  exit 1
fi

if [[ $(yq e ".compute-nodes.metal" ${CLUSTER_CONFIG}) == "true" ]]
  then
    let NODE_COUNT=$(yq e ".compute-nodes.okd-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
  else
    let NODE_COUNT=$(yq e ".compute-nodes.kvm-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
fi

# Cordon Compute Nodes
let i=0
while [[ i -lt ${NODE_COUNT} ]]
do
  oc adm cordon okd4-worker-${i}.${DOMAIN}
  i=$(( ${i} + 1 ))
done

# Drain & Shutdown Compute Nodes
let i=0
while [[ i -lt ${NODE_COUNT} ]]
do
  oc adm drain okd4-worker-${i}.${DOMAIN} --ignore-daemonsets --force --grace-period=60 --delete-emptydir-data
  ${SSH} -o ConnectTimeout=5 core@okd4-worker-${i}.${DOMAIN} "sudo systemctl poweroff"
  i=$(( ${i} + 1 ))
done

# Shutdown Control Plane Nodes
echo "Sleep ${PAUSE} seconds, then shutdown Control Plane"
let pause=${PAUSE}
while [ ${pause} -gt 0 ]; do
   echo -ne "Giving Compute Nodes Time to Shutdown: ${pause}\033[0K\r"
   sleep 1
   : $((pause--))
done

for i in 0 1 2
do
  ${SSH} -o ConnectTimeout=5 core@okd4-master-${i}.${DOMAIN} "sudo systemctl poweroff"
done