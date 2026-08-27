# Scenario: A user may only delete a namespace they created.
#
# Gatekeeper records the creator in an annotation at CREATE time and verifies
# it at DELETE time. Deletes by any other user are denied.

# 0. Prerequisite: OPA Gatekeeper is installed (see ../commands.ps1).

# 1. Deploy the ConstraintTemplate
kubectl apply -f k8snamespaceowner_template.yaml

# 2. Deploy the Constraint
kubectl apply -f namespace_owner_constraint.yaml

# 3. IMPORTANT: allow Gatekeeper to intercept DELETE requests.
# By default the validating webhook only handles CREATE and UPDATE, so DELETE
# would never reach the policy. Add DELETE to the webhook's operations.
kubectl patch validatingwebhookconfiguration gatekeeper-validating-webhook-configuration `
  --type=json `
  -p='[{\"op\":\"add\",\"path\":\"/webhooks/0/rules/0/operations/-\",\"value\":\"DELETE\"}]'

# 4. Find the exact username you authenticate as, then use it in the annotation.
kubectl auth whoami

# 5. Create a namespace owned by another user -> allowed (annotation is honest).
kubectl apply -f alice-namespace.yaml

# 6. Create a namespace with no owner annotation -> DENIED.
kubectl apply -f no-owner-namespace.yaml

# 7. Try to delete a namespace you do NOT own -> DENIED.
kubectl delete namespace alice-ns

# 8. Create a namespace you own, then delete it -> allowed.
$me = kubectl auth whoami -o jsonpath='{.status.userInfo.username}'
kubectl create namespace mine-ns
kubectl annotate namespace mine-ns "namespace-owner=$me"
kubectl delete namespace mine-ns
