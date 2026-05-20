# EntraID Group RBAC on Public AKS

Grants members of an EntraID group (`maestro-admins`) full namespace-scoped access to a **public** AKS cluster, deployed via a GitLab CI/CD pipeline.

This lab is a replica of [60_entraid_rbac](../60_entraid_rbac/README.md) (private cluster). The Kubernetes manifests are identical — the only differences are the cluster creation command and the CI runner requirements.

## How it works

```
EntraID Group (maestro-admins)
        │
        │  Object ID used as Kubernetes Group subject
        ▼
AKS --enable-aad  (AAD-integrated cluster, public API server)
        │
        │  Kubernetes RBAC maps the AAD group → Role
        ▼
RoleBinding → Role (full access in maestro-admins namespace)
```

## Public vs private cluster — key difference

| | Public cluster | Private cluster |
|---|---|---|
| API server endpoint | Internet-accessible FQDN | Private IP only |
| GitLab runner | Shared or self-hosted, anywhere | Must be inside the VNet (or via VPN/ExpressRoute) |
| `az aks get-credentials` | Works from any machine | Must run from within the VNet |

Everything else — manifests, pipeline stages, CI variables, RBAC logic — is the same.

## Directory structure

```
61_entraid_rbac_public/
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

| Stage | Job | Trigger | Purpose |
|---|---|---|---|
| `validate` | `dry-run` | MR / non-main branch | Server-side dry-run to catch schema errors before merge |
| `plan` | `diff` | Push to main | Shows `kubectl diff` of what would change |
| `deploy` | `rbac` | Push to main, **manual gate** | Applies manifests after explicit human approval |

Because the API server is publicly reachable, **GitLab shared runners work out of the box** — no self-hosted runner configuration needed.

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

## AKS cluster pre-requisite

```bash
# Fetch the group Object ID first — it is required by the create command
ENTRAID_GROUP_OBJECT_ID=$(az ad group show --group maestro-admins --query id -o tsv)

az aks create \
  --resource-group "$AKS_RG" \
  --name "$AKS_NAME" \
  --enable-aad \
  --aad-admin-group-object-ids "$ENTRAID_GROUP_OBJECT_ID" \
  --network-plugin azure \
  --node-count 2 \
  --zones 1 2 3
```

Note the absence of `--enable-private-cluster` compared to the private cluster setup.

## Verifying access

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
