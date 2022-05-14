function trustClusterCert() {
  SYS_ARCH=$(uname)
  if [[ ${SYS_ARCH} == "Darwin" ]]
  then
    openssl s_client -showcerts -connect  console-openshift-console.apps.${CLUSTER_NAME}.${SUB_DOMAIN}.${LAB_DOMAIN}:443 </dev/null 2>/dev/null|openssl x509 -outform PEM > /tmp/okd-console.${SUB_DOMAIN}.${LAB_DOMAIN}.crt
    sudo security add-trusted-cert -d -r trustAsRoot -k "/Library/Keychains/System.keychain" /tmp/okd-console.${SUB_DOMAIN}.${LAB_DOMAIN}.crt
  elif [[ ${SYS_ARCH} == "Linux" ]]
  then
    sudo openssl s_client -showcerts -connect console-openshift-console.apps.${CLUSTER_NAME}.${SUB_DOMAIN}.${LAB_DOMAIN}:443 </dev/null 2>/dev/null|openssl x509 -outform PEM > /etc/pki/ca-trust/source/anchors/okd-console.${SUB_DOMAIN}.${LAB_DOMAIN}.crt
    sudo update-ca-trust
  else
    echo "Unsupported OS: Cannot trust openshift cert"
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

function resetNic() {
  SYS_ARCH=$(uname)
  if [[ ${SYS_ARCH} == "Darwin" ]]
  then
    bridge_dev=$(yq e ".bootstrap.bridge-dev" ${CLUSTER_CONFIG})
    sudo launchctl unload -w "/Library/LaunchDaemons/io.github.lima-vm.vde_vmnet.bridged.${bridge_dev}.plist"
    sudo launchctl unload -w "/Library/LaunchDaemons/io.github.virtualsquare.vde-2.vde_switch.bridged.${bridge_dev}.plist"
    sudo launchctl unload -w "/Library/LaunchDaemons/io.github.lima-vm.vde_vmnet.plist"
    sudo launchctl unload -w "/Library/LaunchDaemons/io.github.virtualsquare.vde-2.vde_switch.plist"
    sudo launchctl load -w "/Library/LaunchDaemons/io.github.virtualsquare.vde-2.vde_switch.plist"
    sudo launchctl load -w "/Library/LaunchDaemons/io.github.lima-vm.vde_vmnet.plist"
    sudo launchctl load -w "/Library/LaunchDaemons/io.github.virtualsquare.vde-2.vde_switch.bridged.${bridge_dev}.plist"
    sudo launchctl load -w "/Library/LaunchDaemons/io.github.lima-vm.vde_vmnet.bridged.${bridge_dev}.plist"
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
