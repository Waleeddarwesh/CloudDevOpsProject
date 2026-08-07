# 🚀 Technology Roadmap

Technologies that would take this platform from *portfolio-grade* to *enterprise production-grade*, organised by the three goals: **high performance**, **high availability**, and **high security**.

Each entry states what it solves, what it costs, and how hard it is. Nothing here is cargo-culted — every item maps to a specific gap documented in [ARCHITECTURE § Known Limitations](ARCHITECTURE.md#known-limitations) or [SECURITY § What Is NOT Secured](SECURITY.md#what-is-not-secured).

---

## 📑 Contents

- [How to read this](#how-to-read-this)
- [🥇 Do these first](#-do-these-first)
- [⚡ High Performance](#-high-performance)
- [🔁 High Availability](#-high-availability)
- [🔐 High Security](#-high-security)
- [👁️ Observability](#️-observability)
- [🛠️ Platform Engineering](#️-platform-engineering)
- [💰 Cost Engineering](#-cost-engineering)
- [Phased plan](#phased-plan)
- [Deliberately not recommended](#deliberately-not-recommended)

---

<a id="how-to-read-this"></a>

## 📖 How to read this

| Column | Meaning |
|---|---|
| **Impact** | 🔴 critical gap · 🟠 significant · 🟡 valuable · 🟢 nice to have |
| **Effort** | S = hours · M = days · L = weeks |
| **Cost** | Added AWS/licence spend per month |

> 💡 **The honest advice:** do not adopt all of this. A service mesh on a 3-service application costs more in operational complexity than it returns. The [Phased plan](#phased-plan) at the end is the order that actually makes sense.

---

## 🥇 Do these first

If you only do five things, do these. Each closes a **documented, real** gap in this project.

| # | Technology | Closes | Impact | Effort | Cost |
|:-:|---|---|:---:|:---:|---:|
| 1 | **Redis (ElastiCache) session store** | Multi-replica login is broken; stickiness is a workaround | 🔴 | S | ~$12 |
| 2 | **ACM + Route 53 TLS** | Session cookies travel in plaintext | 🔴 | S | ~$1 |
| 3 | **Velero or EBS snapshots** | **No MySQL backup exists** | 🔴 | S | ~$3 |
| 4 | **External Secrets Operator** | Secrets are placeholders in Git | 🟠 | M | $0 |
| 5 | **RDS Multi-AZ / MySQL Operator** | Database is a single point of failure | 🟠 | M | ~$60 |

---

<a id="-high-performance"></a>

## ⚡ High Performance

### 1 · Redis for sessions — **and this one is not optional**

> 🔴 **This fixes an actual bug.** `express-session` uses the in-memory `MemoryStore` by default. Each frontend replica has its own store, so a user whose next request lands on a different pod **appears logged out**. The ALB stickiness cookie currently papers over it.

```javascript
const RedisStore = require("connect-redis").default;
const redis = require("redis");
const client = redis.createClient({ url: process.env.REDIS_URL });

app.use(session({
  store: new RedisStore({ client }),
  secret: process.env.SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { httpOnly: true, secure: true, sameSite: "lax", maxAge: 3600000 }
}));
```

| Option | Cost/mo | Notes |
|---|---:|---|
| ElastiCache `cache.t4g.micro` | ~$12 | Managed, Multi-AZ available |
| Redis in-cluster (Bitnami chart) | ~$3 | Cheaper; you operate it |

**Bonus:** removes the need for ALB stickiness, which restores even load distribution.

---

### 2 · CDN — CloudFront

The frontend serves CSS, images and EJS-rendered HTML directly from Node. Every static asset is a round trip to the ALB and into a pod.

```text
   Today                          With CloudFront
┌────────────────────────┐   ┌──────────────────────────────┐
│ browser → ALB → pod    │   │ browser → CloudFront edge     │
│ for every .css, .png   │   │   ├ cache HIT  → ~15ms        │
│ ~120ms each            │   │   └ cache MISS → ALB → pod    │
└────────────────────────┘   └──────────────────────────────┘
```

| Benefit | Detail |
|---|---|
| Latency | Edge locations worldwide; typically 5-10× faster for static assets |
| Origin load | 80-95% of asset requests never reach the cluster |
| Free TLS | ACM certificates at no cost |
| DDoS | AWS Shield Standard included |

**Cost:** ~$1-5/mo at low traffic. **Effort:** S.

---

### 3 · Application-level caching

`roadmap-service` returns a **completely static** JSON array on every request — a JVM round trip for constant data.

```java
@Cacheable("roadmap")
@GetMapping("/api/roadmap")
public ResponseEntity<?> roadmap() { … }
```

Or simply set a `Cache-Control` header and let CloudFront do it. **Effort:** S. **Cost:** $0.

---

### 4 · Database connection pooling

`auth-service` opens a **new MySQL connection on every request** (`get_connection()` per handler). TCP handshake + auth per login is measurable latency and wasted database capacity.

```python
from mysql.connector import pooling

pool = pooling.MySQLConnectionPool(
    pool_name="ivolve", pool_size=10, pool_reset_session=True, **DB_CONFIG
)

def get_connection():
    return pool.get_connection()
```

**Effort:** S. **Cost:** $0. **Impact:** noticeably lower login latency under load.

---

### 5 · Graviton (ARM64) instances

| | x86 (t3.medium) | Graviton (t4g.medium) |
|---|---:|---:|
| Cost/mo | $30.37 | **$24.23** (-20%) |
| Performance | baseline | +10-20% on these workloads |

All three base images (`node:22-alpine`, `python:3.12-slim`, `eclipse-temurin:21-jre-alpine`) publish `arm64` variants. The Ansible roles already map architecture via `docker_apt_arch_map` and `java_arch_map`.

```hcl
node_instance_types = ["t4g.medium"]
ami_type            = "AL2023_ARM_64_STANDARD"
```

Requires multi-arch image builds:

```groovy
sh "docker buildx build --platform linux/amd64,linux/arm64 --push -t ${image} ${context}"
```

**Effort:** M. **Saving:** ~20% of compute spend.

---

### 6 · Karpenter instead of the Cluster Autoscaler

| | Cluster Autoscaler | **Karpenter** |
|---|---|---|
| Provisioning speed | 2-5 min (via ASG) | **~40 seconds** (direct EC2 API) |
| Instance selection | Fixed node-group types | Picks the cheapest type that fits the pending pods |
| Bin-packing | ASG-constrained | Actively consolidates and replaces underutilised nodes |
| Spot handling | Basic | Native interruption handling + diversification |

Typical saving: **20-50%** on compute, on top of faster scale-out.

**Effort:** M. **Impact:** 🟠 high, once traffic is variable.

---

### 7 · HTTP/2, gzip and keep-alive

```yaml
alb.ingress.kubernetes.io/load-balancer-attributes: >-
  routing.http2.enabled=true,
  idle_timeout.timeout_seconds=60
```

Already set. Add gzip in Express:

```javascript
app.use(require("compression")());
```

**Effort:** S. **Impact:** 60-80% smaller HTML/CSS payloads.

---

<a id="-high-availability"></a>

## 🔁 High Availability

### 1 · Database HA — the biggest single gap

> 🔴 One MySQL pod, no replication, **no backup**. A node failure means 2-5 minutes of downtime; volume corruption means permanent data loss.

| Option | HA | Backups | Effort | Cost/mo |
|---|:---:|:---:|:---:|---:|
| **RDS MySQL Multi-AZ** | ✅ automatic failover | ✅ automated PITR | **S** | ~$60 |
| **Aurora Serverless v2** | ✅ 6-way replicated | ✅ continuous | M | ~$45+ |
| **Percona XtraDB Operator** | ✅ 3-node cluster | ✅ to S3 | L | ~$40 |
| **Vitess** | ✅ + sharding | ✅ | L | ~$80 |

**Recommendation: RDS Multi-AZ.** Least effort, highest reliability, removes the database from your operational burden entirely. The application needs no code change — only `DB_HOST`.

```hcl
resource "aws_db_instance" "mysql" {
  engine                  = "mysql"
  engine_version          = "8.0"
  instance_class          = "db.t4g.micro"
  multi_az                = true          # ← automatic failover
  backup_retention_period = 7             # ← point-in-time recovery
  storage_encrypted       = true
  deletion_protection     = true
}
```

---

### 2 · Backup — Velero

> 🔴 There is currently **no backup of anything**. `reclaimPolicy: Retain` protects against accidental *deletion*; it does nothing against *corruption*.

```bash
velero install --provider aws --bucket ivolve-backups \
  --plugins velero/velero-plugin-for-aws:v1.10.0

# Nightly, 30-day retention, including PVC snapshots
velero schedule create daily --schedule="0 2 * * *" \
  --include-namespaces ivolve --ttl 720h
```

Velero backs up **both** Kubernetes objects and the underlying EBS volumes, and can restore into a *different* cluster — which is what makes it a disaster-recovery tool rather than just a snapshot script.

**Effort:** S. **Cost:** ~$3/mo. **Impact:** 🔴 critical.

---

### 3 · Multi-AZ NAT — one flag

```hcl
single_nat_gateway = false
```

Today a single NAT Gateway in one AZ means **an AZ failure cuts internet egress for every private subnet** — pods in healthy AZs can no longer pull images.

**Effort:** trivial. **Cost:** +$33/mo per extra AZ.

---

### 4 · Multi-region disaster recovery

| Strategy | RTO | RPO | Cost |
|---|---|---|---|
| Backup & restore | hours | 24h | $ |
| **Pilot light** | ~30 min | minutes | $$ |
| Warm standby | ~5 min | seconds | $$$ |
| Active-active | ~0 | ~0 | $$$$ |

**Pilot light** is the sensible target: ECR cross-region replication, Aurora Global Database, Route 53 health-check failover, and Terraform ready to apply in the second region.

**Effort:** L.

---

### 5 · Argo Rollouts — progressive delivery

Today a bad deploy affects 100% of users the moment it becomes Ready.

```text
   RollingUpdate (today)              Canary (Argo Rollouts)
┌──────────────────────────────┐   ┌────────────────────────────────────┐
│ v2 replaces v1 gradually     │   │ 10% → analyse → 25% → analyse →    │
│ no automated verification    │   │ 50% → 100%                         │
│ bad deploy = 100% affected   │   │ metrics regress ⇒ AUTO-ROLLBACK    │
└──────────────────────────────┘   └────────────────────────────────────┘
```

```yaml
strategy:
  canary:
    steps:
      - setWeight: 10
      - pause: { duration: 5m }
      - analysis:
          templates: [{ templateName: success-rate }]
      - setWeight: 50
      - pause: { duration: 5m }
```

The analysis template queries **Prometheus** — which you already have — and rolls back automatically if the error rate rises.

**Effort:** M. **Impact:** 🟠 high.

---

### 6 · PodDisruptionBudget + `topologySpreadConstraints` — already done ✅

Both are configured. Worth noting as the baseline that makes the above safe.

---

<a id="-high-security"></a>

## 🔐 High Security

### 1 · TLS everywhere — ACM + Route 53

> 🔴 The ALB serves **HTTP only**. Session cookies — the exact credential that authenticates a user — travel in plaintext.

```bash
aws acm request-certificate --domain-name ivolve.example.com \
  --validation-method DNS
```

The annotations are already present and commented in `08-ingress.yaml`:

```yaml
alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:...
alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
alb.ingress.kubernetes.io/ssl-redirect: "443"
```

Then set `cookie.secure = true` in `server.js`.

**Effort:** S (plus a domain). **Impact:** 🔴 critical.

---

### 2 · External Secrets Operator

> Removes secrets from Git **entirely** — the cleanest solution to the placeholder problem.

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: ivolve-secret
  namespace: ivolve
spec:
  refreshInterval: 1h
  secretStoreRef: { name: aws-secrets-manager, kind: SecretStore }
  target: { name: ivolve-secret }
  dataFrom:
    - extract: { key: ivolve/production }
```

Authenticates via **IRSA** — the OIDC provider is already created by Terraform. Secrets live in AWS Secrets Manager with automatic rotation; ESO projects them into the cluster and refreshes them.

**Effort:** M. **Cost:** ~$1/mo. **Impact:** 🟠 high.

---

### 3 · AWS WAF

> Nothing today protects against SQL injection attempts, XSS, or brute-forcing the login endpoint.

```hcl
resource "aws_wafv2_web_acl" "main" {
  rule {
    name = "RateLimit"
    statement {
      rate_based_statement { limit = 2000, aggregate_key_type = "IP" }
    }
    action { block {} }
  }
  # + AWSManagedRulesCommonRuleSet, SQLiRuleSet, KnownBadInputs
}
```

The **rate limit** matters most here: `POST /login` is currently unthrottled, so credential stuffing is unimpeded.

**Effort:** S. **Cost:** ~$8/mo + $0.60 per million requests. **Impact:** 🟠 high.

---

### 4 · Runtime security — Falco

Everything currently in place is *preventive*. Falco is **detective** — it watches syscalls and alerts on anomalous behaviour inside a running container.

```yaml
- rule: Shell spawned in container
  condition: spawned_process and container and proc.name in (bash, sh)
  output: Shell in container (pod=%k8s.pod.name cmd=%proc.cmdline)
  priority: WARNING
```

Catches: a shell spawned in a production container, an unexpected outbound connection, a write to a sensitive path, an attempted privilege escalation.

**Effort:** M. **Cost:** ~$5/mo (resources). **Impact:** 🟡.

---

### 5 · Policy as code — Kyverno

Pod Security Standards enforce a fixed set of rules. Kyverno enforces **yours**:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-images
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-signature
      match:
        resources: { kinds: [Pod] }
      verifyImages:
        - imageReferences: ["*.dkr.ecr.*.amazonaws.com/ivolve-*"]
          attestors:
            - entries: [{ keys: { publicKeys: "-----BEGIN PUBLIC KEY-----…" } }]
```

Also useful for: requiring resource limits, banning `:latest`, mandating specific labels, and auto-injecting sidecars.

**Effort:** M. **Cost:** $0. **Impact:** 🟡.

---

### 6 · Image signing — Cosign / Sigstore

Closes the last supply-chain gap: today you can verify an image *scanned clean*, but not that it *came from your pipeline*.

```groovy
// In the Jenkins pipeline, after ecrPush
sh "cosign sign --key env://COSIGN_KEY ${env.FULL_IMAGE}"
```

Paired with the Kyverno policy above, an unsigned image cannot be admitted to the cluster **at all**.

**Effort:** M. **Cost:** $0. **Impact:** 🟡.

---

### 7 · SBOM generation

```groovy
sh "trivy image --format cyclonedx --output sbom.json ${env.FULL_IMAGE}"
archiveArtifacts artifacts: 'sbom.json'
```

When the next Log4Shell lands, an SBOM answers *"are we affected?"* in seconds rather than days. Increasingly a compliance requirement.

**Effort:** S. **Cost:** $0.

---

### 8 · Private EKS endpoint + bastion / SSM

```hcl
endpoint_public_access = false
```

Removes the API server from the internet entirely. Access via SSM Session Manager (the IAM policy is already attached to the node role) or a VPN.

**Effort:** M. **Impact:** 🟡 — the endpoint is already SigV4-protected, but this removes it from enumeration.

---

### 9 · GuardDuty + Security Hub + AWS Config

| Service | Detects | Cost/mo |
|---|---|---:|
| **GuardDuty** | Crypto-mining, compromised credentials, malicious IPs — including EKS Runtime Monitoring | ~$15 |
| **Security Hub** | Aggregated findings against CIS / AWS Foundational benchmarks | ~$5 |
| **AWS Config** | Configuration drift, compliance rules | ~$10 |

**Effort:** S (mostly enablement). **Impact:** 🟠 — GuardDuty in particular catches the "lab account used for mining" scenario.

---

### 10 · Service mesh — Istio or Linkerd

Gives **mTLS between every pod** (encryption in transit inside the cluster), plus fine-grained authorization policy, automatic retries, circuit breaking and distributed tracing.

> ⚠️ **Honest assessment: not yet.** A service mesh on a **3-service** application adds substantial operational complexity for benefits you can get more cheaply — NetworkPolicy already handles segmentation; the ALB already terminates TLS. Revisit past ~10 services or when a compliance requirement mandates in-cluster encryption.

If you do adopt one, **Linkerd** over Istio: dramatically simpler, lower resource overhead, mTLS on by default.

**Effort:** L. **Cost:** ~$20/mo. **Impact:** 🟢 at this scale.

---

<a id="️-observability"></a>

## 👁️ Observability

| Technology | Adds | Effort | Cost/mo |
|---|---|:---:|---:|
| **Loki + Promtail** | Centralised logs, correlated with metrics in the same Grafana | S | ~$5 |
| **Tempo + OpenTelemetry** | Distributed tracing — *which* service caused the latency | M | ~$5 |
| **Actuator / prom-client** | Real application metrics (request rate, error rate, p99) | S | $0 |
| **Grafana OnCall / PagerDuty** | Real on-call rotation and escalation | S | $0-20 |
| **Pyroscope** | Continuous profiling — CPU/memory flame graphs in production | M | ~$5 |

> 💡 **Logs are the biggest observability gap.** Today `kubectl logs` is the only option, and it is gone the moment a pod restarts. Loki is a half-day of work and transforms debugging.

The white-box metrics upgrade path is documented in detail in [MONITORING § Upgrade Path](MONITORING.md#upgrade-path).

---

<a id="️-platform-engineering"></a>

## 🛠️ Platform Engineering

| Technology | Solves | Effort |
|---|---|:---:|
| **Terragrunt** | DRY multi-environment Terraform; keeps dev/staging/prod from drifting | M |
| **Atlantis / Terraform Cloud** | `terraform plan` on every PR, apply via comment — no local state, full audit | M |
| **Crossplane** | Provision AWS resources *from Kubernetes*, so ArgoCD manages infra too | L |
| **Backstage** | Developer portal — service catalogue, scaffolding, docs in one place | L |
| **Helm charts** | Package the app for consumers; better than raw Kustomize past ~3 environments | M |
| **Renovate** | More capable than Dependabot — grouping, auto-merge policies, custom managers | S |
| **pre-commit hooks** | Catch formatting and secrets *before* the commit, not in CI | S |

### Quick win: pre-commit

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.96.1
    hooks: [{ id: terraform_fmt }, { id: terraform_validate }, { id: terraform_tflint }]
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.21.2
    hooks: [{ id: gitleaks }]
  - repo: https://github.com/adrienverge/yamllint
    rev: v1.35.1
    hooks: [{ id: yamllint }]
```

**Effort:** 30 minutes. **Impact:** stops the "fix lint" commit churn entirely.

---

<a id="-cost-engineering"></a>

## 💰 Cost Engineering

Current baseline: **~$231/month**.

| Lever | Saving | Effort | Trade-off |
|---|---:|:---:|---|
| **Spot instances** for workers | **-70%** (~$43) | S | 2-min interruption notice; safe with PDBs |
| **Graviton** (t4g) | -20% (~$18) | M | Needs multi-arch builds |
| **Karpenter** consolidation | -20-50% | M | None — strictly better bin-packing |
| **`make tf-destroy` when idle** | **-100%** | S | Rebuild takes ~20 min |
| ECR lifecycle policies | ~$2 | ✅ done | — |
| CloudWatch retention caps | ~$5 | ✅ done | — |
| Savings Plans (1yr) | -30% | S | Commitment |

```hcl
node_capacity_type = "SPOT"   # already supported
```

> 💡 **The single biggest cost lever for a portfolio project is `make tf-destroy`.** The EKS control plane bills $73/month whether or not anything is deployed. Destroy between demos.

### Cost visibility

| Tool | Purpose |
|---|---|
| **Kubecost / OpenCost** | Per-namespace, per-deployment Kubernetes cost attribution |
| **Infracost** | Shows the cost delta in every Terraform pull request |
| **AWS Budgets** | Alert before the bill surprises you |

```yaml
# Infracost in the PR pipeline — a genuinely useful gate
- name: Infracost
  run: infracost breakdown --path 02-Terraform --format json
```

---

<a id="phased-plan"></a>

## 🗺️ Phased plan

### Phase A — close the real gaps (1 week, ~$76/mo)

Everything here fixes something **documented as broken**.

| Item | Why |
|---|---|
| Redis session store | Multi-replica login is genuinely broken |
| Velero backups | **No backup exists at all** |
| ACM + TLS | Session cookies in plaintext |
| Connection pooling | New TCP connection per login |
| `single_nat_gateway = false` | AZ failure cuts all egress |

### Phase B — production readiness (2-3 weeks, ~$85/mo)

| Item | Why |
|---|---|
| RDS Multi-AZ | Removes the database SPOF |
| External Secrets Operator | Secrets out of Git |
| AWS WAF | Rate limiting on `/login` |
| Loki | Logs survive a pod restart |
| GuardDuty + Security Hub | Threat detection |

### Phase C — scale and efficiency (1 month, **net saving**)

| Item | Why |
|---|---|
| Karpenter | Faster scaling, 20-50% cheaper |
| Spot instances | -70% on compute |
| Graviton | -20% and faster |
| CloudFront | Latency and origin offload |
| Argo Rollouts | Automated canary + rollback |

### Phase D — enterprise maturity (ongoing)

Kyverno · Cosign · Falco · Tempo · Backstage · Atlantis · multi-region DR

---

<a id="deliberately-not-recommended"></a>

## 🚫 Deliberately not recommended

Being able to justify what you **left out** matters as much as what you added.

| Technology | Why not — *here* |
|---|---|
| **Service mesh (Istio)** | 3 services. NetworkPolicy already segments; the ALB already terminates TLS. Enormous complexity for marginal gain. Revisit at ~10+ services. |
| **Kafka** | No event-driven requirement. Two synchronous HTTP calls is the whole architecture. |
| **MongoDB / NoSQL** | The data is a relational `users` table. MySQL is correct. |
| **Multi-cloud abstraction** | Portability is a real cost paid for a benefit rarely collected. Use AWS well instead. |
| **Custom operators** | Nothing here needs bespoke reconciliation logic. |
| **GraphQL gateway** | Two endpoints. REST is fine. |
| **Self-hosted GitLab / Harbor** | GitHub and ECR already do this, managed. |
| **Chaos engineering (Litmus)** | Valuable — but *after* the database has HA and backups. Chaos testing a system with a known SPOF and no backups just breaks it. |

> 💡 **The senior judgement:** most of the value in this list sits in Phase A and B, and most of it is cheap. Phase D is where teams commonly over-engineer. Adopting a service mesh before you have a database backup is a classic — and visible — mistake.

---

## 📊 If everything in Phases A-C were adopted

| Dimension | Today | After |
|---|---|---|
| **Availability** | ~99.0% (DB SPOF, single NAT) | ~99.95% (Multi-AZ everything) |
| **RTO** | manual, hours | < 15 min (Velero + Multi-AZ) |
| **RPO** | ∞ — **no backups** | < 5 min (RDS PITR) |
| **p95 latency** | ~120 ms | ~35 ms (CDN + pooling + Redis) |
| **Deploy safety** | all-or-nothing | canary + auto-rollback |
| **Secrets** | placeholders in Git | Secrets Manager, rotated |
| **Transport** | plaintext HTTP | TLS 1.3 end to end |
| **Cost** | ~$231/mo | ~$210/mo *(Spot + Graviton offset the additions)* |

> The cost stays roughly flat because Phase C's efficiency work pays for Phase A and B's reliability work. That is the argument to make to a budget holder.

---

**See also:** [ARCHITECTURE § Known Limitations](ARCHITECTURE.md#known-limitations) · [SECURITY § What Is NOT Secured](SECURITY.md#what-is-not-secured) · [MONITORING § Upgrade Path](MONITORING.md#upgrade-path)
