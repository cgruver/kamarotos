#!/bin/bash

EDGE=false
INDEX=""
CONFIG_FILE=${LAB_CONFIG_FILE}

for i in "$@"
do
  case ${i} in
    -e|--edge)
      EDGE=true
      shift
    ;;
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      shift
    ;;
    -d=*|--domain=*)
      SUB_DOMAIN="${i#*=}"
      shift
    ;;
    *)
          echo "USAGE: createEnvScript -e -c=path/to/config/file -d=sub-domain-name"
    ;;
  esac
done

EDGE_NETWORK=$(yq e ".network" ${CONFIG_FILE})
LAB_DOMAIN=$(yq e ".domain" ${CONFIG_FILE})
BASTION_HOST=$(yq e ".bastion-ip" ${CONFIG_FILE})
EDGE_ROUTER=$(yq e ".router" ${CONFIG_FILE})
EDGE_NETMASK=$(yq e ".netmask" ${CONFIG_FILE})

mkdir -p ${OKD_LAB_PATH}/work-dir

if [[ ${SUB_DOMAIN} != "" ]]
then
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
  ROUTER=$(yq e ".sub-domain-configs.[${INDEX}].router-ip" ${CONFIG_FILE})
  NETWORK=$(yq e ".sub-domain-configs.[${INDEX}].network" ${CONFIG_FILE})
  EDGE_IP=$(yq e ".sub-domain-configs.[${INDEX}].router-edge-ip" ${CONFIG_FILE})
  NETMASK=$(yq e ".sub-domain-configs.[${INDEX}].netmask" ${CONFIG_FILE})

IFS=. read -r i1 i2 i3 i4 << EOI
${ROUTER}
EOI
LB_IP=${i1}.${i2}.${i3}.$(( ${i4} + 1 ))

cat << EOF > ${OKD_LAB_PATH}/work-dir/internal-router
export EDGE_NETWORK=${EDGE_NETWORK}
export NETWORK=${NETWORK}
export NETMASK=${NETMASK}
export DOMAIN=${SUB_DOMAIN}.${LAB_DOMAIN}
export BASTION_HOST=${BASTION_HOST}
export EDGE_ROUTER=${EDGE_ROUTER}
export EDGE_IP=${EDGE_IP}
export ROUTER=${ROUTER}
export LB_IP=${LB_IP}
EOF

A=$( echo ${SUB_DOMAIN} | tr "[:lower:]" "[:upper:]" )
cat << EOF > ${OKD_LAB_PATH}/work-dir/edge-router-sub
export ${A}_ROUTER=${EDGE_IP}
export ${A}_NETWORK=${NETWORK}
EOF

cat << EOF > ${OKD_LAB_PATH}/work-dir/edge-zone
zone "${SUB_DOMAIN}.${LAB_DOMAIN}" {
    type stub;
    masters { ${ROUTER}; };
    file "stub.${SUB_DOMAIN}.${LAB_DOMAIN}";
};

EOF

fi



if [[ ${EDGE} == true ]]
then

cat << EOF > ${OKD_LAB_PATH}/work-dir/edge-router
export NETWORK=${EDGE_NETWORK}
export DOMAIN=${LAB_DOMAIN}
export BASTION_HOST=${BASTION_HOST}
export ROUTER=${EDGE_ROUTER}
export NETMASK=${EDGE_NETMASK}
EOF
fi






