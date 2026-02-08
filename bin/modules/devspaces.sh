function devSpaces() {
  for j in "$@"
  do
    case $j in
      -i)
        deployDevSpacesOperator
      ;;
      -c)
        deployDevSpacesCluster
      ;;
      -o)
        createGitHubOauth
      ;;
      -g)
        createUserGitConfig
      ;;
    esac
  done
}

function deployDevSpacesOperator() {

cat << EOF | ${OC} apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: devspaces
  namespace: openshift-operators
spec:
  channel: stable 
  installPlanApproval: Manual
  name: devspaces 
  source: redhat-operators 
  sourceNamespace: openshift-marketplace 
EOF

}

function deployDevSpacesCluster() {

${OC} wait --for=condition=Available -n openshift-operators --timeout=300s --all deployments

echo "Enter the name of the StorageClass to use for PVCs:"
read STORAGE_CLASS

cat << EOF | ${OC} apply -f -
apiVersion: v1                      
kind: Namespace                 
metadata:
  name: devspaces
---           
apiVersion: org.eclipse.che/v2 
kind: CheCluster   
metadata:              
  name: devspaces  
  namespace: devspaces
spec:                         
  components:                  
    cheServer:      
      debug: false
      logLevel: INFO
    metrics:                
      enable: true
    pluginRegistry:
      openVSXURL: https://open-vsx.org
    devfileRegistry:
      disableInternalRegistry: true   
  containerRegistry: {}   
  devEnvironments:       
    startTimeoutSeconds: 300
    secondsOfRunBeforeIdling: -1
    maxNumberOfWorkspacesPerUser: -1
    maxNumberOfRunningWorkspacesPerUser: 5
    containerBuildConfiguration:
      openShiftSecurityContextConstraint: container-build
    disableContainerBuildCapabilities: false
    disableContainerRunCapabilities: false
    defaultComponents:
    - name: dev-tools
      container:
        image: quay.io/cgruver0/che/dev-tools:latest
        memoryLimit: 6Gi
        mountSources: true
    defaultEditor: che-incubator/che-code/latest
    defaultNamespace:
      autoProvision: true
      template: <username>-devspaces
    secondsOfInactivityBeforeIdling: 1800
    storage:
      pvcStrategy: per-workspace
      perUserStrategyPvcConfig:
        storageClass: ${STORAGE_CLASS}
      perWorkspaceStrategyPvcConfig:
        storageClass: ${STORAGE_CLASS}
  gitServices: {}
  networking: {}
EOF
}

function createGitHubOauth() {

  GitHub_OAuth_Client_ID=""
  GitHub_OAuth_Client_Secret="red"
  GitHub_OAuth_Client_Secret_CHK="green"
  echo "Enter the GitHub OAuth Client ID user for the pull secret:"
  read GitHub_OAuth_Client_ID
  while [[ ${GitHub_OAuth_Client_Secret} != ${GitHub_OAuth_Client_Secret_CHK} ]]
  do
    echo "Enter the GitHub Client Secret:"
    read -s GitHub_OAuth_Client_Secret
    echo "Re-Enter the GitHub Client Secret:"
    read -s GitHub_OAuth_Client_Secret_CHK
    if [[ ${GitHub_OAuth_Client_Secret} != ${GitHub_OAuth_Client_Secret_CHK} ]]
    then
      echo "Passwords do not match. Try Again."
    fi
  done

cat << EOF | ${OC} apply -f -
kind: Secret
apiVersion: v1
metadata:
  name: github-oauth-config
  namespace: devspaces 
  labels:
    app.kubernetes.io/part-of: che.eclipse.org
    app.kubernetes.io/component: oauth-scm-configuration
  annotations:
    che.eclipse.org/oauth-scm-server: github
    che.eclipse.org/scm-server-endpoint: https://github.com 
    che.eclipse.org/scm-github-disable-subdomain-isolation: 'false' 
type: Opaque
stringData:
  id: ${GitHub_OAuth_Client_ID} 
  secret: ${GitHub_OAuth_Client_Secret}
EOF
}

function createUserGitConfig() {

USER_NAMESPACE=""
USER_NAME=""
USER_EMAIL=""

echo "Enter your Dev Spaces Namespace:"
read USER_NAMESPACE
echo "Enter your Git userid:"
read USER_NAME
echo "Enter your email:"
read USER_EMAIL

cat << EOF | ${OC} apply -f -
kind: ConfigMap
apiVersion: v1
metadata:
  name: workspace-userdata-gitconfig-configmap
  namespace: ${USER_NAMESPACE} 
  labels:
    controller.devfile.io/mount-to-devworkspace: 'true'
    controller.devfile.io/watch-configmap: 'true'
  annotations:
    controller.devfile.io/mount-as: subpath
    controller.devfile.io/mount-path: /etc/
data:
  gitconfig: |-
    [user]
      name = ${USER_NAME}
      email = ${USER_EMAIL}
EOF
}