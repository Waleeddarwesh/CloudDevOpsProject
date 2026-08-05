# ☸️ Phase 4: Container Orchestration with Kubernetes

## 📌 Overview

This phase defines **37 Kubernetes objects** that run the application on EKS: a MySQL StatefulSet with durable EBS storage, three microservice Deployments, an ALB Ingress, and the governance layer — RBAC, ResourceQuota, LimitRange, NetworkPolicies, HPAs and PodDisruptionBudgets — that makes it operable rather than merely running.

> ✅ **Verified.** All 37 objects pass `kubeconform --strict` against the real Kubernetes **1.31** schemas. Strict mode rejects unknown fields, which is what catches a typo like `resource:` instead of `resources:` — valid YAML that Kubernetes would silently ignore.

---

# 📖 Understanding StatefulSet vs Deployment

This is the single most important design decision in this phase.

```text
   Deployment (frontend, auth, roadmap)   StatefulSet (mysql)
┌────────────────────────────────────┐  ┌──────────────────────────────────┐
│ frontend-7d4b9c-x8k2p              │  │ mysql-0                          │
│ frontend-7d4b9c-p2m4q              │  │ mysql-1                          │
│                                    │  │                                  │
│ random suffix, new on every restart│  │ ordinal, STABLE forever          │
│ pods are interchangeable           │  │ each pod has an identity         │
│ share one PVC (or none)            │  │ each gets its OWN PVC            │
│ start/stop in parallel             │  │ ordered: 0, then 1, then 2       │
│ no stable DNS per pod              │  │ mysql-0.mysql.ivolve.svc…        │
└────────────────────────────────────┘  └──────────────────────────────────┘
```

A database needs a stable identity because **its data is on disk and that disk must follow it**. Running MySQL under a Deployment with a shared `ReadWriteOnce` PVC produces two pods fighting over one volume and a corrupted data directory.

> ⚠️ **`replicas: 1` is deliberate and must not be raised.** MySQL does not replicate by incrementing that number — a second pod would start as an independent, empty database, not a replica. Real HA requires an operator (Percona XtraDB, Vitess) or Group Replication with a bootstrap sidecar. Setting `replicas: 2` here silently produces a split-brain.

---

# 📖 Understanding the Headless Service

`clusterIP: None` changes DNS behaviour fundamentally:

```text
   Normal Service                      Headless Service (clusterIP: None)
┌──────────────────────────────┐   ┌──────────────────────────────────────┐
│ mysql → 10.100.43.7          │   │ mysql → 10.0.10.42                   │
│         (one virtual IP)     │   │         (the POD IPs, directly)      │
│                              │   │                                      │
│ kube-proxy load-balances to  │   │ Plus a per-pod record:               │
│ a RANDOM backing pod         │   │   mysql-0.mysql.ivolve.svc.cluster.local
└──────────────────────────────┘   └──────────────────────────────────────┘
```

Load balancing across database replicas would be **wrong** — a write must reach a specific instance. That per-pod DNS name is what [`02-config.yaml`](manifests/02-config.yaml) sets as `DB_HOST`:

```yaml
DB_HOST: "mysql-0.mysql.ivolve.svc.cluster.local"
         └──┬──┘ └─┬─┘ └──┬──┘
           pod  service  namespace
```

> 💡 `publishNotReadyAddresses: true` gives each pod a DNS record before its readiness probe passes. Clustered databases need this — members discover each other during startup and are not Ready until they have, which is a deadlock if DNS waits for readiness.

---

# 📖 Understanding the StorageClass — the two lines that matter

```yaml
provisioner: ebs.csi.aws.com          # ← line 1
volumeBindingMode: WaitForFirstConsumer   # ← line 2
```

### `provisioner` — the removed in-tree driver

| Value | Status |
|---|---|
| `kubernetes.io/aws-ebs` | **Deprecated in 1.23, REMOVED in 1.27** |
| `ebs.csi.aws.com` | ✅ Correct |

Using the old value on a modern cluster produces a PVC that stays `Pending` **forever**, with the real cause buried in the controller-manager logs and no event on the PVC explaining why. This is the most common "my StatefulSet won't start" cause on EKS.

### `volumeBindingMode` — the AZ trap

```text
   Immediate (wrong here)              WaitForFirstConsumer (used)
┌────────────────────────────────┐  ┌──────────────────────────────────┐
│ 1. PVC created                 │  │ 1. PVC created — nothing happens │
│ 2. EBS volume created in az-a  │  │ 2. Pod scheduled to a node in az-b│
│ 3. Scheduler picks a node…     │  │ 3. EBS volume created in az-b     │
│    in az-b                     │  │ 4. ✅ Attach succeeds             │
│ 4. ✗ volume node affinity      │  │                                  │
│      conflict — stuck forever  │  │                                  │
└────────────────────────────────┘  └──────────────────────────────────┘
```

An EBS volume cannot cross an AZ boundary. This project spans two AZs, which makes `Immediate` a **coin flip**. `WaitForFirstConsumer` makes the failure impossible.

---

# 📖 Understanding the Three Probes

Kubernetes has three probes answering three different questions. Conflating them is the most consequential mistake in this manifest set.

| Probe | Question | On failure |
|---|---|---|
| **startup** | "Has it finished booting?" | Suppresses the other two until it passes |
| **liveness** | "Is it wedged?" | **Restarts the container** |
| **readiness** | "Should it get traffic now?" | Removes the pod from Service endpoints — **no restart** |

### The auth-service case — why liveness and readiness differ

`/health` in `app.py` calls `ensure_database_ready()` and returns **503 when MySQL is unreachable**.

```text
   ❌ WRONG: /health as liveness         ✅ CORRECT (used here)
┌──────────────────────────────────┐  ┌──────────────────────────────────┐
│ MySQL goes down                  │  │ MySQL goes down                  │
│  → /health returns 503           │  │  → readiness fails               │
│  → liveness fails on ALL pods    │  │  → pods leave the endpoint list  │
│  → Kubernetes restarts them all  │  │  → pods stay UP, no restart      │
│  → restarting fixes nothing      │  │                                  │
│  → cold start + thundering herd  │  │ MySQL recovers                   │
│    when MySQL returns            │  │  → readiness passes              │
│                                  │  │  → traffic resumes instantly     │
└──────────────────────────────────┘  └──────────────────────────────────┘
```

So:

```yaml
livenessProbe:
  tcpSocket: { port: http }      # is the PROCESS alive?
readinessProbe:
  httpGet: { path: /health }     # can it SERVE?
```

> 💡 **Rule of thumb:** a liveness probe must never depend on an external system. If it does, an outage in that system multiplies into a restart storm in yours.

---

# 📖 Understanding Init Containers

Init containers run to completion, in order, **before** any app container starts.

```text
  Pod: auth-service
  ┌──────────────────────────────────────────────────┐
  │ initContainer: wait-for-mysql                    │
  │   until nc -z $DB_HOST $DB_PORT; do sleep 3; done│
  │   ↓ exits 0 only when MySQL answers              │
  ├──────────────────────────────────────────────────┤
  │ container: auth-service                          │
  │   starts ONLY after the init container succeeded │
  └──────────────────────────────────────────────────┘
```

Without it, `auth-service` crash-loops while MySQL initialises — and CrashLoopBackOff's exponential delay means the service can stay down for **minutes after** the database is ready.

Putting the wait here rather than in `app.py` keeps retry logic out of the application, where it does not belong.

---

# 📖 Understanding Resource Requests, Limits and QoS

```text
        requests            limits
           │                   │
    ┌──────▼───────────────────▼──────┐
    │   guaranteed    │   burst zone   │  → above limit: throttled (CPU)
    │   reservation   │                │     or OOM-killed (memory)
    └─────────────────┴────────────────┘
     used by the scheduler   enforced by the kernel cgroup
```

| QoS class | Condition | Eviction order under node pressure |
|---|---|---|
| **Guaranteed** | requests == limits | Evicted **last** ← MySQL uses this |
| **Burstable** | requests < limits | Evicted second |
| **BestEffort** | neither set | Evicted **first** |

MySQL is deliberately **Guaranteed** — it is the only component holding persistent state.

> ⚠️ **CPU throttling is invisible on a usage graph.** A throttled container shows *low* CPU precisely because the kernel is stopping it. It manifests to users as unexplained latency. The [monitoring phase](../07-Monitoring/) has a dedicated alert and dashboard panel for exactly this.

The [LimitRange](manifests/00-namespace.yaml) caps `maxLimitRequestRatio` at **4:1** for memory. Without a bound, a pod could request 128Mi and burst to 4Gi — so the scheduler packs nodes based on a fiction and the kernel OOM-kills under real load.

---

# 📖 Understanding Network Policies

By default, Kubernetes networking is **completely flat** — every pod can reach every other pod in the cluster. A compromised frontend can open a TCP connection straight to MySQL.

```text
   Default (no policy)              With policies (this project)
┌──────────────────────────┐   ┌────────────────────────────────────┐
│ frontend ──┬──► auth     │   │ frontend ──► auth ──► mysql        │
│            ├──► roadmap  │   │     └─────► roadmap                │
│            └──► mysql ✗  │   │                                    │
│                          │   │ frontend ─╳─► mysql   DENIED       │
│  anything → anything      │   │ internet ─╳─► auth    DENIED       │
└──────────────────────────┘   └────────────────────────────────────┘
```

Two properties trip people up:

1. **Policies are allow-only.** There is no deny rule — you deny by *not allowing*.
2. **A pod is unrestricted until some policy selects it.** The moment one does, it switches to default-deny for the directions that policy covers.

Hence [`default-deny-all`](manifests/09-network-policies.yaml), then one policy re-opening each legitimate path.

> ⚠️ **Always allow DNS first.** The default-deny blocks egress to CoreDNS, so `auth-service` cannot resolve `mysql` and *everything* breaks in a way that looks like a connectivity problem. This is the single most common NetworkPolicy mistake. Note that **both UDP and TCP port 53** are required — TCP is used for responses over 512 bytes, and allowing only UDP produces intermittent, size-dependent failures.

> ⚠️ **The AWS VPC CNI ignores NetworkPolicy unless explicitly enabled.** Objects are accepted and silently unenforced — more dangerous than no policy, because the cluster *looks* protected. Enable and verify:
> ```bash
> aws eks update-addon --cluster-name ivolve-dev-eks --addon-name vpc-cni \
>   --configuration-values '{"enableNetworkPolicy":"true"}'
>
> kubectl exec -n ivolve deploy/frontend -- nc -zv mysql 3306   # must TIME OUT
> ```

---

# 📖 Understanding the Ingress

An Ingress object **does nothing on its own**. It is a declarative request that a controller must act on.

```text
   Internet
      │
      ▼
   ┌──────────────────────────────────┐
   │ Application Load Balancer        │ ← created by the AWS LB Controller
   │ (public subnets, found via the   │   FROM this Ingress object
   │  kubernetes.io/role/elb=1 tag)   │
   └────────────┬─────────────────────┘
                │ target-type: ip
                ▼
   ┌──────────────────────────────────┐
   │ frontend pods (private subnets)  │
   └──────────────────────────────────┘
```

| Setting | Note |
|---|---|
| `spec.ingressClassName: alb` | Replaces the **deprecated** `kubernetes.io/ingress.class` annotation, which some controllers now ignore — producing an Ingress that is silently never reconciled |
| `target-type: ip` | Registers pod IPs directly. `instance` mode adds a kube-proxy hop and loses the client IP |

Comparing the three exposure methods:

| Type | AWS cost | External access | Used here |
|---|---|---|---|
| `ClusterIP` | none | ❌ internal only | all backends |
| `NodePort` | none | port 30000-32767 on every node | frontend, as a **diagnostic fallback** |
| `Ingress` → ALB | ~$17/mo | ✅ real hostname, TLS, path routing | frontend, primary |

> 💡 The NodePort is a debugging tool: **if NodePort works but the Ingress does not, the problem is the ALB or the controller, not the application.**

---

## 🎯 Objectives

- Create the `ivolve` **namespace**.
- Configure a **Deployment** and **Service** for each microservice.
- Configure a **StatefulSet** for the database with a **headless Service**.
- Configure a **StorageClass** backing the StatefulSet's persistent storage.
- Configure **ConfigMap** and **Secret** for environment variables.
- Create an **Ingress** exposing the frontend.
- *Beyond the brief:* RBAC, ResourceQuota, LimitRange, NetworkPolicies, HPA, PDB, init containers, Pod Security Standards and Kustomize.

---

## 📂 Project Structure

```text
04-Kubernetes/manifests/
├── 00-namespace.yaml          # Namespace (PSS restricted) + ResourceQuota + LimitRange
├── 01-rbac.yaml               # 4 ServiceAccounts + 2 Roles + 2 RoleBindings
├── 02-config.yaml             # ConfigMap + Secret
├── 03-storage.yaml            # StorageClass (ebs.csi.aws.com, WaitForFirstConsumer)
├── 04-database.yaml           # Headless Service + StatefulSet + my.cnf ConfigMap
├── 05-auth-service.yaml       # Deployment (+init) + Service + HPA + PDB
├── 06-roadmap-service.yaml    # Deployment + Service + HPA + PDB
├── 07-frontend.yaml           # Deployment + Service + NodePort + HPA + PDB
├── 08-ingress.yaml            # ALB Ingress
├── 09-network-policies.yaml   # default-deny + DNS + 4 service policies
└── kustomization.yaml         # image substitution target for the CI pipeline
```

### The 37 objects

| Kind | Count | Names |
|---|:---:|---|
| Namespace | 1 | `ivolve` |
| ResourceQuota / LimitRange | 2 | `ivolve-quota`, `ivolve-limits` |
| ServiceAccount | 4 | one per workload |
| Role / RoleBinding | 4 | `ivolve-viewer`, `ivolve-deployer` + bindings |
| ConfigMap | 2 | `ivolve-config`, `mysql-config` |
| Secret | 1 | `ivolve-secret` |
| StorageClass | 1 | `ivolve-storage` |
| StatefulSet | 1 | `mysql` |
| Deployment | 3 | `frontend`, `auth-service`, `roadmap-service` |
| Service | 5 | 3 ClusterIP + 1 headless + 1 NodePort |
| Ingress | 1 | `frontend` |
| HPA | 3 | one per Deployment |
| PodDisruptionBudget | 3 | one per Deployment |
| NetworkPolicy | 6 | default-deny, DNS, 4 per-service |

---

## 🛠 Technologies Used

- Kubernetes 1.31 (Amazon EKS)
- Kustomize (bundled with kubectl 1.14+)
- AWS EBS CSI Driver
- AWS Load Balancer Controller
- Metrics Server (required by the HPAs)
- Pod Security Standards (`restricted`)
- kubeconform (validation)

---

## ✅ Prerequisites

- [Phase 2](../02-Terraform/) applied — EKS cluster running with add-ons.
- `kubectl` connected:
  ```bash
  aws eks update-kubeconfig --region us-east-1 --name ivolve-dev-eks
  kubectl get nodes
  ```
- **AWS Load Balancer Controller** installed (required by the Ingress):
  ```bash
  helm repo add eks https://aws.github.io/eks-charts && helm repo update
  helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=ivolve-dev-eks \
    --set serviceAccount.create=true \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(
        terraform -chdir=../02-Terraform output -raw aws_load_balancer_controller_role_arn)
  ```
- **Metrics Server** installed (required by the HPAs):
  ```bash
  helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
  helm install metrics-server metrics-server/metrics-server -n kube-system
  ```

---

# 📋 Steps

## 1. Set the real image registry

```bash
cd 04-Kubernetes/manifests

REGISTRY=$(terraform -chdir=../../02-Terraform output -raw ecr_registry)

kustomize edit set image ivolve-frontend=$REGISTRY/ivolve-frontend:dev
kustomize edit set image ivolve-auth-service=$REGISTRY/ivolve-auth-service:dev
kustomize edit set image ivolve-roadmap-service=$REGISTRY/ivolve-roadmap-service:dev
```

---

## 2. Replace the placeholder secrets

> ⚠️ [`02-config.yaml`](manifests/02-config.yaml) ships with **deliberate placeholders**. A Secret in Git is only base64-*encoded* — `base64 -d` reverses it instantly.

For a lab, create it out of band:

```bash
kubectl create namespace ivolve --dry-run=client -o yaml | kubectl apply -f -

APP_PW=$(openssl rand -base64 24)
kubectl create secret generic ivolve-secret -n ivolve \
  --from-literal=MYSQL_ROOT_PASSWORD="$(openssl rand -base64 24)" \
  --from-literal=MYSQL_PASSWORD="$APP_PW" \
  --from-literal=DB_PASSWORD="$APP_PW" \
  --from-literal=SESSION_SECRET="$(openssl rand -base64 32)"
```

> 💡 `MYSQL_PASSWORD` and `DB_PASSWORD` **must match** — they are the same credential, read by two containers under different variable names.

For real use, see [docs/SECURITY.md](../docs/SECURITY.md) — Sealed Secrets or External Secrets Operator.

---

## 3. Render and validate before applying

```bash
kubectl kustomize .              # render all 37 objects
kubectl kustomize . | kubeconform -strict -summary -kubernetes-version 1.31.0
```
```text
Summary: 37 resources found in 1 file - Valid: 37, Invalid: 0, Errors: 0, Skipped: 0
```

---

## 4. Apply

```bash
kubectl apply -k .
```

> 💡 In the finished system you do **not** run this — [ArgoCD](../06-ArgoCD/) applies it from Git. This is for testing before GitOps is wired up.

---

## 5. Watch the rollout

```bash
kubectl get pods -n ivolve -w
```
```text
NAME                               READY   STATUS     RESTARTS   AGE
mysql-0                            0/1     Pending    0          5s
mysql-0                            0/1     Running    0          32s
mysql-0                            1/1     Running    0          71s
auth-service-6b7f8d9c4-2xk4p       0/1     Init:0/1   0          8s
auth-service-6b7f8d9c4-2xk4p       0/1     Running    0          78s
auth-service-6b7f8d9c4-2xk4p       1/1     Running    0          89s
roadmap-service-5d9c7b8f6-hj3n2    1/1     Running    0          52s
frontend-7c8d9e5a4-m2p8q           1/1     Running    0          45s
```

Note `Init:0/1` on auth-service — the init container is waiting for MySQL, exactly as designed.

---

## 6. Verify each concept

```bash
# --- StatefulSet identity + its own PVC ---
kubectl get statefulset,pvc -n ivolve
```
```text
NAME                     READY   AGE
statefulset.apps/mysql   1/1     3m

NAME                               STATUS   VOLUME       CAPACITY   STORAGECLASS
persistentvolumeclaim/data-mysql-0 Bound    pvc-a1b2c3   10Gi       ivolve-storage
```

```bash
# --- Headless Service resolves to the POD IP, not a virtual IP ---
kubectl get svc mysql -n ivolve                 # CLUSTER-IP: None
kubectl run dnstest --rm -it --restart=Never --image=busybox:1.36 -n ivolve -- \
  nslookup mysql-0.mysql.ivolve.svc.cluster.local
```

```bash
# --- Volume landed in the same AZ as the pod (WaitForFirstConsumer working) ---
kubectl get pv -o custom-columns=NAME:.metadata.name,AZ:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values
kubectl get pod mysql-0 -n ivolve -o jsonpath='{.spec.nodeName}'
```

```bash
# --- Quota consumption ---
kubectl describe resourcequota ivolve-quota -n ivolve
```

```bash
# --- HPA (needs metrics-server) ---
kubectl get hpa -n ivolve
```
```text
NAME              REFERENCE                    TARGETS           MINPODS  MAXPODS  REPLICAS
auth-service      Deployment/auth-service      6%/70%, 31%/80%   2        6        2
frontend          Deployment/frontend          4%/70%, 28%/80%   2        8        2
roadmap-service   Deployment/roadmap-service   9%/70%            2        6        2
```
> If `TARGETS` shows `<unknown>/70%`, metrics-server is missing.

```bash
# --- Pods are non-root, as the `restricted` PSS requires ---
kubectl get pods -n ivolve -o custom-columns=\
NAME:.metadata.name,USER:.spec.securityContext.runAsUser,NONROOT:.spec.securityContext.runAsNonRoot
```

```bash
# --- NetworkPolicy enforcement: this MUST time out ---
kubectl exec -n ivolve deploy/frontend -- timeout 5 nc -zv mysql 3306; echo "exit=$?"
# exit=1  ← blocked, correct
```

---

## 7. Reach the application

```bash
kubectl get ingress -n ivolve
```
```text
NAME       CLASS   HOSTS   ADDRESS                                          PORTS
frontend   alb     *       k8s-ivolve-frontend-abc123.us-east-1.elb.amazonaws.com   80
```

⏱ The `ADDRESS` takes 2-3 minutes to appear while the ALB provisions. Open it in a browser.

If it stays empty:

```bash
kubectl logs -n kube-system deploy/aws-load-balancer-controller | tail -30
kubectl describe ingress frontend -n ivolve
```

---

## 8. Test resilience

```bash
# Delete a frontend pod — the Deployment replaces it immediately
kubectl delete pod -n ivolve -l app.kubernetes.io/name=frontend --wait=false
kubectl get pods -n ivolve -w

# Delete mysql-0 — it comes back as mysql-0 with the SAME PVC and the same data
kubectl delete pod mysql-0 -n ivolve
kubectl get pods,pvc -n ivolve
```

Log back into the app — your user account survived. That is the StatefulSet + PVC guarantee.

---

# 📸 Screenshots

| Description | Image |
|---|---|
| `kubectl get all -n ivolve` | `Screenshots/get_all.png` |
| StatefulSet with its bound PVC | `Screenshots/statefulset_pvc.png` |
| Headless Service DNS resolution | `Screenshots/headless_dns.png` |
| Init container gating on MySQL | `Screenshots/init_container.png` |
| `kubectl get hpa` with live targets | `Screenshots/hpa.png` |
| ResourceQuota consumption | `Screenshots/quota.png` |
| NetworkPolicy blocking frontend→mysql | `Screenshots/netpol_blocked.png` |
| Ingress with the ALB address | `Screenshots/ingress_alb.png` |
| Application running via the ALB | `Screenshots/app_via_alb.png` |
| Data surviving a pod delete | `Screenshots/persistence.png` |

---

## 📚 Key Learning Outcomes

- Choose StatefulSet vs Deployment from the workload's state requirements, and explain why `replicas: 2` on MySQL is wrong.
- Use a headless Service for stable per-pod DNS, and know when load balancing is undesirable.
- Configure a CSI StorageClass, and explain why `WaitForFirstConsumer` is mandatory in a multi-AZ cluster.
- Design a three-probe strategy, and articulate why a liveness probe must not depend on an external system.
- Use init containers for dependency ordering instead of application retry loops.
- Reason about requests, limits and QoS classes, and recognise CPU throttling as an invisible failure mode.
- Build a default-deny NetworkPolicy model and remember to allow DNS first.
- Apply the `restricted` Pod Security Standard and satisfy it with securityContext.
- Use Kustomize for image substitution instead of regex editing.

---

## 💡 Best Practices

- Use the `app.kubernetes.io/*` **recommended labels** — tooling, dashboards and selectors all key off them.
- Never use `:latest`. Immutable `<build>-<sha>` tags make rollback meaningful.
- Set `automountServiceAccountToken: false` on workloads that never call the Kubernetes API — a container-escape toolkit looks for that token first.
- Set `readOnlyRootFilesystem: true` and mount an `emptyDir` at `/tmp` for the paths that genuinely need writes.
- Always define **both** requests and limits. A namespace with a ResourceQuota makes them mandatory anyway.
- Add a **PodDisruptionBudget** to every multi-replica workload, or a node drain during an EKS upgrade can evict all replicas at once.
- Prefer `minAvailable` over `maxUnavailable` — the latter scales with replica count, so at 6 replicas the HPA could permit 5 simultaneous evictions.
- Use `topologySpreadConstraints` with `whenUnsatisfiable: ScheduleAnyway` on small clusters; a hard constraint leaves pods Pending.
- Add a `preStop` sleep to services behind a load balancer — endpoint removal and SIGTERM happen *concurrently*, which causes 502s on every deploy without it.
- Reference container ports by **name**, so changing the number in one place does not break the Service.
- Set `revisionHistoryLimit` and `progressDeadlineSeconds` so rollbacks work and stuck rollouts fail loudly.

---

## 🌍 Real-World Use Cases

- **Zero-downtime deployments** — `maxUnavailable: 0` plus readiness probes and PDBs.
- **Multi-tenant clusters** — namespace + ResourceQuota + NetworkPolicy as the isolation boundary.
- **Compliance** — Pod Security Standards enforced at admission, not audited after the fact.
- **Cost efficiency** — HPA scales with demand; requests drive bin-packing density.
- **Blast-radius reduction** — a compromised frontend provably cannot reach the database.
- **Stateful workloads** — the StatefulSet + CSI pattern generalises to Kafka, Elasticsearch and Redis.
- **Disaster recovery** — `reclaimPolicy: Retain` preserves data through a cluster rebuild.

---

## 🧹 Cleanup

```bash
# Delete the Ingress FIRST so the ALB is released before the VPC goes
kubectl delete ingress frontend -n ivolve

# Delete everything else
kubectl delete -k .

# The PVC survives on purpose (reclaimPolicy: Retain)
kubectl get pv
aws ec2 delete-volume --volume-id vol-xxxxx     # only when you're sure
```

---

## ✅ Result

A complete, production-shaped Kubernetes deployment: **MySQL as a StatefulSet** with a headless Service, stable per-pod DNS and an encrypted EBS volume bound in the correct AZ; **three microservice Deployments** with init-container dependency gating, a correct three-probe strategy, non-root `restricted`-compliant security contexts and read-only root filesystems; an **ALB Ingress** with a NodePort diagnostic fallback; and a governance layer of **RBAC, ResourceQuota, LimitRange, six NetworkPolicies, three HPAs and three PodDisruptionBudgets**.

**Validated:** `kubectl kustomize` renders 37 objects ✅ · `kubeconform --strict` vs K8s 1.31 → **37/37 valid** ✅

**Next:** [Phase 5 — Continuous Integration with Jenkins →](../05-Jenkins/)
