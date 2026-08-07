# Contributing

## 🌳 Branching

```text
main            ← protected · always deployable · ArgoCD tracks this
 ├── feat/…     new capability
 ├── fix/…      bug fix
 ├── docs/…     documentation only
 ├── chore/…    tooling, dependencies
 └── refactor/… no behaviour change
```

`main` is protected. All changes arrive via pull request with a green CI run and one approval.

---

## ✍️ Commit Convention

[Conventional Commits](https://www.conventionalcommits.org/) — this makes the history machine-readable and lets a changelog be generated automatically.

```text
<type>(<scope>): <subject>

[body]

[footer]
```

| Type | Use for |
|---|---|
| `feat` | New capability |
| `fix` | Bug fix |
| `docs` | Documentation |
| `refactor` | Restructuring with no behaviour change |
| `perf` | Performance improvement |
| `test` | Tests |
| `build` | Dockerfiles, dependencies |
| `ci` | Pipelines, GitHub Actions |
| `chore` | Everything else |

Scopes: `docker`, `terraform`, `ansible`, `k8s`, `jenkins`, `argocd`, `monitoring`, `docs`.

```text
feat(terraform): add per-AZ NAT gateway option

Adds single_nat_gateway variable. Defaults to true for cost;
set false for production HA.

Closes #42
```

> ⚠️ The Jenkins pipeline generates commits containing `[skip ci]`. Never remove that marker — without it each build triggers another build in an infinite loop.

---

## ✅ Before Opening a PR

```bash
make lint          # terraform fmt+validate, compose config, kubeconform, ansible-lint
```

| Layer changed | Also run |
|---|---|
| `02-Terraform/` | `terraform plan` — read it |
| `04-Kubernetes/` | `make k8s-validate` |
| `03-Ansible/` | `ansible-playbook playbook.yml --check --diff` |
| `01-Docker/` or `src/` | `make up` and exercise the app |
| `05-Jenkins/vars/` | Run one pipeline end to end |

### Definition of done

- [ ] `make lint` passes
- [ ] New code carries the same comment density as its neighbours — explain **why**, not what
- [ ] Documentation updated (phase README and/or `docs/`)
- [ ] No secret, IP address or account ID committed
- [ ] `terraform plan` shows only the intended changes
- [ ] An ADR added under `docs/adr/` for any significant architectural decision

---

## 🎨 Code Style

Enforced by `.editorconfig`.

| Language | Indent | Notes |
|---|:---:|---|
| YAML | 2 | Never tabs — a hard parse error |
| HCL | 2 | `terraform fmt` is authoritative |
| Groovy | 4 | |
| Shell | 4 | LF endings; CRLF breaks the shebang |
| Python | 4 | |
| Makefile | **tab** | Mandatory |

### Comments

This repository is documentation as much as it is code. Comments explain **why a choice was made** and **what breaks without it**:

```hcl
# ✅ good
# WaitForFirstConsumer delays volume creation until the pod is scheduled, so the
# EBS volume lands in the same AZ as its node. With `Immediate`, a two-AZ cluster
# is a coin flip between working and `volume node affinity conflict`.
volume_binding_mode = "WaitForFirstConsumer"

# ❌ useless
# set the volume binding mode
volume_binding_mode = "WaitForFirstConsumer"
```

---

## 🔐 Security

**Never commit:** `.env`, `*.tfvars`, `.vault_pass`, `*.pem`, real Secret values, account IDs in new code, or your IP address.

Gitleaks runs in CI against the **full history**, not just the tip.

> ⚠️ Adding a file to `.gitignore` does not remove it from history. If a secret was ever pushed, **rotate it** — it is compromised regardless of what you do next.

Vulnerabilities: see [SECURITY.md](SECURITY.md).

---

## 📐 Adding a New Microservice

1. `src/<name>/` with a hardened multi-stage `Dockerfile` and `.dockerignore`
2. Add a service to `01-Docker/docker-compose.yml`
3. Add the repository name to `ecr_repository_names` in `terraform.tfvars`
4. Add `04-Kubernetes/manifests/NN-<name>.yaml` — Deployment, Service, HPA, PDB
5. Add it to `resources:` and `images:` in `kustomization.yaml`
6. Add NetworkPolicy rules in `09-network-policies.yaml`
7. Add `05-Jenkins/Jenkinsfiles/<name>.Jenkinsfile` (~15 lines)
8. Add the probe target in `07-Monitoring/manifests/01-blackbox-probes.yaml`
9. Update the phase READMEs

---

## 📋 Architecture Decision Records

Significant decisions get an ADR in [`docs/adr/`](docs/adr/). Copy `docs/adr/0000-template.md`.

Write one when the decision is hard to reverse, involves a real trade-off, or someone will ask "why on earth is it like this?" in six months.
