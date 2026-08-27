# Namespace Delete Constraint (OPA Gatekeeper)

Ensure a user can **only delete a namespace they created**, and cannot delete a
namespace created by another user.

## The problem

Kubernetes does **not** record which user created a resource — there is no
built-in `createdBy` field. So "who owns this namespace?" has to be tracked
explicitly. This lab records the owner in an annotation and enforces it with a
single Gatekeeper `ConstraintTemplate` that covers both CREATE and DELETE.

## How it works

| Operation | Rule |
|-----------|------|
| `CREATE`  | The namespace must carry an owner annotation (`namespace-owner`) whose value equals the requesting user's **own** username. You cannot stamp someone else as owner. |
| `DELETE`  | The owner annotation on the existing namespace must equal the requesting user. A mismatch — or a missing annotation — is denied. |

On CREATE the object is at `input.review.object`; on DELETE it is at
`input.review.oldObject`. The requesting user comes from
`input.review.userInfo.username`. Members of `allowedGroups`
(default `system:masters` — the local AKS admin kubeconfig) bypass the policy.

## Explanation

The whole policy lives in the `rego` block of `k8snamespaceowner_template.yaml`.
Here is what each part does.

**Selecting the object.** Gatekeeper hands the admission request to the policy as
`input.review`. Where the object lives depends on the operation:

```rego
object         := input.review.object      # populated on CREATE/UPDATE
deleted_object := input.review.oldObject    # populated on DELETE
```

On a DELETE there is no *new* object, only the one being removed, so it arrives
in `oldObject`. Splitting these into two names keeps each rule reading only the
field that is actually present for its operation.

**Identifying the caller.** The authenticated identity comes straight from the
API server, so it cannot be spoofed by the object being submitted:

```rego
username  := input.review.userInfo.username
owner_key := input.parameters.ownerAnnotation   # "namespace-owner" from the Constraint
```

**The admin bypass.** `is_exempt` is true when any group the user belongs to
appears in `allowedGroups`. The `[_]` on both sides means "some element of the
user's groups equals some element of the allowed groups". Every `violation`
rule starts with `not is_exempt`, so exempt users skip all checks:

```rego
is_exempt {
  input.review.userInfo.groups[_] == input.parameters.allowedGroups[_]
}
```

**The four rules.** In Rego, a `violation` is raised when *all* lines in its body
are true; each rule is evaluated independently and any that fires denies the
request. They are:

1. *CREATE, no annotation* — `not object.metadata.annotations[owner_key]` is true
   when the owner key is absent, so the namespace is rejected for having no owner.
2. *CREATE, wrong owner* — the annotation exists but `provided != username`, i.e.
   you tried to record someone else as the owner. This is what makes the stored
   owner trustworthy: the only value the API server will accept is your own name.
3. *DELETE, not the owner* — the recorded `owner != username`, so a user is
   deleting a namespace someone else created. Denied.
4. *DELETE, no owner recorded* — the namespace has no owner annotation at all
   (e.g. it predates the policy), so ownership can't be verified. Denied, rather
   than silently allowing anyone to delete it.

Together, rules 1–2 guarantee that every new namespace carries a truthful owner,
and rules 3–4 guarantee that only that owner (or an exempt admin) can delete it.

## Files

- `k8snamespaceowner_template.yaml` — the ConstraintTemplate (Rego logic).
- `namespace_owner_constraint.yaml` — the Constraint (annotation key, exempt namespaces, exempt groups).
- `alice-namespace.yaml` — a namespace owned by `alice@contoso.com` (edit to a real username).
- `no-owner-namespace.yaml` — a namespace with no owner annotation (denied on create).
- `commands.sh` / `commands.ps1` — step-by-step walkthrough.

## Enforcing on DELETE — required webhook change

Gatekeeper's validating webhook only intercepts `CREATE` and `UPDATE` by
default, so DELETE requests would never reach the policy. Add `DELETE` to the
webhook operations (see step 3 in `commands.sh`):

```bash
kubectl patch validatingwebhookconfiguration gatekeeper-validating-webhook-configuration \
  --type=json \
  -p='[{"op":"add","path":"/webhooks/0/rules/0/operations/-","value":"DELETE"}]'
```

Verify the webhook name and rule index for your Gatekeeper version first:

```bash
kubectl get validatingwebhookconfiguration gatekeeper-validating-webhook-configuration -o yaml
```

## Notes & limitations

- **Usernames must match exactly.** Run `kubectl auth whoami` and use that value
  as the annotation. On AKS with Entra ID, the username is typically the object
  ID or UPN; with the `--admin` kubeconfig you are `system:masters` (exempt).
- Because Kubernetes has no native creator field, the owner annotation is only
  as trustworthy as the CREATE rule that validates it — which is exactly why the
  CREATE rule forbids setting an owner other than yourself.
- A more automated variant would use a Gatekeeper **mutation** to auto-stamp the
  owner, but Assign mutations cannot read `userInfo`, so the honest-annotation
  approach above is the self-contained way to do this with validation alone.
