#!/usr/bin/env bash
#
# deploy-aks-argocd.sh
#
# Replicates the steps in Readme.md:
#   1. Create an AKS cluster (in Canada Central).
#   2. Install ArgoCD into the cluster and expose it via a LoadBalancer.
#   3. Deploy the ArgoCD project (project-argocd.yaml) and the sample Helm
#      application (app-argocd.yaml) through ArgoCD.
#   4. (Optional) Clean up all created Azure resources.
#
# Usage:
#   ./deploy-aks-argocd.sh            # provision everything
#   ./deploy-aks-argocd.sh cleanup    # delete the resource group (prompts)
#   FORCE=true ./deploy-aks-argocd.sh cleanup   # delete without prompting
#
# Requirements: az, kubectl (and an already 'az login'-ed session).

set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration (override any of these via environment variables)
# ----------------------------------------------------------------------------
LOCATION="${LOCATION:-canadacentral}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aks-cluster}"
# Kubernetes version. Leave empty to let AKS choose its default supported
# version for the region. The README's 1.32.0 is LTS-only and not accepted
# on a standard cluster, so it is no longer pinned by default.
CLUSTER_NAME="${CLUSTER_NAME:-aks-cluster}"
K8S_VERSION="${K8S_VERSION:-}"
# General-purpose node size. The README's standard_d2ads_v5 (DADSv5 family)
# has zero quota in canadacentral, so default to a standard general-purpose
# size (DSv3 family) that has quota. Override via NODE_VM_SIZE if needed.
NODE_VM_SIZE="${NODE_VM_SIZE:-Standard_D2s_v3}"

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
# Application namespace. Matches the destination namespace in app-argocd.yaml.
APP_NAMESPACE="${APP_NAMESPACE:-app02}"
ARGOCD_MANIFEST="${ARGOCD_MANIFEST:-https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml}"

# Paths to the ArgoCD manifests (default to the ones next to this script).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_MANIFEST="${PROJECT_MANIFEST:-$SCRIPT_DIR/project-argocd.yaml}"
APP_MANIFEST="${APP_MANIFEST:-$SCRIPT_DIR/app-argocd.yaml}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# ----------------------------------------------------------------------------
# 0. Preflight
# ----------------------------------------------------------------------------
for bin in az kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is not installed." >&2; exit 1; }
done

if ! az account show >/dev/null 2>&1; then
  echo "ERROR: Not logged in to Azure. Run 'az login' first." >&2
  exit 1
fi

# ----------------------------------------------------------------------------
# Cleanup: delete all Azure resources created by this script.
# Runs when invoked with 'cleanup'/'--cleanup' or CLEANUP=true, then exits.
# ----------------------------------------------------------------------------
cleanup() {
  log "Cleaning up Azure resources"

  if ! az group show -n "$RESOURCE_GROUP" >/dev/null 2>&1; then
    echo "Resource group '$RESOURCE_GROUP' does not exist. Nothing to clean up."
    return 0
  fi

  if [ "${FORCE:-false}" != "true" ]; then
    read -r -p "This will DELETE resource group '$RESOURCE_GROUP' and everything in it. Continue? (y/N) " reply
    case "$reply" in
      y|Y|yes|YES) ;;
      *) echo "Aborted."; return 0 ;;
    esac
  fi

  log "Deleting resource group '$RESOURCE_GROUP'"
  az group delete -n "$RESOURCE_GROUP" --yes --no-wait
  echo "Deletion of '$RESOURCE_GROUP' started (running asynchronously)."

  # Remove the cluster's kubeconfig context so stale entries don't linger.
  kubectl config delete-context "$CLUSTER_NAME" >/dev/null 2>&1 || true
}

case "${1:-}" in
  cleanup|--cleanup|-c)
    cleanup
    exit 0
    ;;
esac

if [ "${CLEANUP:-false}" = "true" ]; then
  cleanup
  exit 0
fi

# ----------------------------------------------------------------------------
# 1. Create the AKS cluster
# ----------------------------------------------------------------------------
log "Creating resource group '$RESOURCE_GROUP' in '$LOCATION'"
az group create -n "$RESOURCE_GROUP" -l "$LOCATION"

log "Creating AKS cluster '$CLUSTER_NAME'"
aks_create_args=(
  -n "$CLUSTER_NAME"
  -g "$RESOURCE_GROUP"
  --network-plugin azure
  --network-plugin-mode overlay
  --node-vm-size "$NODE_VM_SIZE"
  --generate-ssh-keys
)
# Only pin a version when one is explicitly requested; otherwise let AKS pick.
if [ -n "$K8S_VERSION" ]; then
  aks_create_args+=(-k "$K8S_VERSION")
fi
az aks create "${aks_create_args[@]}"

log "Fetching cluster credentials"
az aks get-credentials -n "$CLUSTER_NAME" -g "$RESOURCE_GROUP" --overwrite-existing

# ----------------------------------------------------------------------------
# 2. Install ArgoCD
# ----------------------------------------------------------------------------
log "Creating namespace '$ARGOCD_NAMESPACE'"
kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

log "Installing ArgoCD"
kubectl apply -n "$ARGOCD_NAMESPACE" -f "$ARGOCD_MANIFEST"

log "Waiting for the ArgoCD server deployment to become available"
kubectl rollout status deployment/argocd-server -n "$ARGOCD_NAMESPACE" --timeout=300s

log "Exposing ArgoCD server via a public LoadBalancer"
kubectl patch svc argocd-server -n "$ARGOCD_NAMESPACE" -p '{"spec": {"type": "LoadBalancer"}}'

log "Waiting for the LoadBalancer external IP (this can take a few minutes)"
ARGOCD_IP=""
for _ in $(seq 1 60); do
  ARGOCD_IP="$(kubectl get svc argocd-server -n "$ARGOCD_NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "$ARGOCD_IP" ] && break
  sleep 10
done

# ----------------------------------------------------------------------------
# 3. Deploy the ArgoCD project and the sample Helm application, source all environment variables and create the app and project manually
# ----------------------------------------------------------------------------
log "Creating the ArgoCD project ($PROJECT_MANIFEST)"
kubectl apply -f "$PROJECT_MANIFEST"

log "Creating application namespace '$APP_NAMESPACE'"
kubectl create namespace "$APP_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

log "Deploying the sample application via ArgoCD ($APP_MANIFEST)"
kubectl apply -f "$APP_MANIFEST"

log "Waiting for the ArgoCD Application to register"
sleep 5
kubectl get application -n "$ARGOCD_NAMESPACE"

# ----------------------------------------------------------------------------
# 4. Print access details (matches the README login flow)
# ----------------------------------------------------------------------------
ARGOCD_PASSWORD="$(kubectl get secret argocd-initial-admin-secret \
  -n "$ARGOCD_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"

log "ArgoCD is ready"
if [ -n "$ARGOCD_IP" ]; then
  echo "  URL:      http://$ARGOCD_IP"
  echo "  CLI:      argocd login $ARGOCD_IP:80"
else
  echo "  URL:      LoadBalancer IP not assigned yet; check with:"
  echo "            kubectl get svc argocd-server -n $ARGOCD_NAMESPACE"
fi
echo "  Username: admin"
echo "  Password: ${ARGOCD_PASSWORD:-<run: kubectl get secret argocd-initial-admin-secret -n $ARGOCD_NAMESPACE -o jsonpath='{.data.password}' | base64 -d>}"
