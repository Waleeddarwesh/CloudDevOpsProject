## Summary

<!-- What does this change and why? One or two sentences. -->

## Type

- [ ] `feat` — new capability
- [ ] `fix` — bug fix
- [ ] `docs` — documentation only
- [ ] `refactor` — no behaviour change
- [ ] `perf` — performance
- [ ] `build` / `ci` / `chore`

## Layers touched

- [ ] `src/` — application or Dockerfile
- [ ] `01-Docker` — Compose
- [ ] `02-Terraform` — infrastructure
- [ ] `03-Ansible` — server configuration
- [ ] `04-Kubernetes` — manifests
- [ ] `05-Jenkins` — pipeline
- [ ] `06-ArgoCD` — deployment
- [ ] `07-Monitoring` — observability
- [ ] `docs/`

---

## Validation

<!-- Paste the actual output, not a claim that it passed. -->

```text

```

- [ ] `make lint` passes
- [ ] `terraform plan` reviewed — **paste the resource summary line**
- [ ] `make k8s-validate` → `Valid: N, Invalid: 0`
- [ ] Ansible `--check --diff` reviewed
- [ ] Tested locally with `make up`

## Terraform impact

<!-- Delete if not applicable. -->

```text
Plan: _ to add, _ to change, _ to destroy.
```

- [ ] **No unintended `destroy`** — check carefully for resources that would be replaced
- [ ] No `force_replacement` on a stateful resource (EBS volume, ECR repository, RDS)

---

## Security

- [ ] No secret, credential, private IP or account ID added
- [ ] No new `0.0.0.0/0` ingress rule
- [ ] No new IAM wildcard (`Resource: "*"`) without justification below
- [ ] New pods satisfy the `restricted` Pod Security Standard
- [ ] New service-to-service traffic has a matching NetworkPolicy

<!-- Justify any wildcard or exception here: -->

## Rollback plan

<!-- How is this undone if it goes wrong in production? -->

---

## Related

Closes #
ADR: `docs/adr/`
