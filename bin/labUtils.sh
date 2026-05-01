function trustCerts() {

  for i in "$@"
  do
    case ${i} in
      -c)
        CERT_URL=console-openshift-console.apps.${CLUSTER_NAME}.${DOMAIN}:443
        CERT_NAME=openshift-console.${DOMAIN}.crt
        trustCert ${CERT_URL} ${CERT_NAME} root ""
        CERT_URL=api.${CLUSTER_NAME}.${DOMAIN}:6443
        CERT_NAME=openshift-api.${DOMAIN}.crt
        trustCert ${CERT_URL} ${CERT_NAME} root "-servername api.${CLUSTER_NAME}.${DOMAIN}"
      ;;
      -n)
        CERT_URL=nexus.${LAB_DOMAIN}:8443
        CERT_NAME=nexus.${LAB_DOMAIN}.crt
        trustCert ${CERT_URL} ${CERT_NAME} na ""
      ;;
      -g)
        CERT_URL=gitea.${LAB_DOMAIN}:3000
        CERT_NAME=gitea.${LAB_DOMAIN}.crt
        trustCert ${CERT_URL} ${CERT_NAME} na ""
      ;;
      -k)
        CERT_URL=keycloak.${LAB_DOMAIN}:7443
        CERT_NAME=keycloak.${LAB_DOMAIN}.crt
        trustCert ${CERT_URL} ${CERT_NAME} na ""
      ;;
      -a)
        CERT_URL=apicurio.${LAB_DOMAIN}:9443
        CERT_NAME=apicurio.${LAB_DOMAIN}.crt
        trustCert ${CERT_URL} ${CERT_NAME} na ""
      ;;
    esac
  done
}

function trustCert() {

  local url=${1}
  local cert_name=${2}
  local cert_type=${3}
  local sni_fix=${4}
  CERT_CMD=trustRoot

  if [[ ${cert_type} == "root" ]]
  then
    CERT_CMD=trustAsRoot
  fi
  SYS_ARCH=$(uname)
  if [[ ${SYS_ARCH} == "Darwin" ]]
  then
    openssl s_client -showcerts ${sni_fix} -connect ${url} </dev/null 2>/dev/null|openssl x509 -outform PEM > /tmp/${cert_name}
    sudo security add-trusted-cert -d -r ${CERT_CMD} -k "/Library/Keychains/System.keychain" /tmp/${cert_name}
  elif [[ ${SYS_ARCH} == "Linux" ]]
  then
    sudo openssl s_client -showcerts ${sni_fix} -connect ${url} </dev/null 2>/dev/null|openssl x509 -outform PEM > /tmp/${cert_name}
    sudo mv /tmp/${cert_name} /etc/pki/ca-trust/source/anchors/${cert_name}
    sudo update-ca-trust
  else
    echo "Unsupported OS: Cannot trust cert with this utility"
  fi
}

function noInternet() {
  ${SSH} root@router.${LAB_DOMAIN} "new_rule=\$(uci add firewall rule) ; \
    uci set firewall.\${new_rule}.enabled=1 ; \
    uci set firewall.\${new_rule}.target=REJECT ; \
    uci set firewall.\${new_rule}.src=lan ; \
    uci set firewall.\${new_rule}.src_ip=${DOMAIN_NETWORK}/24 ; \
    uci set firewall.\${new_rule}.dest=wan ; \
    uci set firewall.\${new_rule}.name=${SUB_DOMAIN}-internet-deny ; \
    uci set firewall.\${new_rule}.proto=all ; \
    uci set firewall.\${new_rule}.family=ipv4 ; \
    uci commit firewall && \
    /etc/init.d/firewall restart"
}

function restoreInternet() {
  local fw_index=$(${SSH} root@router.${LAB_DOMAIN} "uci show firewall" | grep ${SUB_DOMAIN}-internet-deny | cut -d"[" -f2 | cut -d "]" -f1)
  if [[ ! -z ${fw_index} ]] && [[ ${fw_index} != 0 ]]
  then
    ${SSH} root@router.${LAB_DOMAIN} "uci delete firewall.@rule[${fw_index}] ; \
      uci commit firewall ; \
      /etc/init.d/firewall restart"
  fi
}

function resetDns() {
  SYS_ARCH=$(uname)
  if [[ ${SYS_ARCH} == "Darwin" ]]
  then
    sudo killall -HUP mDNSResponder
  else
    echo "Unsupported OS: Cannot reset DNS"
    exit 1
  fi
}

function pause() {
  let pause=${1}
  MSG=${2}

  while [ ${pause} -gt 0 ]; do
    echo -ne "${2}: ${pause}\033[0K\r"
    sleep 1
    : $((pause--))
  done
}

function startWorker() {

  STAGGER="false"

  for i in "$@"
  do
    case $i in
      -s)
        STAGGER="true"
      ;;
    esac
  done

  let node_count=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    host_name=$(yq e ".compute-nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    local mac=$(yq e ".compute-nodes.[${node_index}].mac-addr" ${CLUSTER_CONFIG})
    startNode ${mac}
    if [[ ${node_index} -gt 0 ]] && [[ ${STAGGER} == "true" ]]
    then
      pause 30 "Pause to stagger node start up"
    fi
    node_index=$(( ${node_index} + 1 ))
  done
}

function stopWorkers() {
  
  let node_count=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)

  # Cordon Compute Nodes
  ${OC} adm cordon -l node-role.kubernetes.io/worker=""

  CEPH_PDB="false"
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    node_index=$(( ${node_index} + 1 ))
    if [[ $(yq ".compute-nodes.[${node_index}] | has(\"ceph\")" ${CLUSTER_CONFIG}) == "true" ]]
    then
      CEPH_PDB="true"
    fi
  done
  if [[ ${CEPH_PDB} == "true" ]]
  then
    ${OC} scale deployment rook-ceph-operator -n rook-ceph --replicas=0
    ${OC} patch pdb rook-ceph-mgr-pdb -n rook-ceph --type=merge -p '{"spec":{"maxUnavailable":"100%"}}'
    ${OC} patch pdb rook-ceph-mon-pdb -n rook-ceph --type=merge -p '{"spec":{"maxUnavailable":"100%"}}'
    ${OC} patch pdb rook-ceph-osd -n rook-ceph --type=merge -p '{"spec":{"maxUnavailable":"100%"}}'
  fi
  # Drain & Shutdown Compute Nodes
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    host_name=$(yq e ".compute-nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    ${OC} adm drain ${host_name} --ignore-daemonsets --force --grace-period=20 --delete-emptydir-data
    ${SSH} -o ConnectTimeout=5 core@${host_name}.${DOMAIN} "sudo systemctl poweroff"
    node_index=$(( ${node_index} + 1 ))
  done
}

function deleteWorker() {
  local index=${1}
  local p_cmd=${2}

  host_name=$(yq e ".compute-nodes.[${index}].name" ${CLUSTER_CONFIG})
  mac_addr=$(yq e ".control-plane.nodes.[${index}].mac-addr" ${CLUSTER_CONFIG})
  boot_dev=$(yq e ".compute-nodes.[${index}].boot-dev" ${CLUSTER_CONFIG})
  ceph_dev=$(yq e ".compute-nodes.[${index}].ceph.ceph-dev" ${CLUSTER_CONFIG})
  destroyNode core ${host_name} ${boot_dev} "${ceph_dev}" ${p_cmd}
  deleteDns ${host_name}-${DOMAIN}
  deletePxeConfig ${mac_addr}
}

function unCordonNode() {

  ${OC} adm uncordon -l node-role.kubernetes.io/master=""
  ${OC} adm uncordon -l node-role.kubernetes.io/worker=""
  
  CEPH_PDB="false"
  let node_index=0
  while [[ node_index -lt ${node_count} ]]
  do
    node_index=$(( ${node_index} + 1 ))
    if [[ $(yq ".compute-nodes.[${node_index}] | has(\"ceph\")" ${CLUSTER_CONFIG}) == "true" ]]
    then
      CEPH_PDB="true"
    fi
  done
  if [[ ${CEPH_PDB} == "true" ]]
  then
    ${OC} scale deployment rook-ceph-operator -n rook-ceph --replicas=1
    ${OC} patch pdb rook-ceph-mgr-pdb -n rook-ceph --type=merge -p '{"spec":{"maxUnavailable":1}}'
    ${OC} patch pdb rook-ceph-mon-pdb -n rook-ceph --type=merge -p '{"spec":{"maxUnavailable":1}}'
    ${OC} patch pdb rook-ceph-osd -n rook-ceph --type=merge -p '{"spec":{"maxUnavailable":1}}'
  fi
}

function stopCluster() {
  ${OC} patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Removed"}}'
  node_count=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  if [[ ${node_count} -gt 0 ]]
  then
    stopWorkers
    pause 60 "Giving Compute Nodes Time to Shutdown"
  fi
  stopControlPlane
}

function addUser() {
  
  for i in "$@"
  do
    case $i in
      -a|--admin)
        ADMIN_USER="true"
      ;;
      -i|--init)
        OAUTH_INIT="true"
      ;;
      -u=*)
        USER="${i#*=}"
      ;;
      *)
        # catch all
      ;;
    esac
  done
  PWD_WORK_DIR=$(mktemp -d)
  PASSWD_FILE=${PWD_WORK_DIR}/htpasswd
  if [[ ${OAUTH_INIT} == "true" ]]
  then
    touch ${PASSWD_FILE}
  else
    ${OC} get secret openshift-htpasswd-secret -n openshift-config -o jsonpath='{.data.htpasswd}' | base64 -d > ${PASSWD_FILE}
  fi
  if [[ -z ${USER} ]]
  then
    echo "Usage: labcli --user [ -a | --admin ] -u=user-name-to-add"
    exit 1
  fi
  htpasswd -B ${PASSWD_FILE} ${USER}
  ${OC} create -n openshift-config secret generic openshift-htpasswd-secret --from-file=htpasswd=${PASSWD_FILE} -o yaml --dry-run='client' | ${OC} apply -f -
  if [[ ${ADMIN_USER} == "true" ]]
  then
    ${OC} adm policy add-cluster-role-to-user cluster-admin ${USER}
  fi
  if [[ ${OAUTH_INIT} == "true" ]]
  then
    ${OC} patch oauth cluster --type merge --patch '{"spec":{"identityProviders":[{"name":"openshift_htpasswd_idp","mappingMethod":"claim","type":"HTPasswd","htpasswd":{"fileData":{"name":"openshift-htpasswd-secret"}}}]}}'
    ${OC} delete secrets kubeadmin -n kube-system
  fi
  rm -rf ${PWD_WORK_DIR}
}

function setKubeConfig() {
  export KUBECONFIG=${KUBE_INIT_CONFIG}
}

function approveCsr() {
    ${OC} get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs ${OC} adm certificate approve
}

function getButaneRelease() {

  BUTANE_VERSION=$(basename $(curl -Ls -o /dev/null -w %{url_effective} https://github.com/coreos/butane/releases/latest))
  echo "Butane Release: ${BUTANE_VERSION}"
  yq e ".cluster.butane-version = \"${BUTANE_VERSION}\"" -i ${CLUSTER_CONFIG}
  setButaneRelease
}

function ocLogin() {

  USER=admin
  
  for i in "$@"
  do
    case $i in
      -u=*)
        USER="${i#*=}"
      ;;
      -a)
        LOGIN_ALL="true"
      ;;
    esac
  done
  if [[ ${LOGIN_ALL} == "true" ]]
  then
    DOMAIN_COUNT=$(yq e ".sub-domain-configs" ${LAB_CONFIG_FILE} | yq e 'length' -)
    let DOMAIN_INDEX=0
    while [[ ${DOMAIN_INDEX} -lt ${DOMAIN_COUNT} ]]
    do
      labctx $(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].name" ${LAB_CONFIG_FILE})
      oc login -u ${USER} https://api.${CLUSTER_NAME}.${DOMAIN}:6443
      DOMAIN_INDEX=$(( ${DOMAIN_INDEX} + 1 ))
    done
  else
    oc login -u ${USER} https://api.${CLUSTER_NAME}.${DOMAIN}:6443
  fi
}

function ocConsole() {

  CONSOLE_ALL="false"
  SYS_ARCH=$(uname)
  if [[ ${SYS_ARCH} != "Darwin" ]]
  then
    echo "Unsupported OS: This function currently supports Darwin OS only"
    exit 1
  fi

  for i in "$@"
  do
    case $i in
      -a)
        CONSOLE_ALL="true"
      ;;
    esac
  done

  if [[ ${CONSOLE_ALL} == "true" ]]
  then
    DOMAIN_COUNT=$(yq e ".sub-domain-configs" ${LAB_CONFIG_FILE} | yq e 'length' -)
    let DOMAIN_INDEX=0
    while [[ ${DOMAIN_INDEX} -lt ${DOMAIN_COUNT} ]]
    do
      labctx $(yq e ".sub-domain-configs.[${DOMAIN_INDEX}].name" ${LAB_CONFIG_FILE})
      open -a Safari https://console-openshift-console.apps.${CLUSTER_NAME}.${DOMAIN}
      DOMAIN_INDEX=$(( ${DOMAIN_INDEX} + 1 ))
    done
    EDGE_CLUSTER_COUNT=$(yq e ".cluster-configs" ${LAB_CONFIG_FILE} | yq e 'length' -)
    let EDGE_CLUSTER_INDEX=0
    while [[ ${EDGE_CLUSTER_INDEX} -lt ${EDGE_CLUSTER_COUNT} ]]
    do
      labctx $(yq e ".cluster-configs.[${EDGE_CLUSTER_INDEX}].name" ${LAB_CONFIG_FILE})
      open -a Safari https://console-openshift-console.apps.${CLUSTER_NAME}.${DOMAIN}
      EDGE_CLUSTER_INDEX=$(( ${EDGE_CLUSTER_INDEX} + 1 ))
    done
  else
    open -a Safari https://console-openshift-console.apps.${CLUSTER_NAME}.${DOMAIN}
  fi
}

function startNode() {
  local mac=${1}
  ${SSH} root@${DOMAIN_ROUTER} "etherwake -i br-lan ${mac}"
}

function startControlPlane() {

  STAGGER="false"

  for i in "$@"
  do
    case $i in
      -s)
        STAGGER="true"
      ;;
    esac
  done

  if [[ $(yq e ".control-plane.nodes" ${CLUSTER_CONFIG} | yq e 'length' -) == "1" ]]
  then
    local mac=$(yq e ".control-plane.nodes.[0].mac-addr" ${CLUSTER_CONFIG})
    startNode ${mac}
  else
    for node_index in 0 1 2
    do
      if [[ ${node_index} -gt 0 ]] && [[ ${STAGGER} == "true" ]]
      then
        pause 30 "Pause to stagger node start up"
      fi
      local mac=$(yq e ".control-plane.nodes.[${node_index}].mac-addr" ${CLUSTER_CONFIG})
      startNode ${mac}
    done
  fi
}

function stopControlPlane() {

  ${OC} adm cordon -l node-role.kubernetes.io/master=""
  let node_count=$(yq e ".control-plane.nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let node_index=0
  while [[ ${node_index} -lt ${node_count} ]]
  do
    host_name=$(yq e ".control-plane.nodes.[${node_index}].name" ${CLUSTER_CONFIG})
    ${SSH} -o ConnectTimeout=5 core@${host_name}.${DOMAIN} "sudo systemctl poweroff"
    node_index=$(( ${node_index} + 1 ))
  done
}

function start() {
  for i in "$@"
  do
    case $i in
      -c)
        startControlPlane "$@"
        startWorker "$@"
      ;;
      -m)
        startControlPlane "$@"
      ;;
      -w)
        startWorker "$@"
      ;;
      -u)
        unCordonNode
      ;;
      -i)
        ${OC} patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed"}}'
      ;;
      *)
        # catch all
      ;;
    esac
  done
}

function monitor() {

  for i in "$@"
  do
    case $i in
      -b)
        openshift-install agent wait-for bootstrap-complete --dir=${OPENSHIFT_LAB_PATH}/${CLUSTER_NAME}.${DOMAIN}/openshift-install-dir --log-level debug
      ;;
      -i)
        openshift-install agent wait-for install-complete --dir=${OPENSHIFT_LAB_PATH}/${CLUSTER_NAME}.${DOMAIN}/openshift-install-dir --log-level debug
      ;;
      -m=*)
        CP_INDEX="${i#*=}"
        host_name=$(yq e ".control-plane.nodes.[${CP_INDEX}].name" ${CLUSTER_CONFIG})
        ${SSH} core@${host_name}.${DOMAIN} "journalctl -b -f"
      ;;
      -w=*)
        W_INDEX="${i#*=}"
        host_name=$(yq e ".compute-nodes.[${W_INDEX}].name" ${CLUSTER_CONFIG})
        ${SSH} core@${host_name}.${DOMAIN} "journalctl -b -f"
      ;;
      -s)
        host_name=$(yq e ".control-plane.nodes.[0].name" ${CLUSTER_CONFIG})
        ${SSH} core@${host_name}.${DOMAIN} "journalctl -b -f -u release-image.service -u release-image-pivot.service"
      ;;
      *)
        # catch all
      ;;
    esac
  done
}

function stop() {
  for i in "$@"
  do
    case $i in
      -c|--cluster)
        stopCluster
      ;;
      -w|--worker)
        stopWorkers
      ;;
      *)
        # catch all
      ;;
    esac
  done
}

function getNodes() {

  for j in "$@"
  do
    case $j in
      -cp)
        YQ_PATH="control-plane.nodes"
        let NODE_COUNT=$(yq e ".control-plane.nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
      ;;
      -cn)
        YQ_PATH="compute-nodes"
        let NODE_COUNT=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
      ;;
    esac
  done
  
  let node_index=0
  while [[ node_index -lt ${NODE_COUNT} ]]
  do
    node_name=$(yq e ".${YQ_PATH}.[${node_index}].name" ${CLUSTER_CONFIG}).${DOMAIN}
    echo ${node_name}
    node_index=$(( ${node_index} + 1 ))
  done

}

function keyCloak() {

  KEYCLOAK_REALM=$(yq e ".cluster.keycloak-realm" ${CLUSTER_CONFIG})

  KEYCLOAK_CLIENT_SECRET="red"
  KEYCLOAK_CLIENT_SECRET_CHK="green"
  while [[ ${KEYCLOAK_CLIENT_SECRET} != ${KEYCLOAK_CLIENT_SECRET_CHK} ]]
  do
    echo "Enter the Clent Secret for the Keycloak Client:"
    read -s KEYCLOAK_CLIENT_SECRET
    echo "Re-Enter the Clent Secret for the Keycloak Client:"
    read -s KEYCLOAK_CLIENT_SECRET_CHK
    if [[ ${KEYCLOAK_CLIENT_SECRET} != ${KEYCLOAK_CLIENT_SECRET_CHK} ]]
    then
      echo "Clent Secrets do not match. Try Again."
    fi
  done

  ${OC} create -n openshift-config secret generic keycloak-client-secret --from-literal=clientSecret=${KEYCLOAK_CLIENT_SECRET} -o yaml --dry-run='client' | ${OC} apply -f -

  openssl s_client -showcerts -connect keycloak.${LAB_DOMAIN}:7443 </dev/null 2>/dev/null|openssl x509 -outform PEM > /tmp/ca.crt
  ${OC} create -n openshift-config configmap keycloak-ca --from-file=ca.crt=/tmp/ca.crt -o yaml --dry-run='client' | ${OC} apply -f -

  ${OC} patch oauth cluster --type merge --patch "{\"spec\":{\"identityProviders\":[{\"mappingMethod\":\"claim\",\"name\":\"keycloak\",\"openID\":{\"ca\":{\"name\":\"keycloak-ca\"},\"claims\":{\"email\":[\"email\"],\"groups\":[\"groups\"],\"name\":[\"name\"],\"preferredUsername\":[\"preferred_username\"]},\"clientID\":\"ocp-${CLUSTER_NAME}\",\"clientSecret\":{\"name\":\"keycloak-client-secret\"},\"extraScopes\":[],\"issuer\":\"https://keycloak.${LAB_DOMAIN}:7443/realms/${KEYCLOAK_REALM}\"},\"type\":\"OpenID\"}]}}"
  ${OC} patch console cluster --type merge --patch "{\"spec\":{\"authentication\":{\"logoutRedirect\":\"https://keycloak.${LAB_DOMAIN}:7443/realms/${KEYCLOAK_REALM}/protocol/openid-connect/logout?post_logout_redirect_uri=https://console-openshift-console.apps.${CLUSTER_NAME}.${LAB_DOMAIN}&client_id=ocp-${CLUSTER_NAME}\"}}}"
  ${OC} adm policy add-cluster-role-to-group cluster-admin lab-admin

}

function deployGitOps() {
  ${OC} create ns openshift-gitops-operator
  ${OC} label namespace openshift-gitops-operator openshift.io/cluster-monitoring=true

cat << EOF | ${OC} apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  channel: latest 
  installPlanApproval: Manual
  name: openshift-gitops-operator 
  source: redhat-operators 
  sourceNamespace: openshift-marketplace 
EOF

}
