function usage() {

  for i in "$@"
  do
    case $i in
      header)
      usageHeader
      ;;
      --pi)
        configPiHelp
      ;;
      --router)
        configRouterHelp
      ;;
      --disconnect)
        noInternetHelp
      ;;
      --connect)
        restoreInternetHelp
      ;;
      --deploy)
        deployHelp
      ;;
      --destroy)
        destroyHelp
      ;;
      --start)
        startHelp
      ;;
      --stop)
        stopHelp
      ;;
      --user)
        addUserHelp
      ;;
      --trust)
        trustCertsHelp
      ;;
      --config-infra)
        configInfraNodesHelp
      ;;
      --csr)
        approveCsrHelp
      ;;
      --pull-secret)
        pullSecretHelp
      ;;
      --git-secret)
        gitSecretHelp
      ;;
      --butane)
        getButaneReleaseHelp
      ;;
      --console)
        ocConsoleHelp
      ;;
      --login)
        ocLoginHelp
      ;;
      --cli)
        getOkdCmdsHelp
      ;;
      --dns)
        resetDnsHelp
      ;;
      --mirror)
        mirrorOkdReleaseHelp
      ;;
      --kube)
        setKubeConfigHelp
      ;;
      --ceph)
        initCephVarsHelp
      ;;
      --monitor)
        monitorHelp
      ;;
      --post)
        postInstallHelp
      ;;
      --reset-nic)
        resetNicHelp
      ;;
      --nodes)
        getNodesHelp
      ;;
      --dev-tools)
        devToolsHelp
      ;;
      --kvm-pwd)
        createHostPwdHelp
      ;;
      --hostpath)
        deploySnoHostPathHelp
      ;;
      *)
        echo "unknown option ${i}"
        usage "header"
      ;;
    esac
  done
}

function usageHeader() {
  
  echo "WIP"

}