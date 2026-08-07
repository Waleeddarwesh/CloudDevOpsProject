# Security Policy

## 📢 Reporting a Vulnerability

**Do not open a public issue for a security vulnerability.**

Email **Waleeddarweshsaad1@gmail.com** with:

- Component affected (Terraform module, Kubernetes manifest, pipeline step, …)
- Steps to reproduce
- Impact assessment
- Suggested remediation, if you have one

Expected response: acknowledgement within 48 hours, assessment within 5 working days.

---

## 🔍 Scope

### In scope

- Infrastructure code — Terraform modules, IAM policies, security groups, NACLs
- Kubernetes manifests — RBAC, NetworkPolicy, Pod Security, secrets handling
- CI/CD — the Jenkins shared library, GitHub Actions workflows
- Container images — the `Dockerfile`s under `src/`
- Documentation that would lead an operator into an insecure configuration

### Out of scope

- The **application logic** under `src/` (`server.js`, `app.py`, `RoadmapController.java`) — vendored unmodified from [upstream](https://github.com/Ibrahim-Adel15/iVolveFinalProject); report those upstream
- Anything listed under [Known Limitations](docs/ARCHITECTURE.md#known-limitations) or [What Is NOT Secured](docs/SECURITY.md#what-is-not-secured) — already documented and accepted
- Findings that require the deliberate placeholder credentials to have been left in place

---

## 🛡️ Security Controls

Full detail in **[docs/SECURITY.md](docs/SECURITY.md)**. Summary:

| Layer | Control |
|---|---|
| Credentials | **Zero static AWS keys** — instance profile + IRSA only |
| Metadata | IMDSv2 enforced (`http_tokens = required`) |
| Secrets at rest | KMS envelope encryption of etcd; Ansible Vault; encrypted EBS and S3 |
| Network | Public + private NACLs, VPC flow logs, default-deny NetworkPolicy |
| Workloads | Pod Security Standard `restricted` enforced at admission |
| Registry | Immutable ECR tags, scan-on-push |
| Supply chain | Trivy (blocking), SonarQube, Checkov, Gitleaks, hadolint |
| Access | EKS Access Entries scoped to `EDIT` on one namespace for CI |

---

## 🤖 Automated Scanning

Runs on every push and pull request ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)):

| Tool | Target | Blocking |
|---|---|:---:|
| Gitleaks | Full git history | ✅ |
| Trivy | Container images (in Jenkins) | ✅ |
| Trivy config | Kubernetes manifests | ❌ report |
| Checkov | Terraform | ❌ report |
| hadolint | Dockerfiles | ✅ on error |
| SonarQube | Source (in Jenkins) | ⚠️ unstable |

---

## ⚠️ Placeholder Credentials

Several files ship with **deliberate placeholders** (`CHANGE_ME_*`). These are not vulnerabilities — they are documented required-configuration markers:

| File | Purpose |
|---|---|
| `01-Docker/.env.example` | Local development template |
| `02-Terraform/terraform.tfvars.example` | Infrastructure variables template |
| `03-Ansible/group_vars/all/vault.yml.example` | Vault contents template |
| `04-Kubernetes/manifests/02-config.yaml` | Secret keys, annotated with a warning |
| `07-Monitoring/kube-prometheus-stack-values.yaml` | Grafana admin password |

Deploying without replacing them is a misconfiguration, and the [hardening checklist](docs/SECURITY.md#hardening-checklist) exists to catch it.
