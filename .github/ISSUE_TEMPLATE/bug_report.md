---
name: Bug report
about: Something is broken
title: "[BUG] "
labels: bug
assignees: ""
---

## Layer

- [ ] `src/` application or Dockerfile
- [ ] `01-Docker` Compose
- [ ] `02-Terraform` infrastructure
- [ ] `03-Ansible` server configuration
- [ ] `04-Kubernetes` manifests
- [ ] `05-Jenkins` pipeline
- [ ] `06-ArgoCD` deployment
- [ ] `07-Monitoring` observability
- [ ] Documentation

## What happens

## What should happen

## Reproduction

```bash
1.
2.
3.
```

## Output

<!-- The ACTUAL error. Not a description of it. -->

```text

```

## Diagnostics

<!-- Whichever apply. See docs/TROUBLESHOOTING.md for the full cheat sheet. -->

```text
kubectl get events -n ivolve --sort-by='.lastTimestamp' | tail -20

kubectl logs -n ivolve <pod> --previous

terraform -chdir=02-Terraform plan
```

## Environment

| | |
|---|---|
| OS | |
| Terraform | `terraform version` |
| kubectl | `kubectl version --client` |
| Kubernetes / EKS | |
| AWS region | |

## Already checked

- [ ] [docs/TROUBLESHOOTING.md](../../docs/TROUBLESHOOTING.md)
- [ ] [docs/RUNBOOK.md](../../docs/RUNBOOK.md)
- [ ] [Known Limitations](../../docs/ARCHITECTURE.md#known-limitations)
