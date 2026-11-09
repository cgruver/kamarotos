function deployCertManagerOperator() {

cat << EOF | ${OC} apply -f -
apiVersion: v1                      
kind: Namespace                 
metadata:
  name: cert-manager-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
  - cert-manager-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

echo "Waiting for CertManager CSV to install..."
until CSV=$(${OC} get csv -n cert-manager-operator --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep cert-manager-operator | head -1) && \
      [ -n "${CSV}" ] && \
      [ "$(${OC} get csv ${CSV} -n cert-manager-operator -o jsonpath='{.status.phase}' 2>/dev/null)" = "Succeeded" ]; do
  echo "  ...CSV not ready yet"
  sleep 2
done

echo "CSV ${CSV} succeeded."

pause 15 "Wait for Cert Manager"

}