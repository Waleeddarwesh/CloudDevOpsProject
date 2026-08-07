# 🔧 Troubleshooting

Symptom-driven fixes for problems this stack actually produces during **setup and build**.

For **runtime incidents** (something that was working has broken), use [RUNBOOK.md](RUNBOOK.md) instead.

---

## 📑 Contents

- [Docker Compose](#docker-compose)
- [Terraform](#terraform)
- [Ansible](#ansible)
- [Kubernetes](#kubernetes)
- [Jenkins](#jenkins)
- [ArgoCD](#argocd)
- [Monitoring](#monitoring)
- [Diagnostic cheat sheet](#diagnostic-cheat-sheet)

---

<a id="docker-compose"></a>

## 🐳 Docker Compose

### `MYSQL_ROOT_PASSWORD is required — copy .env.example to .env`

Working as designed. The Compose file uses `${VAR:?message}` so a missing value fails at parse time rather than silently starting MySQL with an empty root password.

```bash
cp 01-Docker/.env.example 01-Docker/.env
# replace every CHANGE_ME
```

### `auth-service` restarting repeatedly on first run

```bash
docker compose logs auth-service | head -30
```

| Log line | Cause | Fix |
|---|---|---|
| `Missing database environment variables: DB_USER` | Wrong variable name | `app.py` reads **`DB_USER`**, not `DB_USERNAME` |
| `Access denied for user 'ivolve_user'` | MySQL initialised with a different password | `docker compose down -v` then `up` — the volume holds the old credentials |
| `Can't connect to MySQL server` | Started before MySQL was ready | Confirm `condition: service_healthy` is present |

> 💡 **`down -v` is the fix for most first-run database problems.** MySQL only reads `MYSQL_PASSWORD` when the data directory is empty. Changing `.env` after the first boot has no effect until the volume is deleted.

### `port is already allocated`

```bash
# Linux/macOS
lsof -i :3000
# Windows
netstat -ano | findstr :3000
```

Change the host side of the mapping: `"3001:3000"`.

### `the attribute 'version' is obsolete`

Not from this project — you are running an older Compose file. This one has no `version:` key.

### Build is very slow or fails on `npm install` / `mvn`

```bash
docker builder prune -af
docker compose build --no-cache
```

Behind a proxy, pass build args for `HTTP_PROXY`/`HTTPS_PROXY`.

---

<a id="terraform"></a>

## 🏗️ Terraform

### `Refusing to open SSH (port 22) to the entire internet`

A deliberate validation block, not a bug.

```hcl
allowed_ssh_cidrs        = ["203.0.113.9/32"]   # curl -s https://checkip.amazonaws.com
allowed_jenkins_ui_cidrs = ["203.0.113.9/32"]
```

### `Error: Invalid count argument`

```text
The "count" value depends on resource attributes that cannot be determined
until apply.
```

`count` must be resolvable at **plan** time. This exact bug was found and fixed in `modules/eks/access.tf` — see `create_jenkins_access_entry` in `modules/eks/variables.tf`.

**Rule:** never derive `count` from another resource's attribute. Use a `bool` variable.

### `Error: Cycle: module.server..., module.eks...`

Two modules reference each other's outputs. Break the cycle by passing a **value known at plan time** — this project passes `local.cluster_name` to the server module and reconstructs the ARN there, rather than reading `module.eks.cluster_arn`.

### `BucketAlreadyExists`

S3 bucket names are globally unique across **all** AWS accounts. The bootstrap module embeds your account ID; if it still collides, change `project_name`.

### `Backend configuration changed`

```bash
terraform init -reconfigure -backend-config=backend.hcl
# to move existing state into the new backend:
terraform init -migrate-state -backend-config=backend.hcl
```

### `Error acquiring the state lock`

```bash
# Confirm nobody else is applying, then:
terraform force-unlock <LOCK_ID>
```

> ⚠️ Only after confirming no other apply is running. Force-unlocking a live apply corrupts state.

### `InvalidKeyPair.NotFound`

The key pair does not exist **in that region**.

```bash
aws ec2 describe-key-pairs --key-names ivolve-key --region us-east-1
```

### EKS apply hangs then times out

Normal duration is 10-15 min for the control plane, 5 for nodes. If nodes never join:

```bash
aws eks describe-nodegroup --cluster-name ivolve-dev-eks --nodegroup-name ivolve-dev-eks-nodes \
  --query 'nodegroup.health'
```

Usually a missing IAM policy or no NAT route (nodes cannot reach the EKS API to register).

### `terraform destroy` hangs on the VPC

```text
DependencyViolation: The subnet has dependencies and cannot be deleted
```

An orphaned ALB from the Ingress. **Delete the Ingress first:**

```bash
kubectl delete ingress frontend -n ivolve
# then find leftovers
aws elbv2 describe-load-balancers --query 'LoadBalancers[?VpcId==`vpc-xxx`].LoadBalancerArn'
```

---

<a id="ansible"></a>

## 🤖 Ansible

### `skipping: no hosts matched`

The three causes, in order of likelihood:

1. **Plugin not enabled** — `ansible.cfg` must contain:
   ```ini
   [inventory]
   enable_plugins = amazon.aws.aws_ec2
   ```
2. **Filename wrong** — it *must* end `aws_ec2.yml` or `aws_ec2.yaml`.
3. **Tag mismatch** — Terraform sets `Role = jenkins`; the inventory filters `tag:Role: jenkins`.

```bash
ansible-inventory --graph -vvv
aws ec2 describe-instances --filters "Name=tag:Role,Values=jenkins" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output table
```

### Inventory shows a stale/dead host

```bash
ansible-inventory --graph --flush-cache
rm -rf .ansible_inventory_cache
```

### `UNREACHABLE ... Permission denied (publickey)`

```bash
chmod 400 ~/.ssh/ivolve-key.pem
ssh -i ~/.ssh/ivolve-key.pem ubuntu@<IP>     # test directly
```

If SSH itself times out, your public IP changed — update `allowed_ssh_cidrs` and re-apply Terraform.

### `Could not get lock /var/lib/dpkg/lock-frontend`

Terraform's `user_data` is still running. The playbook waits on `/etc/ivolve-bootstrap-complete`; if it timed out:

```bash
ssh ubuntu@<IP> 'sudo tail -20 /var/log/user-data.log'
```

### `Attempting to decrypt but no vault secrets found`

```bash
cd 03-Ansible
openssl rand -base64 32 > .vault_pass && chmod 600 .vault_pass
# or run with --ask-vault-pass
```

### Jenkins service dead immediately after install

Java is missing — the `java` role must run before `jenkins`.

```bash
ssh ubuntu@<IP> 'java -version; sudo systemctl status jenkins; sudo journalctl -u jenkins -n 50'
```

### SonarQube container exits immediately

```bash
ssh ubuntu@<IP> 'sudo docker compose -f /opt/sonarqube/docker-compose.yml logs sonarqube | tail -30'
```

| Error | Fix |
|---|---|
| `max virtual memory areas vm.max_map_count [65530] is too low` | `sudo sysctl -w vm.max_map_count=262144` — the `common` role sets this |
| `max file descriptors ... too low` | The `ulimits` block in the Compose template |
| Out of memory | t3.medium is tight with Jenkins + SonarQube. Use t3.large, or `--skip-tags sonarqube` |

---

<a id="kubernetes"></a>

## ☸️ Kubernetes

### PVC stuck `Pending`

**The single most common EKS problem.** In order:

```bash
kubectl describe pvc data-mysql-0 -n ivolve      # read the Events
kubectl get storageclass
kubectl get pods -n kube-system -l app=ebs-csi-controller
```

| Cause | Check | Fix |
|---|---|---|
| **EBS CSI driver missing** | `aws eks describe-addon --addon-name aws-ebs-csi-driver …` | Unbundled since EKS 1.23 — install the add-on |
| **Wrong provisioner** | `kubectl get sc ivolve-storage -o yaml` | Must be `ebs.csi.aws.com`; `kubernetes.io/aws-ebs` was removed in 1.27 |
| **IRSA role missing** | `kubectl logs -n kube-system -l app=ebs-csi-controller -c ebs-plugin` | Driver runs but cannot `CreateVolume` |
| `WaitForFirstConsumer` | PVC Pending with **no pod yet** | Normal — it binds when a pod is scheduled |

### `volume node affinity conflict`

The EBS volume is in a different AZ from the node. The StorageClass **must** use `volumeBindingMode: WaitForFirstConsumer`.

```bash
kubectl get pv <pv> -o jsonpath='{.spec.nodeAffinity}'
kubectl get pod mysql-0 -n ivolve -o jsonpath='{.spec.nodeName}'
```

### Ingress `ADDRESS` stays empty

```bash
kubectl describe ingress frontend -n ivolve
kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=50
```

| Cause | Fix |
|---|---|
| Controller not installed | Install it — the Ingress is inert without a controller |
| `couldn't auto-discover subnets` | Subnets need `kubernetes.io/role/elb=1` (Terraform sets these) |
| IRSA role missing/wrong | Check the ServiceAccount annotation |
| Wrong ingress class | Must be `spec.ingressClassName: alb`, not the deprecated annotation |

### HPA shows `<unknown>/70%`

metrics-server is not installed.

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm install metrics-server metrics-server/metrics-server -n kube-system
kubectl top nodes
```

### NetworkPolicy has no effect

```bash
kubectl exec -n ivolve deploy/frontend -- timeout 5 nc -zv mysql 3306
```

If this **succeeds**, enforcement is off. The AWS VPC CNI accepts and silently ignores NetworkPolicy by default:

```bash
aws eks update-addon --cluster-name ivolve-dev-eks --addon-name vpc-cni \
  --configuration-values '{"enableNetworkPolicy":"true"}' --resolve-conflicts OVERWRITE
```

### Everything breaks right after applying NetworkPolicies

You blocked DNS. The `default-deny-all` policy denies egress to CoreDNS, so nothing can resolve any service name.

```bash
kubectl get networkpolicy allow-dns-egress -n ivolve
kubectl exec -n ivolve deploy/frontend -- nslookup auth-service
```

Both **UDP and TCP** port 53 are required.

### `error: You must be logged in to the server (Unauthorized)`

IAM permissions alone grant nothing inside the cluster.

```bash
aws sts get-caller-identity
aws eks list-access-entries --cluster-name ivolve-dev-eks
```

The identity that ran `terraform apply` has admin via `bootstrap_cluster_creator_admin_permissions`. A *different* identity needs an entry in `cluster_admin_principals`.

### Pod rejected at admission

```text
violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false
```

The namespace enforces the `restricted` Pod Security Standard. The pod needs the full securityContext — `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile: RuntimeDefault`.

### `exceeded quota`

```bash
kubectl describe resourcequota ivolve-quota -n ivolve
```

Either lower requests, or raise the quota in `00-namespace.yaml`.

---

<a id="jenkins"></a>

## ⚙️ Jenkins

### `unable to resolve class` on `@Library`

The trailing underscore is missing:

```groovy
@Library('shared-library') _
```

### `No such DSL method 'microservicePipeline'`

`vars/` is not at the **root** of the library repository. See [Phase 5 § shared library](../05-Jenkins/README.md#3-set-up-the-shared-library).

Then: *Manage Jenkins → System → Global Pipeline Libraries* — confirm the name matches `@Library('...')` exactly.

### `docker: permission denied ... /var/run/docker.sock`

```bash
ssh ubuntu@<IP> 'groups jenkins'          # should include 'docker'
ssh ubuntu@<IP> 'sudo usermod -aG docker jenkins && sudo systemctl restart jenkins'
```

> 💡 Group membership only applies to **new** processes — Jenkins must be restarted.

### `no basic auth credentials` on `docker push`

```bash
ssh ubuntu@<IP> 'aws sts get-caller-identity'
```

Should show `assumed-role/ivolve-dev-jenkins-role`. If it errors, the instance profile is not attached or the region is wrong.

### `waitForQualityGate` hangs until timeout

The SonarQube webhook is not configured.

SonarQube → *Administration → Configuration → Webhooks → Create*
URL: `http://<JENKINS_IP>:8080/sonarqube-webhook/` (the trailing slash matters).

### Manifest push rejected — `non-fast-forward`

Two pipelines raced. Handled by the rebase-retry in `updateManifests.groovy`. If persistent, verify `disableConcurrentBuilds()` is in the pipeline options.

### Builds trigger each other forever

`[skip ci]` is missing from the commit message, or the webhook ignores it.

```bash
git log --oneline -5      # every ci(...) commit must contain [skip ci]
```

### `no space left on device`

```bash
ssh ubuntu@<IP> 'df -h; docker system df'
ssh ubuntu@<IP> 'docker system prune -af --volumes'
```

The Ansible role installs a nightly prune cron; raise `jenkins_root_volume_size` if it recurs.

---

<a id="argocd"></a>

## 🔄 ArgoCD

### `application repo ... is not permitted in project`

The `repoURL` in the Application must appear in `sourceRepos` in `project.yaml`.

### `resource ... is not permitted in project`

Add the kind to `namespaceResourceWhitelist` or `clusterResourceWhitelist` in `project.yaml`.

> 💡 `ClusterRole`/`ClusterRoleBinding` are excluded **on purpose** — they are the privilege-escalation path.

### `ComparisonError: repository not accessible`

```bash
argocd repo add https://github.com/<user>/CloudDevOpsProject.git \
  --username <user> --password <PAT>
```

### Application never appears

It must be created in the `argocd` namespace. Anywhere else, it is silently ignored.

### Perpetually `OutOfSync` on `/spec/replicas`

The HPA owns that field. Already handled by `ignoreDifferences` — verify it is present.

### Deleting the Application leaves pods running

The finalizer is missing:

```yaml
finalizers:
  - resources-finalizer.argocd.argoproj.io
```

### Slow to notice a commit

3-minute default poll. Add a GitHub webhook to `https://<argocd-host>/api/webhook`.

---

<a id="monitoring"></a>

## 📊 Monitoring

### ServiceMonitor / Probe never scraped

The chart's default selector restricts discovery to objects labelled `release=monitoring`. The values file sets:

```yaml
serviceMonitorSelectorNilUsesHelmValues: false
probeSelectorNilUsesHelmValues: false
ruleSelectorNilUsesHelmValues: false
```

Verify in Prometheus → **Status → Configuration**.

### Prometheus pod `Pending`

No PVC could bind — see [PVC Pending](#pvc-stuck-pending).

### Prometheus OOM-killed

Retention exceeds the memory limit. Lower `retention`/`retentionSize`, or raise the limit.

### Four permanently-firing "target down" alerts

EKS control-plane components are AWS-managed and unreachable. Already disabled in the values file:

```yaml
kubeControllerManager: { enabled: false }
kubeScheduler:         { enabled: false }
kubeEtcd:              { enabled: false }
```

### `probe_success` returns nothing

```bash
kubectl get svc -n monitoring | grep blackbox
```

The blackbox-exporter is a **separate** Helm chart — install it.

### Grafana dashboard not imported

The ConfigMap needs `grafana_dashboard: "1"`.

```bash
kubectl get cm -n monitoring -l grafana_dashboard=1
kubectl logs -n monitoring deploy/monitoring-grafana -c grafana-sc-dashboard
```

---

<a id="diagnostic-cheat-sheet"></a>

## 🩺 Diagnostic Cheat Sheet

```bash
# ── Kubernetes ────────────────────────────────────────────────
kubectl get all,ingress,pvc,hpa,pdb -n ivolve
kubectl get events -A --sort-by='.lastTimestamp' | tail -30
kubectl logs -n ivolve <pod> --previous          # WHY IT DIED
kubectl describe pod -n ivolve <pod> | tail -25
kubectl top pods -n ivolve

# ── Connectivity ──────────────────────────────────────────────
kubectl exec -n ivolve deploy/frontend -- nslookup auth-service
kubectl exec -n ivolve deploy/frontend -- wget -qO- --timeout=3 http://auth-service:5000/health
kubectl get endpoints -n ivolve

# ── AWS ───────────────────────────────────────────────────────
aws sts get-caller-identity
aws eks describe-cluster --name ivolve-dev-eks --query 'cluster.status'
aws eks list-addons --cluster-name ivolve-dev-eks
aws ecr describe-repositories --query 'repositories[].repositoryName'

# ── Terraform ─────────────────────────────────────────────────
terraform -chdir=02-Terraform output
terraform -chdir=02-Terraform state list
terraform -chdir=02-Terraform plan          # read-only drift check

# ── Ansible ───────────────────────────────────────────────────
cd 03-Ansible && ansible-inventory --graph --flush-cache
cd 03-Ansible && ansible role_jenkins -m ping
cd 03-Ansible && ansible-playbook playbook.yml --check --diff

# ── Validate everything before pushing ────────────────────────
make lint
```

### Log locations

| What | Where |
|---|---|
| EC2 first-boot | `/var/log/user-data.log` |
| Jenkins | `sudo journalctl -u jenkins -f` |
| SonarQube | `sudo docker compose -f /opt/sonarqube/docker-compose.yml logs -f` |
| Ansible run | `03-Ansible/ansible.log` |
| EKS control plane | CloudWatch `/aws/eks/ivolve-dev-eks/cluster` |
| VPC flow logs | CloudWatch `/aws/vpc/ivolve-dev/flow-logs` |
| Pod | `kubectl logs -n ivolve <pod>` |

---

## 🆘 Still stuck?

1. **`kubectl get events`** — the answer is there more often than people expect.
2. **`--previous` on logs** — the dead container's output, not the restarting one's.
3. **VPC Flow Logs** — a `REJECT` entry names which SG or NACL dropped the packet, which is otherwise invisible.
4. **`terraform plan`** — read-only, and shows any drift from code.
5. **Reproduce locally** — `make up`. If it works there, the problem is infrastructure, not application code.

---

**See also:** [RUNBOOK](RUNBOOK.md) (runtime incidents) · [SETUP](SETUP.md) (installation) · [ARCHITECTURE](ARCHITECTURE.md#known-limitations) (known limitations)
