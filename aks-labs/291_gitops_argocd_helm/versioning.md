# Helm Version Management with ArgoCD

## Overview

When deploying applications to AKS with ArgoCD and Helm, there are two distinct version numbers to manage:

| Version | Location | Tracks |
|---|---|---|
| `version` in `Chart.yaml` | `helm/Chart.yaml` | The Helm chart itself (templates, structure) |
| `appVersion` in `Chart.yaml` | `helm/Chart.yaml` | The application container image version |
| Image tag | `deployment.yaml` or `values.yaml` | The exact container image running in the cluster |

Understanding which to bump when is critical for traceability.

---

## The Two Version Fields in Chart.yaml

```yaml
# helm/Chart.yaml
version: 0.1.0       # Chart version  — bump when templates/values change
appVersion: "1.16.0" # App version    — bump when the application itself changes
```

### When to bump `version`

Bump the chart `version` when you change anything inside the `helm/` folder:
- Adding or removing a Kubernetes resource (Deployment, Service, Ingress, HPA, etc.)
- Modifying a template in `helm/templates/`
- Adding new keys to `values.yaml`

### When to bump `appVersion`

Bump `appVersion` when a new container image of the application is released. It is a human-readable label — ArgoCD and Helm do not use it to pull images. The actual image tag in `deployment.yaml` is what Kubernetes uses.

---

## How ArgoCD Tracks the Deployed Version

ArgoCD uses `targetRevision` in the `Application` manifest to know which Git state to deploy:

```yaml
# app-argocd.yaml
source:
  repoURL: https://github.com/HoussemDellai/aks-course/
  path: 291_gitops_argocd_helm/helm
  targetRevision: HEAD        # always deploy the latest commit on the default branch
```

### `targetRevision` options

| Value | Meaning |
|---|---|
| `HEAD` | Latest commit on the default branch — good for dev/test |
| `main` or `master` | Tip of a named branch |
| `v1.2.0` | A specific Git tag — recommended for production |
| `a3f9c12` | A specific commit SHA — fully pinned, immutable |

For production workloads, pin to a **Git tag** so the deployed version is explicit and reproducible:

```yaml
targetRevision: v1.2.0
```

---

## Pinning the Container Image Version

The `deployment.yaml` in this lab uses `latest`:

```yaml
image: ghcr.io/jelledruyts/inspectorgadget:latest
```

`latest` is a mutable tag — it silently changes what is deployed when the upstream image is updated, making it impossible to answer "what version is running right now?"

### Recommended: pin the image tag in values.yaml

```yaml
# helm/values.yaml
image:
  repository: ghcr.io/jelledruyts/inspectorgadget
  tag: "1.2.3"
```

```yaml
# helm/templates/deployment.yaml
image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
```

Now the running version is always visible in Git and traceable through ArgoCD.

---

## Checking What Is Currently Deployed

### Via ArgoCD CLI

```sh
# Summary — shows Git commit SHA that is synced
argocd app get app02

# Full history of syncs
argocd app history app02

# Roll back to a previous sync
argocd app rollback app02 <history-id>
```

### Via ArgoCD UI

1. Open the ArgoCD dashboard and select the application.
2. The **Summary** tab shows the current Git commit SHA and `targetRevision`.
3. The **History and Rollback** tab lists every previous sync with timestamp, Git SHA, and the operator who triggered it.

### Via kubectl

```sh
# Helm release metadata stored as a secret in the app namespace
kubectl get secrets -n app02 -l owner=helm

# Full release details including chart version and app version
helm list -n app02

# Exact image tag running in the pod
kubectl get deployment inspectorgadget -n app02 \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

---

## Recommended Versioning Workflow

This workflow creates a clear, auditable chain from a code change to a running pod.

```
1. Developer merges a PR → CI pipeline builds and pushes image
       ghcr.io/myapp:1.3.0

2. Update helm/values.yaml
       image.tag: "1.3.0"

3. Bump Chart.yaml
       appVersion: "1.3.0"
       version: 0.2.0          (if templates also changed)

4. Commit & tag the Git repo
       git tag v1.3.0 && git push --tags

5. Update app-argocd.yaml
       targetRevision: v1.3.0

6. ArgoCD detects the change and syncs → AKS runs image 1.3.0
```

At any point in the future you can answer "what is deployed?" by running `argocd app get app02` or `helm list -n app02` and tracing the Git tag back to the exact commit and image.

---

## Environment-Specific Values (dev / staging / prod)

For multiple environments, keep a separate values file per environment and pass it via `valueFiles` in the ArgoCD Application:

```
helm/
  values.yaml           # shared defaults
  values-dev.yaml       # dev overrides  (e.g. image.tag: "latest")
  values-staging.yaml   # staging overrides
  values-prod.yaml      # prod overrides (e.g. image.tag: "1.3.0")
```

```yaml
# app-argocd-prod.yaml
source:
  path: 291_gitops_argocd_helm/helm
  targetRevision: v1.3.0
  helm:
    valueFiles:
      - values.yaml
      - values-prod.yaml
```

This lets prod always run a pinned, tagged version while dev can track `HEAD`.

---

## Summary

| Question | Where to look |
|---|---|
| What Git state is deployed? | `argocd app get app02` → Sync Status (commit SHA) |
| What chart version is deployed? | `helm list -n app02` → CHART column |
| What image is running? | `kubectl get deployment ... -o jsonpath=...` |
| What changed between versions? | `git log v1.2.0..v1.3.0 -- helm/` |
| How do I roll back? | `argocd app rollback app02 <history-id>` |
