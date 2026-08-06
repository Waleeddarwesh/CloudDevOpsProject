# 🔄 Phase 6: Continuous Deployment with ArgoCD

## 📌 Overview

This phase closes the loop. Jenkins commits an image-tag change to Git; **ArgoCD notices and reconciles the cluster to match**. Nobody runs `kubectl apply`, and nobody hands deployment credentials to a CI server.

Two objects do it: an **AppProject** that constrains what may be deployed, and an **Application** that continuously syncs `04-Kubernetes/manifests/` to the `ivolve` namespace with `prune` and `selfHeal` enabled.

---

# 📖 Understanding GitOps

The defining shift is from **push** to **pull**.

```text
   Push-based CD (traditional)          Pull-based CD / GitOps (used here)
┌──────────────────────────────┐   ┌────────────────────────────────────────┐
│ Jenkins                      │   │ Jenkins                                │
│   holds a kubeconfig         │   │   commits to Git — no cluster creds    │
│   runs kubectl apply ───────►│   │            │                           │
│                              │   │            ▼                           │
│ ✗ CI has cluster-admin       │   │ Git = declared desired state           │
│ ✗ credentials outside the    │   │            ▲                           │
│   cluster                    │   │            │ polls / webhook           │
│ ✗ manual kubectl edits are   │   │ ArgoCD (INSIDE the cluster)            │
│   invisible                  │   │   pulls, diffs, applies, self-heals    │
│ ✗ "what's running?" is       │   │                                        │
│   unanswerable               │   │ ✓ credentials never leave the cluster  │
└──────────────────────────────┘   │ ✓ drift is detected AND corrected      │
                                   │ ✓ Git history = deployment history     │
                                   └────────────────────────────────────────┘
```

### The reconciliation loop

```text
        ┌──────────────────────────────────────────┐
        │                                          │
        ▼                                          │
   read Git (desired) ──► diff ──► apply ──► observe
        ▲                                          │
        └──────────────────────────────────────────┘
                    every 3 min, or on webhook
```

This runs **continuously**, not once per deploy. That is what makes `selfHeal` possible: someone runs `kubectl scale deploy/frontend --replicas=10` during an incident, and within three minutes ArgoCD restores the value in Git.

> 💡 That behaviour is the whole point — and also the thing to internalise: **an emergency manual change must be committed, not just applied**, or it will be reverted.

---

# 📖 Understanding the AppProject

Every Application belongs to a Project. Without an explicit one they land in `default`, which permits **any** source repository, **any** destination cluster, and **any** resource kind.

That matters because **ArgoCD runs with cluster-admin**:

```text
   project: default                    project: ivolve (used here)
┌──────────────────────────────┐   ┌────────────────────────────────────┐
│ sourceRepos:      '*'        │   │ sourceRepos:                       │
│ destinations:     '*'        │   │   - github.com/…/CloudDevOpsProject│
│ clusterResources: '*'        │   │ destinations:                      │
│                              │   │   - ivolve, monitoring             │
│ ⚠ anyone who can create an   │   │ clusterResourceWhitelist:          │
│   Application can create a   │   │   - Namespace                      │
│   ClusterRoleBinding and     │   │   - StorageClass                   │
│   grant themselves           │   │   ← NO ClusterRole/ClusterRoleBinding
│   cluster-admin              │   │                                    │
└──────────────────────────────┘   └────────────────────────────────────┘
```

The omission of `ClusterRole` and `ClusterRoleBinding` from the whitelist is deliberate: those are the privilege-escalation path. `Role` and `RoleBinding` **are** allowed, because their blast radius is a single namespace.

### Orphaned resource detection

```yaml
orphanedResources:
  warn: true
```

Warns when something exists in the namespace but is **not** defined in Git — i.e. it was created by hand. In a GitOps model that is drift, and drift is what GitOps exists to eliminate.

---

# 📖 Understanding Sync Waves

Applying 37 objects simultaneously would start `auth-service` before MySQL exists. Sync waves impose an order.

```text
  wave 0   Namespace · ConfigMap · Secret · StorageClass · RBAC · Quota
             │  (no annotation ⇒ default wave 0, applied first)
             ▼
  wave 1   MySQL StatefulSet          ← must be Healthy before wave 2
             ▼
  wave 2   auth-service · roadmap-service
             ▼
  wave 3   frontend                   ← both backends healthy first
             ▼
  wave 4   Ingress                    ← frontend has endpoints, so the
                                        ALB target group starts healthy
```

Declared per-resource:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"
```

ArgoCD applies a wave, **waits for those resources to become Healthy**, then proceeds. Lower numbers go first; negative numbers are allowed.

> 💡 Wave 4 on the Ingress matters practically: creating the ALB before any healthy frontend pod exists means the target group starts unhealthy and the first requests return 503.

---

# 📖 Understanding `ignoreDifferences`

Some fields are legitimately owned by **other controllers**. Without telling ArgoCD, the Application flaps between `Synced` and `OutOfSync` forever — and with `selfHeal` on, ArgoCD actively **fights** the controller.

```text
   Without ignoreDifferences            With ignoreDifferences
┌──────────────────────────────┐   ┌────────────────────────────────────┐
│ HPA scales frontend 2 → 5    │   │ HPA scales frontend 2 → 5          │
│ ArgoCD: "Git says 2"         │   │ ArgoCD ignores /spec/replicas      │
│ ArgoCD resets to 2           │   │ → stays Synced                     │
│ HPA scales to 5 again        │   │ → HPA owns replicas, ArgoCD owns   │
│ … infinite fight, under load │   │   everything else                  │
└──────────────────────────────┘   └────────────────────────────────────┘
```

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
      - /spec/replicas      # the HPA owns this
```

---

# 📖 Understanding `prune` and `selfHeal`

| Setting | Off | On (used here) |
|---|---|---|
| `prune` | A manifest deleted from Git leaves the object **running forever** — Git and reality silently diverge | Removing a manifest removes the object |
| `selfHeal` | Manual `kubectl` changes persist and accumulate as drift | Manual changes are reverted within one sync interval |

Together they make Git **authoritative** rather than merely advisory.

> ⚠️ **`prune: true` is powerful.** Deleting `04-database.yaml` from Git deletes the StatefulSet. The PVC survives because the StorageClass uses `reclaimPolicy: Retain` — that is not an accident, it is the safety net.

### The finalizer

```yaml
finalizers:
  - resources-finalizer.argocd.argoproj.io
```

Makes deletion **cascade**. Without it, `kubectl delete application ivolve-app` removes only the Application record and **orphans the entire running stack**.

---

## 🎯 Objectives

- Configure ArgoCD to sync and deploy the application into the cluster.
- Constrain what may be deployed with an **AppProject**.
- Enable automated sync with **prune** and **self-heal**.
- Order the rollout with **sync waves**.
- Prevent controller conflicts with **ignoreDifferences**.

---

## 📂 Project Structure

```text
06-ArgoCD/
├── project.yaml                    # AppProject — the security boundary
├── applications/
│   └── ivolve-app.yaml             # Application — the sync definition
└── README.md
```

---

## 🛠 Technologies Used

- ArgoCD (stable)
- Kubernetes CRDs: `AppProject`, `Application`
- Kustomize (auto-detected from `kustomization.yaml`)
- Git as the source of truth

---

## ✅ Prerequisites

- [Phase 4](../04-Kubernetes/) manifests committed to the repository.
- `kubectl` connected to the EKS cluster.
- The repository **public**, or a repository credential configured in ArgoCD.

---

# 📋 Steps

## 1. Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd
```

Or with the Makefile:

```bash
make argo-install
```

Verify:

```bash
kubectl get pods -n argocd
```
```text
NAME                                  READY   STATUS
argocd-application-controller-0       1/1     Running
argocd-repo-server-6b9c8d7f5-x2k4p    1/1     Running
argocd-server-7d5f9c8b4-m3n8q         1/1     Running
…
```

---

## 2. Access the UI

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open **<https://localhost:8080>** (accept the self-signed certificate), log in as `admin`.

> 💡 Change the admin password and delete the bootstrap secret afterwards:
> ```bash
> argocd account update-password
> kubectl -n argocd delete secret argocd-initial-admin-secret
> ```

---

## 3. Update the repository URL

Both files reference the repository. Point them at yours:

```bash
REPO="https://github.com/WaleedDarwesh/CloudDevOpsProject.git"
sed -i "s|https://github.com/WaleedDarwesh/CloudDevOpsProject.git|$REPO|g" \
  project.yaml applications/ivolve-app.yaml
```

> ⚠️ The URL in `Application.spec.source.repoURL` **must appear in** `AppProject.spec.sourceRepos`, or the sync is rejected with:
> `application repo … is not permitted in project 'ivolve'`

---

## 4. Apply the Project and Application

```bash
kubectl apply -f project.yaml
kubectl apply -f applications/
```

Order matters — the Application references the Project.

---

## 5. Watch the first sync

```bash
kubectl get application ivolve-app -n argocd -w
```
```text
NAME         SYNC STATUS   HEALTH STATUS
ivolve-app   OutOfSync     Missing
ivolve-app   Syncing       Progressing
ivolve-app   Synced        Progressing
ivolve-app   Synced        Healthy
```

Or in the UI — the wave-by-wave rollout is visible as the graph fills in: MySQL first, then the two backends, then the frontend, then the Ingress.

```bash
kubectl get pods -n ivolve
```

---

## 6. Verify the GitOps loop end to end

This is the real test.

```bash
# 1. Note the current image
kubectl get deploy frontend -n ivolve -o jsonpath='{.spec.template.spec.containers[0].image}'; echo

# 2. Trigger a Jenkins build (or edit the tag by hand)
cd 04-Kubernetes/manifests
kustomize edit set image ivolve-frontend=<registry>/ivolve-frontend:43-b2c3d4e
git commit -am "test: bump frontend image" && git push

# 3. Wait up to 3 minutes (or force it)
kubectl patch application ivolve-app -n argocd --type merge \
  -p '{"operation":{"sync":{}}}'

# 4. Confirm the cluster followed Git
kubectl get deploy frontend -n ivolve -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
kubectl rollout status deploy/frontend -n ivolve
```

---

## 7. Verify self-healing

```bash
# Manually scale — simulating a panicked incident response
kubectl scale deploy/frontend -n ivolve --replicas=7
kubectl get deploy frontend -n ivolve      # READY 7/7

# Wait up to 3 minutes…
kubectl get deploy frontend -n ivolve      # back to 2/2 ✅
```

ArgoCD detected the drift and restored the value from Git.

> 💡 Note this does **not** fight the HPA, because `/spec/replicas` is listed in `ignoreDifferences`. ArgoCD reverts a *human* scale, but respects the *autoscaler*. Verify:
> ```bash
> kubectl get hpa frontend -n ivolve
> ```

---

## 8. Verify pruning

```bash
# Temporarily remove a resource from the kustomization
cd 04-Kubernetes/manifests
# comment out `- 07-frontend.yaml` in kustomization.yaml
git commit -am "test: prune check" && git push

# ArgoCD deletes the frontend Deployment, Service, HPA and PDB
kubectl get all -n ivolve

# Revert
git revert HEAD && git push
```

---

## 9. Roll back

```bash
# Via the CLI
argocd app history ivolve-app
argocd app rollback ivolve-app 3
```

Or simply revert the commit — which is the more GitOps-native answer, because it keeps Git as the record:

```bash
git revert <commit> && git push
```

---

## 🔧 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ComparisonError: repository not accessible` | Private repo, no credential | `argocd repo add <url> --username … --password <PAT>` |
| `application repo … is not permitted in project` | URL missing from `sourceRepos` | Add it to `project.yaml` |
| `resource … is not permitted in project` | Kind missing from the whitelist | Add it to `namespaceResourceWhitelist` |
| Application never appears | Created in the wrong namespace | It **must** be in `argocd` |
| Perpetually `OutOfSync` on `/spec/replicas` | HPA conflict | Already handled by `ignoreDifferences` |
| `Progressing` forever | A pod cannot become Healthy | `kubectl describe pod -n ivolve <pod>` |
| Deleting the Application leaves pods running | Finalizer missing | Ensure `resources-finalizer.argocd.argoproj.io` is present |
| Sync is slow to notice a commit | 3-minute default poll | Add a GitHub webhook to `https://<argocd>/api/webhook` |

---

# 📸 Screenshots

| Description | Image |
|---|---|
| ArgoCD login page | `Screenshots/argocd_login.png` |
| Application list showing Synced / Healthy | `Screenshots/argocd_apps.png` |
| Resource tree — all 37 objects | `Screenshots/argocd_tree.png` |
| Sync waves progressing in order | `Screenshots/argocd_waves.png` |
| AppProject configuration | `Screenshots/argocd_project.png` |
| Automated deployment triggered by a Jenkins commit | `Screenshots/argocd_autosync.png` |
| Self-heal reverting a manual scale | `Screenshots/argocd_selfheal.png` |
| Application running via the ALB | `Screenshots/app_live.png` |

---

## 📚 Key Learning Outcomes

- Explain pull-based GitOps and why it removes cluster credentials from CI.
- Use an AppProject as a security boundary, and identify `ClusterRoleBinding` as the escalation path to exclude.
- Order a multi-tier rollout with sync waves and understand why the Ingress must come last.
- Diagnose the `ignoreDifferences` problem — an Application fighting the HPA.
- Reason about `prune` and `selfHeal`, including the operational implication that emergency fixes must be committed.
- Understand the finalizer's role in cascading deletion.
- Roll back through Git history rather than through imperative commands.

---

## 💡 Best Practices

- **Never** use `project: default`. Constrain sources, destinations and resource kinds explicitly.
- Enable `prune` **and** `selfHeal` — half a loop is drift you cannot see.
- Always include the `resources-finalizer` so deletion cascades.
- Add `ignoreDifferences` for every field another controller owns.
- Use sync waves for anything with a startup dependency.
- Configure `retry` with backoff — the first sync often fails legitimately while a webhook or CRD is still registering.
- Prefer a **webhook** over polling for sub-second feedback.
- Pin `targetRevision` to a **tag** in production; `HEAD` is right for dev, where every merge should deploy.
- Never commit real Secrets — use Sealed Secrets or External Secrets Operator (see [docs/SECURITY.md](../docs/SECURITY.md)).
- Enable `orphanedResources.warn` so hand-created objects surface.
- Use `ServerSideApply=true` for large manifests and controller-managed fields.

---

## 🌍 Real-World Use Cases

- **Multi-cluster deployment** — one Application per cluster from the same repository.
- **Environment promotion** — dev tracks `HEAD`, staging tracks `release/*`, prod tracks a signed tag.
- **Instant rollback** — `git revert` is the deployment rollback.
- **Compliance and audit** — every production change is a reviewed, attributable Git commit.
- **Disaster recovery** — point ArgoCD at a fresh cluster and the entire platform rebuilds itself.
- **Drift remediation** — an out-of-band console change is corrected automatically.
- **App-of-apps** — one root Application managing dozens of child Applications at scale.

---

## 🧹 Cleanup

```bash
# Delete the Application — the finalizer cascades to all 37 objects
kubectl delete -f applications/

# Delete the Project
kubectl delete -f project.yaml

# Uninstall ArgoCD
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl delete namespace argocd
```

> ⚠️ Delete the Ingress **before** running `terraform destroy`, or the orphaned ALB blocks VPC deletion.

---

## ✅ Result

A complete GitOps continuous-deployment loop. An **AppProject** constrains deployments to one repository, two namespaces and a whitelisted set of resource kinds — deliberately excluding the cluster-scoped RBAC objects that would allow privilege escalation. An **Application** syncs the Kustomize-rendered manifests with `prune` and `selfHeal` enabled, ordered by **sync waves** so the database is healthy before the backends and the ALB is created only once the frontend is serving, with `ignoreDifferences` preventing any conflict with the HorizontalPodAutoscaler.

Jenkins commits; ArgoCD deploys. **Git is the single source of truth for what is running in the cluster.**

**Next:** [Phase 7 — Monitoring & Observability →](../07-Monitoring/)
