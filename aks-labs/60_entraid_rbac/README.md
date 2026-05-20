# EntraID Group RBAC on Private AKS

Grants members of an EntraID group (`maestro-admins`) full namespace-scoped access to a private AKS cluster, deployed via a GitLab CI/CD pipeline.

## How it works

```
EntraID Group (maestro-admins)
        │
        │  Object ID used as Kubernetes Group subject
        ▼
AKS --enable-aad  (AAD-integrated cluster)
        │
        │  Kubernetes RBAC maps the AAD group → Role
        ▼
RoleBinding → Role (full access in maestro-admins namespace)
```

## Directory structure

```
60_entraid_rbac/
├── manifests/
│   ├── namespace.yaml      — creates the maestro-admins namespace
│   ├── role.yaml           — Role with full access to all common resource types
│   └── rolebinding.yaml    — binds the EntraID group to the Role via Object ID
├── .gitlab-ci.yml          — 3-stage pipeline: validate → plan → deploy
├── commands.sh             — manual reference commands for local testing
└── README.md
```

## The critical detail: Object ID, not display name

In an AAD-integrated AKS cluster, Kubernetes receives the user's token from EntraID. The group claim in that token is the **Object ID (UUID)**, not the display name `"maestro-admins"`. The `RoleBinding` subject must therefore be the UUID:

```yaml
subjects:
  - kind: Group
    apiGroup: rbac.authorization.k8s.io
    name: "a1b2c3d4-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # Object ID, not display name
```

Fetch the Object ID with:

```bash
az ad group show --group maestro-admins --query id -o tsv
```

## GitLab pipeline strategy

The pipeline has three stages with a manual approval gate before any change lands on the cluster.

| Stage | Job | Trigger | Purpose |
|---|---|---|---|
| `validate` | `dry-run` | MR / non-main branch | Server-side dry-run to catch schema errors before merge |
| `plan` | `diff` | Push to main | Shows `kubectl diff` of what would change |
| `deploy` | `rbac` | Push to main, **manual gate** | Applies manifests after explicit human approval |

The `when: manual` gate on deploy is intentional — RBAC changes in production clusters should require a human click, not auto-deploy.

## Required GitLab CI/CD Variables

Set these under **Settings → CI/CD → Variables**. Mark `AZURE_CLIENT_SECRET` as **Protected** and **Masked**.

| Variable | Description |
|---|---|
| `AZURE_CLIENT_ID` | Service principal App ID |
| `AZURE_CLIENT_SECRET` | Service principal secret |
| `AZURE_TENANT_ID` | Azure tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Target subscription ID |
| `AKS_RESOURCE_GROUP` | Resource group containing the AKS cluster |
| `AKS_CLUSTER_NAME` | AKS cluster name |
| `ENTRAID_GROUP_OBJECT_ID` | UUID of the `maestro-admins` EntraID group |

## Role coverage

| API Group | Resources |
|---|---|
| `""` (core) | pods, services, configmaps, secrets, serviceaccounts, persistentvolumeclaims, events, endpoints, replicationcontrollers |
| `apps` | deployments, statefulsets, daemonsets, replicasets |
| `batch` | jobs, cronjobs |
| `autoscaling` | horizontalpodautoscalers |
| `networking.k8s.io` | ingresses, networkpolicies |
| `rbac.authorization.k8s.io` | roles, rolebindings |
| `policy` | poddisruptionbudgets |
| `secrets-store.csi.x-k8s.io` | secretproviderclasses |

## Private cluster consideration

For a private cluster the GitLab runner must be **network-reachable to the API server** — typically a self-hosted runner deployed inside the same VNet, or connected via VPN/ExpressRoute. The pipeline uses `az aks get-credentials` without the `--admin` flag, which forces AAD token authentication rather than cluster-admin certificate access.

## AKS cluster pre-requisite

The cluster must be created with AAD integration enabled:

```bash
# Fetch the group Object ID first — it is required by the create command
ENTRAID_GROUP_OBJECT_ID=$(az ad group show --group maestro-admins --query id -o tsv)

az aks create \
  --resource-group "$AKS_RG" \
  --name "$AKS_NAME" \
  --enable-aad \
  --aad-admin-group-object-ids "$ENTRAID_GROUP_OBJECT_ID" \
  --enable-private-cluster \
  --network-plugin azure \
  --node-count 2 \
  --zones 1 2 3
```

`--enable-azure-rbac` is **not** used. Kubernetes-native RBAC (Role/RoleBinding) is preferred here over Azure RBAC roles because it gives granular, namespace-level control without depending on Azure role assignments.

## Verifying access

After deployment, verify what the group can do in the namespace:

```bash
# List all allowed actions for the group
kubectl auth can-i --list \
  --namespace=maestro-admins \
  --as-group="$ENTRAID_GROUP_OBJECT_ID" \
  --as=dummy-user

# Spot-check specific resources
kubectl auth can-i create pods      -n maestro-admins --as-group="$ENTRAID_GROUP_OBJECT_ID" --as=dummy-user
kubectl auth can-i create services  -n maestro-admins --as-group="$ENTRAID_GROUP_OBJECT_ID" --as=dummy-user
kubectl auth can-i create secrets   -n maestro-admins --as-group="$ENTRAID_GROUP_OBJECT_ID" --as=dummy-user
```

A user who is a member of `maestro-admins` in EntraID can then authenticate and work within their namespace:

```bash
az aks get-credentials -g "$AKS_RG" -n "$AKS_NAME"

kubectl create deployment nginx --image=nginx -n maestro-admins   # succeeds
kubectl get pods -n maestro-admins                                  # succeeds
kubectl get pods -n default                                         # FORBIDDEN — namespace scoped
```
