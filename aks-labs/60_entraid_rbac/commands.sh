#!/bin/bash
# EntraID Group RBAC on Private AKS — manual reference commands
# These mirror what the GitLab pipeline does; useful for local testing.

set -euo pipefail

# ─── Variables ────────────────────────────────────────────────────────────────
AKS_RG="rg-aks-private"
AKS_NAME="aks-private-cluster"
NAMESPACE="maestro-admins"
ENTRA_GROUP_NAME="maestro-admins"
TEST_USER_EMAIL="manoutechconsulting@gmail.com"

# ─── 0. Create the EntraID group (idempotent) ────────────────────────────────
# Creates the group if it does not already exist, then fetches its Object ID.
if ! az ad group show --group "$ENTRA_GROUP_NAME" &>/dev/null; then
  az ad group create \
    --display-name "$ENTRA_GROUP_NAME" \
    --mail-nickname "$ENTRA_GROUP_NAME"
  echo "Created EntraID group: $ENTRA_GROUP_NAME"
else
  echo "EntraID group already exists: $ENTRA_GROUP_NAME"
fi

ENTRAID_GROUP_OBJECT_ID=$(az ad group show --group "$ENTRA_GROUP_NAME" --query id -o tsv)
echo "EntraID Group Object ID: $ENTRAID_GROUP_OBJECT_ID"

# ─── 1. Add test user to the group ───────────────────────────────────────────
USER_OBJECT_ID=$(az ad user show --id "$TEST_USER_EMAIL" --query id -o tsv)
echo "User Object ID: $USER_OBJECT_ID"

az ad group member add \
  --group "$ENTRAID_GROUP_OBJECT_ID" \
  --member-id "$USER_OBJECT_ID"
echo "Added $TEST_USER_EMAIL to group $ENTRA_GROUP_NAME"

# ─── 2. Pre-requisite: AKS must be created with AAD + Azure RBAC enabled ──────
# Private cluster + AAD integration + Kubernetes RBAC (not Azure RBAC)
az aks create \
  --resource-group "$AKS_RG" \
  --name "$AKS_NAME" \
  --enable-aad \
  --aad-admin-group-object-ids "$ENTRAID_GROUP_OBJECT_ID" \
  --enable-private-cluster \
  --network-plugin azure \
  --node-count 2 \
  --zones 1 2 3

# ─── 3. Authenticate to the private cluster ───────────────────────────────────
# For a private cluster you must run this from inside the VNet (jump box, CI runner in VNet, etc.)
az aks get-credentials --resource-group "$AKS_RG" --name "$AKS_NAME" --overwrite-existing

# ─── 4. Apply manifests ───────────────────────────────────────────────────────
kubectl apply -f manifests/namespace.yaml

kubectl apply -f manifests/role.yaml

# Substitute the group Object ID before applying
ENTRAID_GROUP_OBJECT_ID="$ENTRAID_GROUP_OBJECT_ID" \
  envsubst < manifests/rolebinding.yaml | kubectl apply -f -

# ─── 5. Verify RBAC ──────────────────────────────────────────────────────────
kubectl get role,rolebinding -n "$NAMESPACE"

# Check what the group can do in the namespace
kubectl auth can-i --list \
  --namespace="$NAMESPACE" \
  --as-group="$ENTRAID_GROUP_OBJECT_ID" \
  --as=dummy-user

# Spot-check specific verbs
kubectl auth can-i create pods     -n "$NAMESPACE" --as-group="$ENTRAID_GROUP_OBJECT_ID" --as=dummy-user
kubectl auth can-i create services -n "$NAMESPACE" --as-group="$ENTRAID_GROUP_OBJECT_ID" --as=dummy-user
kubectl auth can-i create secrets  -n "$NAMESPACE" --as-group="$ENTRAID_GROUP_OBJECT_ID" --as=dummy-user

# ─── 6. End-to-end test — user IS a group member (should succeed) ─────────────
# Run these as the test user after authenticating with their credentials:
#   az aks get-credentials -g $AKS_RG -n $AKS_NAME
#   kubectl create deployment nginx --image=nginx -n maestro-admins   # succeeds
#   kubectl get pods -n maestro-admins                                 # succeeds
#   kubectl create secret generic mysecret --from-literal=key=val \
#     -n maestro-admins                                                # succeeds
#   kubectl get pods -n default                                        # FORBIDDEN

# ─── 7. Remove user from group — revoke access ───────────────────────────────
az ad group member remove \
  --group "$ENTRAID_GROUP_OBJECT_ID" \
  --member-id "$USER_OBJECT_ID"
echo "Removed $TEST_USER_EMAIL from group $ENTRA_GROUP_NAME"

# ─── 8. Verify revoked access ────────────────────────────────────────────────
# EntraID token caches mean revocation may take up to 60-90 minutes to fully
# propagate. Force a fresh token to see the effect immediately:
#   az account clear && az login
# Then re-run as the test user — all operations should now be FORBIDDEN:
#   kubectl get pods -n maestro-admins                   # FORBIDDEN
#   kubectl create deployment nginx --image=nginx \
#     -n maestro-admins                                  # FORBIDDEN
#   kubectl create secret generic mysecret \
#     --from-literal=key=val -n maestro-admins           # FORBIDDEN

# Confirm via impersonation (using the user's Object ID as the subject):
kubectl auth can-i create pods     -n "$NAMESPACE" --as="$USER_OBJECT_ID"
kubectl auth can-i create services -n "$NAMESPACE" --as="$USER_OBJECT_ID"
kubectl auth can-i get pods        -n "$NAMESPACE" --as="$USER_OBJECT_ID"

# ─── Clean up ─────────────────────────────────────────────────────────────────
# az group delete -n "$AKS_RG" --yes --no-wait
