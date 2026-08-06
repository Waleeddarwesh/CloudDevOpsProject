# 🔐 Security

Threat model, defence layers, secrets strategy, and an honest account of what is *not* secured.

---

## 📑 Contents

- [Threat Model](#threat-model)
- [Defence in Depth](#defence-in-depth)
- [Identity and Access](#identity-and-access)
- [Secrets Management](#secrets-management)
- [Supply Chain](#supply-chain)
- [Network Security](#network-security)
- [Workload Hardening](#workload-hardening)
- [Data Protection](#data-protection)
- [What Is NOT Secured](#what-is-not-secured)
- [Hardening Checklist](#hardening-checklist)
- [Incident Response](#incident-response)

---

<a id="threat-model"></a>

## 🎯 Threat Model

### Assets

| Asset | Impact if compromised |
|---|---|
| User credentials (bcrypt hashes in MySQL) | Account takeover; credential-stuffing elsewhere |
| AWS account | Resource abuse (crypto-mining), data exfiltration, full account takeover |
| Container images in ECR | Supply-chain attack — malicious code deployed automatically by ArgoCD |
| Terraform state | **Complete infrastructure inventory plus every secret in plaintext** |
| Jenkins | Ability to push arbitrary images and commit arbitrary manifests |
| Git repository | ArgoCD deploys whatever is committed |

### Threat actors and the controls that stop them

| Actor | Capability | Primary control |
|---|---|---|
| Internet scanner | Mass port scanning | SG restricted to a single `/32`; workers have no public IP |
| Opportunistic attacker | Exploits a known CVE | Trivy gate blocks fixable CRITICALs before publication |
| Malicious dependency | Code execution in a container | Non-root, all caps dropped, read-only rootfs, NetworkPolicy |
| Compromised CI | Pushes a malicious image | ECR scoped to 3 repos; EKS access scoped to `EDIT` on one namespace |
| Insider / mistake | `kubectl delete` in production | ArgoCD `selfHeal`; CloudTrail + EKS audit logs |
| Credential thief | Finds a key in Git | **No static AWS keys exist**; Gitleaks in CI |

### Attack paths explicitly closed

```text
① SSRF in the frontend → read EC2 instance credentials
   ⛔ IMDSv2 required (http_tokens = "required")
      SSRF can issue GET; IMDSv2 needs a PUT to obtain a token first.

② Compromised frontend container → connect to MySQL
   ⛔ NetworkPolicy: only auth-service may reach :3306
      Verified: kubectl exec deploy/frontend -- nc -zv mysql 3306  → times out

③ Container escape → read the ServiceAccount token → call the K8s API
   ⛔ automountServiceAccountToken: false on all four workloads

④ Compromised Jenkins → overwrite a production image tag
   ⛔ ECR imageTagMutability = IMMUTABLE — an existing tag cannot be replaced

⑤ Compromised pipeline → grant itself cluster-admin
   ⛔ EKS Access Entry scoped to EDIT on namespace `ivolve`
   ⛔ ArgoCD AppProject whitelist EXCLUDES ClusterRole/ClusterRoleBinding

⑥ Privilege escalation via a setuid binary inside a container
   ⛔ allowPrivilegeEscalation: false + capabilities.drop: ["ALL"]

⑦ Attacker writes a persistence backdoor into a running container
   ⛔ readOnlyRootFilesystem: true (writable /tmp is tmpfs, wiped on restart)
```

---

<a id="defence-in-depth"></a>

## 🛡️ Defence in Depth

```text
   Internet
      │
  ①   ▼  Network ACL         subnet · stateless · allow + DENY
  ┌─────────────────────────────────────────────────────────┐
  │ ②  Security Group        ENI · stateful · your /32 only  │
  │ ┌─────────────────────────────────────────────────────┐ │
  │ │ ③  IAM                 who may call the AWS API      │ │
  │ │ ┌─────────────────────────────────────────────────┐ │ │
  │ │ │ ④  Kubernetes RBAC   what you may do in-cluster  │ │ │
  │ │ │ ┌─────────────────────────────────────────────┐ │ │ │
  │ │ │ │ ⑤ NetworkPolicy    which pods may talk       │ │ │ │
  │ │ │ │ ┌─────────────────────────────────────────┐ │ │ │ │
  │ │ │ │ │ ⑥ Pod Security   non-root · no caps      │ │ │ │ │
  │ │ │ │ │ ┌─────────────────────────────────────┐ │ │ │ │ │
  │ │ │ │ │ │ ⑦ Container    read-only rootfs      │ │ │ │ │ │
  │ │ │ │ │ └─────────────────────────────────────┘ │ │ │ │ │
  │ │ │ │ └─────────────────────────────────────────┘ │ │ │ │
  │ │ │ └─────────────────────────────────────────────┘ │ │ │
  │ │ └─────────────────────────────────────────────────┘ │ │
  │ └─────────────────────────────────────────────────────┘ │
  └─────────────────────────────────────────────────────────┘
```

No single layer is trusted. Each assumes the one outside it has already failed.

---

<a id="identity-and-access"></a>

## 🔑 Identity and Access

### Zero static AWS credentials

**There is no `AKIA…` key anywhere in this project.**

| Consumer | Mechanism | Rotation |
|---|---|---|
| Jenkins EC2 | Instance profile | Automatic, hourly |
| EBS CSI driver | IRSA | Automatic, per-token |
| AWS LB Controller | IRSA | Automatic, per-token |
| Cluster Autoscaler | IRSA | Automatic, per-token |
| Worker nodes | Node instance role | Automatic |

> 💡 A leaked long-lived access key is the single most common path from "CI server compromised" to "AWS account compromised". Removing them removes the path.

### IAM scoping

`ecr:GetAuthorizationToken` **cannot** be resource-scoped — AWS issues the token registry-wide. It is therefore isolated in its own statement so the wildcard is confined to one harmless read action:

```hcl
statement {
  sid       = "EcrAuthToken"
  actions   = ["ecr:GetAuthorizationToken"]
  resources = ["*"]                          # unavoidable
}

statement {
  sid       = "EcrPushPull"
  actions   = ["ecr:PutImage", "ecr:UploadLayerPart", …]
  resources = var.ecr_repository_arns        # ← 3 specific ARNs
}
```

### Two gates to the cluster

```text
Gate 1 — IAM:  eks:DescribeCluster        → may I reach the endpoint?
Gate 2 — RBAC: EKS Access Entry → Group   → what may I do inside?
                 └─► ivolve-ci ─► RoleBinding ─► Role (EDIT, ns=ivolve)
```

Jenkins gets **`AmazonEKSEditPolicy` scoped to one namespace** — deliberately not `ADMIN`:

- EDIT cannot create or modify RBAC objects → a compromised pipeline cannot escalate itself.
- Namespace scope → it cannot touch `kube-system`, `argocd` or `monitoring`.

### Kubernetes RBAC

| Subject | Role | Scope |
|---|---|---|
| `ivolve-ci` (Jenkins) | `ivolve-deployer` + `ivolve-viewer` | namespace `ivolve` |
| workload SAs | none | `automountServiceAccountToken: false` |

Note that `ivolve-viewer` grants `configmaps` but **not `secrets`** — read access to a Secret is read access to the database password. "Read-only" is not the same as harmless.

---

<a id="secrets-management"></a>

## 🗝️ Secrets Management

### Current state, honestly

| Secret | Where | Protection |
|---|---|---|
| AWS credentials | ✅ nowhere | Instance profile / IRSA |
| Ansible secrets | `group_vars/all/vault.yml` | ✅ AES-256 (Ansible Vault) |
| Terraform state | S3 | ✅ SSE-AES256, versioned, TLS-enforced, public-blocked |
| K8s Secret in etcd | EKS | ✅ KMS envelope encryption |
| **K8s Secret in Git** | `02-config.yaml` | ⚠️ **Placeholders only — see below** |
| GitHub PAT | Jenkins credentials | ✅ encrypted at rest by Jenkins |
| SonarQube token | Jenkins credentials | ✅ encrypted at rest |

### The Kubernetes Secret problem

```text
   What people think                    What actually happens
┌──────────────────────────────┐   ┌────────────────────────────────────┐
│ kind: Secret                 │   │ data:                              │
│   → "it's a Secret,          │   │   password: Q0hBTkdFX01FCg==       │
│      so it's encrypted"      │   │                                    │
│                              │   │ $ echo Q0hBTkdFX01FCg== | base64 -d│
│                              │   │ CHANGE_ME                          │
│                              │   │                                    │
│                              │   │ base64 is ENCODING, not encryption │
└──────────────────────────────┘   └────────────────────────────────────┘
```

`02-config.yaml` ships **deliberate placeholders** (`CHANGE_ME_*`) with an annotation saying so. Three production-grade options:

#### Option A — Sealed Secrets *(simplest to adopt)*

```bash
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system
kubeseal --format yaml < secret.yaml > sealed-secret.yaml
```
Only the in-cluster controller holds the private key, so the sealed file is safe in a **public** repository.

#### Option B — External Secrets Operator *(best on AWS)*

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
Secrets live in AWS Secrets Manager; ESO projects them in and refreshes on rotation. **Nothing sensitive ever enters Git.** Authenticates via IRSA — the OIDC provider is already created.

#### Option C — Out-of-band `kubectl create secret`

Fine for a lab; invisible to GitOps, so add the Secret to ArgoCD's `ignoreDifferences`.

### `SESSION_SECRET` — the highest-value secret here

```javascript
// src/frontend/server.js
secret: process.env.SESSION_SECRET || "change-me-in-k8s"
```

That fallback is in a **public** upstream repository. Anyone who knows it can forge a signed session cookie for any username — a complete authentication bypass with no password needed. It is mandatory in both Compose (`${VAR:?}`) and Kubernetes.

---

<a id="supply-chain"></a>

## 📦 Supply Chain

### Five gates before code reaches production

```text
  commit
    │
  ① Gitleaks ──────── secrets in git history (full clone, not just HEAD)
    │
  ② hadolint ──────── Dockerfile misconfiguration
    │
  ③ SonarQube ─────── code smells, bugs, security hotspots
    │
  ④ Trivy ─────────── image CVEs  ⛔ BLOCKS THE PUSH
    │
  ⑤ Checkov ───────── Terraform misconfiguration
    │
  ▼ ECR (immutable tags, scan-on-push)
```

### Why the Trivy gate is credible

| Choice | Reason |
|---|---|
| Runs **before** push | Scanning after publication means the vulnerable image is already pullable |
| `--ignore-unfixed` | Without it, every build fails on unpatchable base-image CVEs — and a gate everyone bypasses is worse than none |
| Two invocations | A single failing run aborts before the report is written, leaving nothing to diagnose |
| `--severity CRITICAL` to fail | HIGH is reported, CRITICAL blocks — a calibrated threshold, not a blanket one |

### Image immutability

```hcl
image_tag_mutability = "IMMUTABLE"
```

With mutable tags, a rebuild can silently replace the image behind a tag already running in the cluster — so `ivolve-frontend:42` no longer means what it meant when it was scanned and approved. Immutability makes every tag a permanent, auditable reference, which is exactly what GitOps records in Git.

### Reproducibility

- Exact pins: `Flask==3.1.1`, `mysql:8.0`, `node:22-alpine`
- `.terraform.lock.hcl` committed (provider **checksums**)
- Multi-stage builds keep compilers out of runtime images
- Provenance labels: `org.opencontainers.image.revision` maps a container to a commit

### Not yet implemented

- ❌ Image signing (Cosign) + admission policy requiring signatures
- ❌ SBOM generation (`trivy image --format cyclonedx`)
- ❌ Dependency pinning by hash in `package.json`

---

<a id="network-security"></a>

## 🌐 Network Security

### Exposure surface

| Component | Exposure | Restriction |
|---|---|---|
| Jenkins `:8080` | Public IP | **Your `/32` only** |
| SonarQube `:9000` | Public IP | **Your `/32` only** |
| SSH `:22` | Public IP | **Your `/32` only** |
| EKS API | Public endpoint | SigV4 + RBAC; narrow `public_access_cidrs` in prod |
| ALB `:80` | Public | Intended — it is the application |
| Worker nodes | **None** | Private subnets, no public IP |
| MySQL | **None** | ClusterIP + NetworkPolicy |

Terraform **refuses to apply** with `0.0.0.0/0` on SSH or the Jenkins UI:

```text
Error: Invalid value for variable
Refusing to open SSH (port 22) to the entire internet.
```

### NetworkPolicy matrix

| From ↓ / To → | frontend | auth | roadmap | mysql | DNS | Internet |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| **ALB / VPC** | ✅ | ❌ | ❌ | ❌ | — | — |
| **frontend** | — | ✅ | ✅ | ⛔ | ✅ | ❌ |
| **auth** | ❌ | — | ❌ | ✅ | ✅ | ❌ |
| **roadmap** | ❌ | ❌ | — | ⛔ | ✅ | ❌ |
| **mysql** | ❌ | ❌ | ❌ | — | ✅ | ⛔ |
| **monitoring** | ✅ | ✅ | ✅ | ❌ | ✅ | — |

⛔ = explicitly the interesting denial.

> ⚠️ **Enforcement must be enabled.** The AWS VPC CNI accepts and silently ignores NetworkPolicy unless configured. Verify — do not assume:
> ```bash
> kubectl exec -n ivolve deploy/frontend -- timeout 5 nc -zv mysql 3306   # must FAIL
> ```

> ⚠️ **Allow DNS first.** The `default-deny-all` policy blocks egress to CoreDNS. Both **UDP and TCP** port 53 are required — TCP handles responses over 512 bytes, and allowing only UDP produces intermittent, size-dependent resolution failures.

---

<a id="workload-hardening"></a>

## 🔒 Workload Hardening

Every pod satisfies the **`restricted`** Pod Security Standard, enforced at admission:

```yaml
metadata:
  labels:
    pod-security.kubernetes.io/enforce: restricted
```

Non-compliant pods are **rejected**, not merely flagged.

| Control | Setting | Prevents |
|---|---|---|
| Non-root | `runAsNonRoot: true`, `runAsUser: 1000/10001` | Root inside the container = root on the host after an escape |
| No escalation | `allowPrivilegeEscalation: false` | setuid-based escalation |
| No capabilities | `capabilities.drop: ["ALL"]` | `CAP_NET_RAW` packet sniffing, `CAP_SYS_ADMIN` escapes |
| Immutable rootfs | `readOnlyRootFilesystem: true` | Dropping a binary or backdooring the app |
| Seccomp | `seccompProfile: RuntimeDefault` | ~44 dangerous syscalls |
| No SA token | `automountServiceAccountToken: false` | Stolen token → Kubernetes API access |

`readOnlyRootFilesystem` requires a writable `/tmp`, supplied as a **tmpfs** `emptyDir`:

```yaml
volumes:
  - name: tmp
    emptyDir: { medium: Memory, sizeLimit: 64Mi }
```

RAM-backed, wiped on restart, and size-capped so it cannot exhaust node memory.

> 💡 Without a writable `/tmp`, gunicorn's worker heartbeat fails and workers are killed every 30 seconds; Spring Boot fails to start with `Unable to create tempDir`.

---

<a id="data-protection"></a>

## 💾 Data Protection

### Encryption at rest

| Data | Mechanism |
|---|---|
| MySQL EBS volume | `encrypted: "true"` in the StorageClass |
| Jenkins root volume | `encrypted = true` |
| Kubernetes Secrets in etcd | **KMS envelope encryption**, customer-managed key, annual rotation |
| Terraform state | S3 SSE-AES256 |
| ECR images | AES256 |

### Encryption in transit

| Path | Status |
|---|---|
| Browser → ALB | ⚠️ **HTTP** — annotations for ACM/TLS present but commented |
| ALB → pod | HTTP (inside the VPC) |
| Pod → pod | HTTP (inside the VPC) |
| Anything → AWS API | ✅ TLS, enforced on the state bucket by policy |
| kubectl → EKS | ✅ TLS + SigV4 |

### Password storage

`auth-service` uses **bcrypt with a per-user salt** (`bcrypt.gensalt()`), which is correct — adaptive, salted, and slow by design.

### Backups — a gap

| Data | Backup | Status |
|---|---|---|
| Terraform state | S3 versioning, 90 days | ✅ |
| MySQL | none | ❌ **Not implemented** |
| Jenkins config | none | ❌ Recoverable by re-running Ansible |

`reclaimPolicy: Retain` protects against accidental deletion but is **not a backup** — it does not protect against corruption. Add scheduled `VolumeSnapshot` resources via the EBS CSI driver.

---

<a id="what-is-not-secured"></a>

## ⚠️ What Is NOT Secured

Stated plainly rather than omitted.

| Gap | Risk | Fix |
|---|:---:|---|
| **No TLS on the ALB** | 🔴 High | Session cookies travel in plaintext. Add ACM + the commented annotations. |
| **No WAF** | 🟡 Medium | No protection against SQLi/XSS attempts or volumetric abuse. Add AWS WAF. |
| **Secrets as placeholders in Git** | 🟡 Medium | Mitigated by being obvious placeholders. Adopt ESO or Sealed Secrets. |
| **No MySQL backups** | 🔴 High | Data loss on volume corruption. Add `VolumeSnapshot` schedules. |
| **No image signing** | 🟡 Medium | Cannot cryptographically prove image provenance. Add Cosign. |
| **EKS API public** | 🟡 Medium | SigV4-protected but enumerable. Narrow `public_access_cidrs`. |
| **No rate limiting** | 🟡 Medium | Login brute-force is unthrottled. Add WAF rate rules or app-level limits. |
| **No runtime detection** | 🟢 Low | No Falco/GuardDuty for anomalous container behaviour. |
| **SonarQube gate is `unstable`** | 🟢 Low | Deliberate baseline choice; tighten to `error` once clean. |
| **`docker` group = root** | 🟢 Low | Accepted on a dedicated build server; use rootless Docker to remove. |

---

<a id="hardening-checklist"></a>

## ✅ Hardening Checklist

### Before any real deployment

- [ ] Replace **every** `CHANGE_ME` placeholder
- [ ] `allowed_ssh_cidrs` / `allowed_jenkins_ui_cidrs` set to your `/32`
- [ ] `SESSION_SECRET` set to 32 random bytes
- [ ] Vault password stored in a password manager
- [ ] Grafana `adminPassword` changed from `prom-operator`
- [ ] SonarQube admin password rotated (the Ansible role does this)
- [ ] ArgoCD admin password changed; bootstrap secret deleted
- [ ] GitHub PAT is **fine-grained**, scoped to one repository
- [ ] `.gitignore` verified — no `.env`, `*.tfvars`, `.vault_pass`, `*.pem`

### Verify enforcement — do not assume

```bash
# NetworkPolicy actually enforced
kubectl exec -n ivolve deploy/frontend -- timeout 5 nc -zv mysql 3306   # must FAIL

# Pods run as non-root
kubectl get pods -n ivolve -o jsonpath='{.items[*].spec.securityContext.runAsNonRoot}'

# No static AWS keys on the Jenkins server
ssh ubuntu@$JENKINS_IP 'ls ~/.aws/credentials 2>/dev/null && echo "⚠️ FOUND" || echo "✅ none"'

# IMDSv2 enforced
aws ec2 describe-instances --instance-ids $ID \
  --query 'Reservations[].Instances[].MetadataOptions.HttpTokens'      # → "required"

# ECR tags immutable
aws ecr describe-repositories \
  --query 'repositories[].[repositoryName,imageTagMutability]' --output table

# Trivy gate really blocks — pin an old base image and confirm the build fails
```

### Before production

- [ ] TLS via ACM, HTTP→HTTPS redirect
- [ ] External Secrets Operator or Sealed Secrets
- [ ] Automated MySQL snapshots, restore tested
- [ ] `single_nat_gateway = false`
- [ ] `cluster_endpoint_public_access_cidrs` narrowed
- [ ] AWS WAF on the ALB
- [ ] GuardDuty + Security Hub enabled
- [ ] CloudTrail to a dedicated, locked S3 bucket
- [ ] Alertmanager wired to a real notification channel
- [ ] Image signing with Cosign + admission enforcement

---

<a id="incident-response"></a>

## 🚨 Incident Response

### Suspected credential leak

```bash
# 1. Revoke immediately
#    GitHub → Settings → PATs → Revoke
#    AWS    → IAM → deactivate the key (if any exists)

# 2. Assess exposure — what did that identity do?
aws cloudtrail lookup-events --lookup-attributes \
  AttributeKey=Username,AttributeValue=<user> --max-results 50

# 3. Rotate everything downstream
kubectl delete secret ivolve-secret -n ivolve && <recreate>
kubectl rollout restart deploy -n ivolve

# 4. Purge from git history — the secret is compromised REGARDLESS
git filter-repo --path <file> --invert-paths
```

> ⚠️ Adding a file to `.gitignore` does **not** remove it from history. If it was ever pushed, treat it as compromised and rotate.

### Suspected container compromise

```bash
# 1. Isolate — cordon the node, do not delete the pod (you lose the evidence)
kubectl cordon <node>

# 2. Capture
kubectl logs -n ivolve <pod> --previous > incident.log
kubectl describe pod -n ivolve <pod> >> incident.log

# 3. Check what the identity could reach
kubectl auth can-i --list --as=system:serviceaccount:ivolve:<sa> -n ivolve

# 4. Replace
kubectl delete pod -n ivolve <pod>

# 5. Review the audit trail
aws logs tail /aws/eks/ivolve-dev-eks/cluster --since 1h --filter-pattern "<sa>"
```

### Audit sources

| Question | Source |
|---|---|
| Who called the AWS API? | CloudTrail |
| Who changed a Kubernetes object? | EKS audit log (`/aws/eks/<cluster>/cluster`) |
| Which flow was dropped, and by what? | VPC Flow Logs (`REJECT` entries) |
| Who deployed what, when? | Git history — every deploy is a commit |
| What was in the image? | ECR scan findings + archived Trivy reports |

---

**See also:** [ARCHITECTURE](ARCHITECTURE.md) · [RUNBOOK](RUNBOOK.md) · [CICD](CICD.md)
