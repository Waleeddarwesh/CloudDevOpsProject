# 🏛️ Architecture

Component design, data flow, network topology, and the reasoning behind each significant decision — including the ones that were trade-offs rather than obvious wins.

---

## 📑 Contents

- [System Overview](#system-overview)
- [Application Architecture](#application-architecture)
- [Network Topology](#network-topology)
- [Data Flow](#data-flow)
- [Identity and Trust Chains](#identity-and-trust-chains)
- [Design Decisions](#design-decisions)
- [Known Limitations](#known-limitations)
- [Failure Modes](#failure-modes)
- [Scaling Model](#scaling-model)

---

<a id="system-overview"></a>

## 🗺️ System Overview

```text
┌───────────────────────────────────────────────────────────────────────────┐
│ AWS Account · us-east-1                                                   │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │ VPC 10.0.0.0/16                                                     │  │
│  │                                                                     │  │
│  │  ┌── PUBLIC ──────────────────────────────────────────────────────┐ │  │
│  │  │  us-east-1a  10.0.1.0/24      us-east-1b  10.0.2.0/24          │ │  │
│  │  │  ┌────────────────────┐       ┌──────────────────────────┐     │ │  │
│  │  │  │ Jenkins EC2        │       │  (ALB spans both AZs)    │     │ │  │
│  │  │  │ t3.medium · EIP    │       └──────────────────────────┘     │ │  │
│  │  │  │ IMDSv2 · IAM role  │                                        │ │  │
│  │  │  └────────────────────┘       ┌──────────────────────────┐     │ │  │
│  │  │  ┌────────────────────┐       │  Application Load        │     │ │  │
│  │  │  │ NAT Gateway        │       │  Balancer (internet)     │     │ │  │
│  │  │  └─────────┬──────────┘       └────────────┬─────────────┘     │ │  │
│  │  └────────────┼───────────────────────────────┼───────────────────┘ │  │
│  │               │ egress only                   │ target-type: ip     │  │
│  │  ┌── PRIVATE ─┼───────────────────────────────┼───────────────────┐ │  │
│  │  │  us-east-1a▼ 10.0.10.0/24     us-east-1b   ▼ 10.0.11.0/24      │ │  │
│  │  │  ┌──────────────────────┐     ┌──────────────────────────┐     │ │  │
│  │  │  │ EKS worker node 1    │     │ EKS worker node 2        │     │ │  │
│  │  │  │  frontend            │     │  frontend                │     │ │  │
│  │  │  │  auth-service        │     │  auth-service            │     │ │  │
│  │  │  │  roadmap-service     │     │  roadmap-service         │     │ │  │
│  │  │  │  mysql-0 ── EBS 10Gi │     │  prometheus ── EBS 20Gi  │     │ │  │
│  │  │  └──────────────────────┘     └──────────────────────────┘     │ │  │
│  │  └────────────────────────────────────────────────────────────────┘ │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│   ECR (3 repos)    S3 (tfstate)    KMS    CloudWatch Logs                  │
└───────────────────────────────────────────────────────────────────────────┘
```

### Layers

| Layer | Technology | Owns |
|---|---|---|
| **Provisioning** | Terraform | VPC, EC2, EKS, ECR, IAM, KMS, S3 |
| **Configuration** | Ansible | Packages and services on the Jenkins host |
| **Orchestration** | Kubernetes | Pod scheduling, service discovery, storage binding |
| **Integration** | Jenkins | Build, test, scan, publish |
| **Deployment** | ArgoCD | Cluster reconciliation from Git |
| **Observability** | Prometheus | Metrics, alerts, dashboards |

---

<a id="application-architecture"></a>

## 🧩 Application Architecture

```text
                      ┌──────────────┐
                      │   Browser    │
                      └──────┬───────┘
                             │ HTTPS/HTTP
                             ▼
                    ┌─────────────────┐
                    │       ALB       │   internet-facing, public subnets
                    └────────┬────────┘
                             │ target-type: ip → pod IPs directly
                             ▼
              ┌──────────────────────────────┐
              │  frontend  (Node 22, :3000)  │  ← the ONLY public service
              │  · renders EJS               │
              │  · holds the session cookie  │
              └───────┬──────────────┬───────┘
                      │              │      server-side HTTP calls
        POST /login   │              │  GET /api/roadmap
                      ▼              ▼
   ┌──────────────────────┐   ┌───────────────────────────┐
   │ auth-service         │   │ roadmap-service           │
   │ Python 3.12 / Flask  │   │ Java 21 / Spring Boot     │
   │ :5000                │   │ :8080                     │
   │ · bcrypt hashing     │   │ · static JSON payload     │
   │ · creates `users`    │   │ · STATELESS               │
   └──────────┬───────────┘   └───────────────────────────┘
              │ :3306
              ▼
   ┌──────────────────────┐
   │ mysql-0              │  StatefulSet · headless Service
   │ MySQL 8.0            │  EBS gp3 10Gi · encrypted · Retain
   └──────────────────────┘
```

### Service contracts

| Service | Endpoints | Env vars it actually reads |
|---|---|---|
| `frontend` | `GET /`, `GET /signup`, `POST /signup`, `POST /login`, `GET /roadmap`, `POST /logout` | `AUTH_SERVICE_URL`, `ROADMAP_SERVICE_URL`, `SESSION_SECRET`, `NODE_ENV` |
| `auth-service` | `GET /health`, `POST /api/auth/signup`, `POST /api/auth/login` | `DB_HOST`, `DB_PORT`, `DB_NAME`, **`DB_USER`**, `DB_PASSWORD` |
| `roadmap-service` | `GET /api/roadmap` | `JAVA_OPTS` |

> ⚠️ **`DB_USER`, not `DB_USERNAME`.** `app.py` validates all five variables at startup and raises `RuntimeError: Missing database environment variables` listing any that are absent. Getting this name wrong is a startup crash, not a silent fallback.

> ⚠️ **The upstream README has the languages of `auth-service` and `roadmap-service` swapped.** It claims auth is Java and roadmap is Python. The code says otherwise: `auth-service/app.py` imports Flask; `roadmap-service/pom.xml` declares `spring-boot-starter-parent`. Everything in this repository follows the code.

---

<a id="network-topology"></a>

## 🌐 Network Topology

### Subnet allocation

| Subnet | CIDR | AZ | Hosts | Public IP |
|---|---|---|---|:---:|
| public-1a | `10.0.1.0/24` | us-east-1a | Jenkins, NAT GW, ALB | ✅ |
| public-1b | `10.0.2.0/24` | us-east-1b | ALB | ✅ |
| private-1a | `10.0.10.0/24` | us-east-1a | EKS worker 1 | ❌ |
| private-1b | `10.0.11.0/24` | us-east-1b | EKS worker 2 | ❌ |

### Four independent enforcement layers

```text
   Internet
      │
   ①  ▼  Network ACL (subnet, stateless, allow + DENY)
   ┌──────────────────────────────────────────┐
   │  ②  Security Group (ENI, stateful)       │
   │  ┌────────────────────────────────────┐  │
   │  │  ③  NetworkPolicy (pod, CNI)       │  │
   │  │  ┌──────────────────────────────┐  │  │
   │  │  │  ④  Pod securityContext      │  │  │
   │  │  │     non-root, caps dropped,  │  │  │
   │  │  │     read-only rootfs         │  │  │
   │  │  └──────────────────────────────┘  │  │
   │  └────────────────────────────────────┘  │
   └──────────────────────────────────────────┘
```

Each layer fails independently. An attacker who bypasses the ALB still meets the Security Group; who bypasses that still meets the NetworkPolicy; who lands inside a container still has no root and no capabilities.

### Egress paths

| Source | Destination | Path |
|---|---|---|
| Worker pod → ECR | image pull | NAT Gateway → IGW |
| Worker node → EKS API | kubelet | **private endpoint**, stays in the VPC |
| Jenkins → GitHub/ECR | build | IGW directly (public subnet) |
| ALB → frontend pod | user traffic | direct to the pod IP (`target-type: ip`) |

---

<a id="data-flow"></a>

## 🔀 Data Flow

### User signup

```text
Browser              frontend           auth-service          mysql
   │  POST /signup      │                    │                  │
   ├───────────────────►│                    │                  │
   │                    │ POST /api/auth/    │                  │
   │                    │      signup        │                  │
   │                    ├───────────────────►│                  │
   │                    │                    │ CREATE TABLE IF  │
   │                    │                    │  NOT EXISTS users│
   │                    │                    ├─────────────────►│
   │                    │                    │ bcrypt.hashpw()  │
   │                    │                    │ INSERT           │
   │                    │                    ├─────────────────►│
   │                    │ 201 Created        │                  │
   │  302 → /           │◄───────────────────┤                  │
   │◄───────────────────┤                    │                  │
```

> 💡 `auth-service` creates the `users` table itself on first connection (`ensure_database_ready()`), so no migration Job is required.

### Deployment

```text
developer         Jenkins            ECR         Git         ArgoCD      cluster
    │  git push      │                │           │             │           │
    ├───────────────►│                │           │             │           │
    │                │ test·sonar     │           │             │           │
    │                │ build          │           │             │           │
    │                │ TRIVY GATE ⛔  │           │             │           │
    │                │ push ─────────►│           │             │           │
    │                │ kustomize edit │           │             │           │
    │                │ git commit ────┼──────────►│             │           │
    │                │                │           │  poll/hook  │           │
    │                │                │           ├────────────►│           │
    │                │                │           │             │ apply by  │
    │                │                │           │             │ sync wave │
    │                │                │           │             ├──────────►│
    │                │                │◄──────────┼─────────────┼─ pull ────┤
```

---

<a id="identity-and-trust-chains"></a>

## 🔗 Identity and Trust Chains

### Jenkins → ECR (no static keys)

```text
EC2 instance ──► instance profile ──► IAM role ──► scoped policy
                                                    ecr:PutImage on
                                                    3 repository ARNs
      │
      └─ IMDSv2 required: credentials retrievable only with a PUT-obtained
         token, so SSRF cannot read them
```

### Jenkins → Kubernetes (two independent gates)

```text
IAM role ──► EKS Access Entry ──► Kubernetes group "ivolve-ci"
                                        │
                                        └─► RoleBinding ──► Role
                                              (namespace ivolve, EDIT only)

Gate 1 (IAM):  may I CALL the API endpoint?
Gate 2 (RBAC): what may I DO once inside?
```

> 💡 This is why "I have `AdministratorAccess` but `kubectl` says Unauthorized" is so common — IAM permissions alone grant nothing inside the cluster.

### Pod → AWS (IRSA)

```text
Pod (SA: ebs-csi-controller-sa)
   │ projected JWT
   ▼
EKS OIDC issuer ──registered──► IAM OIDC provider
   │
   ▼ sts:AssumeRoleWithWebIdentity
IAM role, trust policy condition:
   sub == system:serviceaccount:kube-system:ebs-csi-controller-sa
   aud == sts.amazonaws.com
   │
   ▼
temporary credentials scoped to EC2 volume operations
```

---

<a id="design-decisions"></a>

## ⚖️ Design Decisions

| # | Decision | Alternative | Why |
|---|---|---|---|
| 1 | **Kustomize** for image updates | `sed -i 's\|image: .*\|...\|g'` | The regex rewrites *every* `image:` line — including `busybox` and `mysql:8.0`. Verified: Kustomize touched 3 of 5 image lines; `sed` would have touched all 5. |
| 2 | **S3 native locking** (`use_lockfile`) | DynamoDB lock table | Deprecated in TF 1.11. One less resource to provision and pay for. |
| 3 | **`for_each`** in the ECR module | `count` | Removing an item from a `count` list shifts indices and Terraform destroys/recreates the survivors — deleting live images. |
| 4 | **Black-box probes** | Adding `/metrics` to each service | Keeps `src/` byte-identical to upstream and independently verifiable. Upgrade path documented in [MONITORING.md](MONITORING.md). |
| 5 | **`tcpSocket` liveness** on auth-service | `httpGet /health` | `/health` returns 503 when MySQL is down. As liveness, a DB outage would restart every auth pod — which fixes nothing and adds a cold start. |
| 6 | **`WaitForFirstConsumer`** | `Immediate` | EBS volumes cannot cross AZs. With two AZs, `Immediate` is a coin flip between working and `volume node affinity conflict`. |
| 7 | **`replicas: 1`** on MySQL | 2+ | MySQL does not replicate by incrementing that number. A second pod is an independent empty database — a silent split-brain. |
| 8 | **Single NAT Gateway** default | One per AZ | Saves ~$33/mo. Documented single point of failure; `single_nat_gateway = false` flips it for production. |
| 9 | **`--ignore-unfixed`** in Trivy | Fail on all CRITICAL | Otherwise every build fails on unpatchable base-image CVEs. A gate everyone bypasses is worse than no gate. |
| 10 | **`unstable`** on a failed SonarQube gate | `error` | The upstream code carries pre-existing findings that would block every build from day one. Documented as a baseline to tighten. |
| 11 | **`ServerSideApply`** in ArgoCD | Client-side | Avoids the 256 KB last-applied annotation limit and resolves field-ownership conflicts with controllers. |
| 12 | **Vendored `src/`** | Git submodule | Submodules break Docker build contexts and confuse CI checkouts. Provenance recorded as commit `aa60d92`. |
| 13 | **`bootstrap_cluster_creator_admin_permissions = true`** | Explicit access entry for the caller | Under an assumed role, `aws_caller_identity.arn` returns a *session* ARN that the Access Entry API rejects — breaking every CI-driven apply. |
| 14 | **`gunicorn`** instead of `python app.py` | Flask dev server | Werkzeug's dev server is single-threaded and explicitly unsupported for production. The one app-side change made, and it is a container concern. |

---

<a id="known-limitations"></a>

## ⚠️ Known Limitations

These are **honest gaps**, documented rather than hidden.

### 1. In-memory sessions break multi-replica login

`frontend/server.js` uses `express-session` with the default `MemoryStore`. Each replica has its own store, so a user whose next request lands on a different pod appears logged out.

**Mitigated** by ALB `stickiness.enabled=true` (a workaround, not a fix).
**Real fix:** a shared store.

```javascript
const RedisStore = require("connect-redis").default;
app.use(session({ store: new RedisStore({ client: redisClient }), … }));
```

### 2. MySQL is a single point of failure

One replica, no replication, no automated backup. A node failure means downtime until the pod reschedules and the EBS volume re-attaches (typically 2-5 minutes).

**Production path:** the Percona or Oracle MySQL operator for replication + automated backups, or migrate to RDS Multi-AZ.

### 3. Kubernetes Secrets are base64 in Git

`02-config.yaml` ships **deliberate placeholders**. See [SECURITY.md](SECURITY.md) for the Sealed Secrets and External Secrets Operator paths.

### 4. No TLS on the ALB

HTTP only. TLS requires a domain and an ACM certificate; the annotations are present and commented in `08-ingress.yaml`.

### 5. No application metrics

No `/metrics` endpoint on any service. Black-box probes cover availability and latency but not request rates or error rates by route.

### 6. The shared library needs a second repository

Jenkins requires `vars/` at the repository root. See [Phase 5](../05-Jenkins/README.md#3-set-up-the-shared-library).

### 7. NetworkPolicy requires explicit CNI enablement

The AWS VPC CNI accepts and **silently ignores** NetworkPolicy objects unless `enableNetworkPolicy=true`. More dangerous than no policy, because the cluster *looks* protected. Verification command is in [Phase 4](../04-Kubernetes/README.md).

### 8. No test suite

The upstream application ships no tests. `runUnitTests.groovy` runs them if present and reports clearly when absent — it never silently passes a *failing* test.

---

<a id="failure-modes"></a>

## 💥 Failure Modes

| Failure | Blast radius | Recovery | Handled by |
|---|---|---|---|
| One frontend pod dies | None — 1 of 2 remains | Automatic, ~30s | Deployment + PDB |
| **All** frontend pods die | Total outage | Automatic | ALB health checks + `minAvailable: 1` |
| auth-service down | Login/signup fail; roadmap still renders | Automatic | Independent Deployments |
| **MySQL down** | Login/signup fail; auth pods stay UP | Manual investigation | `tcpSocket` liveness prevents a restart storm |
| One worker node dies | Half of capacity | ~5 min reschedule | 2 AZs + topology spread |
| **One AZ down** | Degraded; single NAT may block egress | Manual | `single_nat_gateway = false` for full HA |
| EBS volume lost | Data loss | Restore from snapshot | `reclaimPolicy: Retain` + snapshots (not automated) |
| Bad image deployed | Depends | `git revert` → ArgoCD syncs | Immutable tags + GitOps |
| Jenkins down | No new deploys; running app unaffected | Re-run Ansible | CI is not in the request path |
| ArgoCD down | No new deploys; running app unaffected | Reinstall | CD is not in the request path |

> 💡 The last two matter: **neither Jenkins nor ArgoCD is in the user request path**. A CI/CD outage stops deployments, not the application.

---

<a id="scaling-model"></a>

## 📈 Scaling Model

```text
   Load increases
        │
        ▼
   HPA sees CPU > 70% of requests
        │
        ▼
   Adds pods (max +100% or +2 per 30s)
        │
        ├─ capacity available ──► pods schedule ──► load absorbed
        │
        └─ no capacity ──► pods Pending
                              │
                              ▼
                     Cluster Autoscaler (IRSA role provisioned)
                              │
                              ▼
                     node group desired_size ↑ (max 4)
```

| Workload | min | max | Trigger |
|---|:---:|:---:|---|
| `frontend` | 2 | 8 | CPU 70% / memory 80% |
| `auth-service` | 2 | 6 | CPU 70% / memory 80% |
| `roadmap-service` | 2 | 6 | CPU 70% |
| worker nodes | 2 | 4 | Pending pods |
| `mysql` | 1 | 1 | **Not horizontally scalable** |

**Anti-thrash controls:** `scaleUp.stabilizationWindowSeconds: 0` (react fast), `scaleDown: 300s` (frontend/auth) and `600s` (roadmap — a JVM pod is expensive to replace).

> ⚠️ The HPA requires **metrics-server**. Without it, `kubectl get hpa` shows `<unknown>/70%` and nothing ever scales.

---

## 🔭 Production Roadmap

Ordered by value:

1. **Shared session store (Redis)** — removes the stickiness workaround and the multi-replica login bug.
2. **TLS via ACM + Route 53** — annotations already present, commented.
3. **MySQL operator or RDS Multi-AZ** — removes the single point of failure.
4. **External Secrets Operator** — removes secrets from Git entirely.
5. **Application metrics** — Actuator / prom-client / prometheus_flask_exporter.
6. **Automated EBS snapshots** — via the CSI `VolumeSnapshot` API.
7. **Multi-AZ NAT** — one flag: `single_nat_gateway = false`.
8. **Progressive delivery** — Argo Rollouts for canary releases.
9. **Centralised logging** — Loki or OpenSearch; only metrics are collected today.
10. **Image signing** — Cosign + an admission policy requiring signatures.

---

**See also:** [SETUP](SETUP.md) · [CICD](CICD.md) · [SECURITY](SECURITY.md) · [MONITORING](MONITORING.md) · [RUNBOOK](RUNBOOK.md) · [TROUBLESHOOTING](TROUBLESHOOTING.md)
