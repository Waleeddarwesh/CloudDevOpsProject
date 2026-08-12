# 🚀 Setup Guide

Zero to a fully running platform. Every step lists the command, the expected output, and what to do when it goes wrong.

**Total time:** ~60 minutes, most of it waiting for EKS.

---

## 📑 Contents

- [Prerequisites](#prerequisites)
- [Stage 0 — Local verification](#stage-0--local-verification)
- [Stage 1 — AWS infrastructure](#stage-1--aws-infrastructure)
- [Stage 2 — Jenkins server](#stage-2--jenkins-server)
- [Stage 3 — Cluster add-ons](#stage-3--cluster-add-ons)
- [Stage 4 — Application](#stage-4--application)
- [Stage 5 — ArgoCD](#stage-5--argocd)
- [Stage 6 — CI pipelines](#stage-6--ci-pipelines)
- [Stage 7 — Monitoring](#stage-7--monitoring)
- [Verification checklist](#verification-checklist)
- [Teardown](#teardown)

---

<a id="prerequisites"></a>

## ✅ Prerequisites

### Tools

| Tool | Minimum | Check |
|---|---|---|
| Terraform | **1.10** (for `use_lockfile`) | `terraform version` |
| AWS CLI | 2.x | `aws --version` |
| kubectl | 1.30+ | `kubectl version --client` |
| Helm | 3.x | `helm version --short` |
| Ansible | core 2.15+ | `ansible --version` |
| Docker | 24+ with Compose v2 | `docker compose version` |
| Git | 2.x | `git --version` |

```bash
# Ansible + the AWS SDK it needs
pip install ansible-core boto3 botocore
```

### AWS

```bash
aws sts get-caller-identity
```
```json
{ "Account": "991216470475", "Arn": "arn:aws:iam::991216470475:user/Waleeddarwesh" }
```

Permissions required: VPC, EC2, EKS, ECR, IAM, KMS, S3, CloudWatch.

### EC2 key pair

```bash
aws ec2 create-key-pair --key-name ivolve-key \
  --query KeyMaterial --output text > ~/.ssh/ivolve-key.pem
chmod 400 ~/.ssh/ivolve-key.pem
```

> 💡 **PowerShell:** `>` corrupts the key encoding. Use:
> ```powershell
> aws ec2 create-key-pair --key-name ivolve-key --query KeyMaterial --output text |
>   Out-File -Encoding ascii $HOME\.ssh\ivolve-key.pem
> ```

### Your public IP

```bash
curl -s https://checkip.amazonaws.com
```

You will need this twice. Terraform **refuses to apply** with `0.0.0.0/0`.

### GitHub token

Create a **fine-grained PAT**: *Settings → Developer settings → Personal access tokens → Fine-grained*
Repository access: **only** `CloudDevOpsProject`. Permissions: **Contents → Read and write**.

> ⚠️ Do not use a classic token with full `repo` scope — it grants access to every repository you own.

---

<a id="stage-0--local-verification"></a>

## 🐳 Stage 0 — Local verification

**~5 minutes.** Prove the application works before spending money on AWS.

```bash
git clone https://github.com/WaleedDarwesh/CloudDevOpsProject.git
cd CloudDevOpsProject

cp 01-Docker/.env.example 01-Docker/.env
```

Fill in `01-Docker/.env`:

```bash
openssl rand -base64 24   # run 3× — root pw, app pw, session secret
```

```bash
make up
```

Expected:

```text
 ✔ Container ivolve-mysql            Healthy
 ✔ Container ivolve-roadmap-service  Healthy
 ✔ Container ivolve-auth-service     Healthy
 ✔ Container ivolve-frontend         Started
```

Verify:

```bash
make ps                                        # all four (healthy)
curl -s http://localhost:5000/health            # {"status":"UP"}
curl -s http://localhost:8080/api/roadmap | head -c 80
```

Open <http://localhost:3000>, sign up, log in, see the roadmap.

```bash
make down
```

> 🎯 **Checkpoint:** if this works, the application and images are sound. Anything that breaks later is infrastructure, not code.

---

<a id="stage-1--aws-infrastructure"></a>

## 🏗️ Stage 1 — AWS infrastructure

**~20 minutes**, mostly EKS.

### 1.1 Create the state bucket

```bash
make tf-bootstrap
```

```text
Apply complete! Resources: 7 added, 0 changed, 0 destroyed.

Outputs:
state_bucket_name = "ivolve-tfstate-991216470475-us-east-1"
```

### 1.2 Configure the backend

```bash
cp 02-Terraform/backend.hcl.example 02-Terraform/backend.hcl
```

```hcl
bucket = "ivolve-tfstate-991216470475-us-east-1"   # ← from above
key    = "capstone/dev/terraform.tfstate"
region = "us-east-1"
```

### 1.3 Set your variables

```bash
cp 02-Terraform/terraform.tfvars.example 02-Terraform/terraform.tfvars
```

Edit the two required values:

```hcl
allowed_ssh_cidrs        = ["203.0.113.9/32"]   # ← YOUR IP
allowed_jenkins_ui_cidrs = ["203.0.113.9/32"]   # ← YOUR IP
```

### 1.4 Apply

```bash
make tf-init
make tf-plan     # read it — should say: Plan: 81 to add, 0 to change, 0 to destroy
make tf-apply
```

⏱ **15-20 minutes.**

```text
Apply complete! Resources: 81 added, 0 changed, 0 destroyed.

Outputs:
ecr_registry      = "991216470475.dkr.ecr.us-east-1.amazonaws.com"
eks_cluster_name  = "ivolve-dev-eks"
jenkins_public_ip = "54.211.x.x"
```

```bash
make tf-output
```

> 🔧 **`InvalidKeyPair.NotFound`** → the key pair does not exist in this region. Re-run the key-pair command from Prerequisites.
> 🔧 **`UnauthorizedOperation`** → insufficient IAM permissions.
> 🔧 **`BucketAlreadyExists`** → someone else owns that global name; change `project_name`.

---

<a id="stage-2--jenkins-server"></a>

## 🤖 Stage 2 — Jenkins server

**~12 minutes.**

### 2.1 Install dependencies

```bash
make ansible-deps
```

### 2.2 Create the vault

```bash
cd 03-Ansible
openssl rand -base64 32 > .vault_pass
chmod 600 .vault_pass

cp group_vars/all/vault.yml.example group_vars/all/vault.yml
# edit it — replace every CHANGE_ME
ansible-vault encrypt group_vars/all/vault.yml
head -1 group_vars/all/vault.yml     # → $ANSIBLE_VAULT;1.1;AES256
cd ..
```

> ⚠️ Store the vault password in a password manager. Lose it and the vault is unrecoverable.

### 2.3 Verify discovery

```bash
make ansible-inventory
```
```text
@all:
  |--@role_jenkins:
  |  |--ivolve-dev-jenkins
```

```bash
cd 03-Ansible && ansible role_jenkins -m ping && cd ..
```

> 🔧 **Empty inventory** → `ansible-inventory --graph --flush-cache`, or your IP changed (update `allowed_ssh_cidrs` and re-apply Terraform).

### 2.4 Run the playbook

```bash
make ansible-run
```

⏱ **8-12 minutes.**

```text
PLAY RECAP ****************************************************
ivolve-dev-jenkins : ok=68  changed=41  unreachable=0  failed=0
```

The summary prints the Jenkins URL and initial admin password.

### 2.5 Prove idempotency

```bash
make ansible-run     # → changed=0
```

---

<a id="stage-3--cluster-add-ons"></a>

## ☸️ Stage 3 — Cluster add-ons

**~5 minutes.** These are **required** — the Ingress and HPAs do not work without them.

### 3.1 Connect kubectl

```bash
make kubeconfig
kubectl get nodes
```
```text
NAME                         STATUS   ROLES    AGE   VERSION
ip-10-0-10-42.ec2.internal   Ready    <none>   5m    v1.31.x
ip-10-0-11-88.ec2.internal   Ready    <none>   5m    v1.31.x
```

```bash
kubectl get nodes -L topology.kubernetes.io/zone    # confirm two AZs
```

### 3.2 AWS Load Balancer Controller

**Without this, the Ingress never produces an ALB.**

```bash
helm repo add eks https://aws.github.io/eks-charts && helm repo update

LBC_ROLE=$(terraform -chdir=02-Terraform output -raw aws_load_balancer_controller_role_arn)

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=ivolve-dev-eks \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$LBC_ROLE" \
  --wait
```

```bash
kubectl get deploy -n kube-system aws-load-balancer-controller
```

### 3.3 Metrics Server

**Without this, every HPA reports `<unknown>/70%` and never scales.**

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm install metrics-server metrics-server/metrics-server -n kube-system --wait
kubectl top nodes
```

### 3.4 Enable NetworkPolicy enforcement

**Without this, the NetworkPolicies are accepted and silently ignored.**

```bash
aws eks update-addon --cluster-name ivolve-dev-eks --addon-name vpc-cni \
  --configuration-values '{"enableNetworkPolicy":"true"}' --resolve-conflicts OVERWRITE
```

---

<a id="stage-4--application"></a>

## 📦 Stage 4 — Application

### 4.1 Point the manifests at your registry

```bash
cd 04-Kubernetes/manifests
REGISTRY=$(terraform -chdir=../../02-Terraform output -raw ecr_registry)

kustomize edit set image ivolve-frontend=$REGISTRY/ivolve-frontend:dev
kustomize edit set image ivolve-auth-service=$REGISTRY/ivolve-auth-service:dev
kustomize edit set image ivolve-roadmap-service=$REGISTRY/ivolve-roadmap-service:dev
cd ../..
```

### 4.2 Create the real Secret

The committed one contains **deliberate placeholders**.

```bash
kubectl create namespace ivolve --dry-run=client -o yaml | kubectl apply -f -

APP_PW=$(openssl rand -base64 24)
kubectl create secret generic ivolve-secret -n ivolve \
  --from-literal=MYSQL_ROOT_PASSWORD="$(openssl rand -base64 24)" \
  --from-literal=MYSQL_PASSWORD="$APP_PW" \
  --from-literal=DB_PASSWORD="$APP_PW" \
  --from-literal=SESSION_SECRET="$(openssl rand -base64 32)"
```

> ⚠️ `MYSQL_PASSWORD` and `DB_PASSWORD` **must be identical** — same credential, two variable names.

### 4.3 Build and push the first images

The cluster cannot start until images exist in ECR. Either run the Jenkins pipelines (Stage 6), or bootstrap manually:

```bash
aws ecr get-login-password --region us-east-1 |
  docker login --username AWS --password-stdin $REGISTRY

for svc in frontend auth-service roadmap-service; do
  docker build -t $REGISTRY/ivolve-$svc:dev src/$svc
  docker push $REGISTRY/ivolve-$svc:dev
done
```

### 4.4 Validate then apply

```bash
make k8s-validate      # → Valid: 37, Invalid: 0
make k8s-apply
kubectl get pods -n ivolve -w
```

```text
mysql-0                           1/1     Running   0   71s
auth-service-6b7f8d9c4-2xk4p      1/1     Running   0   89s
roadmap-service-5d9c7b8f6-hj3n2   1/1     Running   0   52s
frontend-7c8d9e5a4-m2p8q          1/1     Running   0   45s
```

### 4.5 Reach the application

```bash
kubectl get ingress -n ivolve
```

⏱ The `ADDRESS` takes 2-3 minutes while the ALB provisions. Open it in a browser.

---

<a id="stage-5--argocd"></a>

## 🔄 Stage 5 — ArgoCD

```bash
make argo-install
make argo-password       # save this
```

Update the repository URL in both files, then:

```bash
make argo-apply
kubectl get application ivolve-app -n argocd -w
```
```text
ivolve-app   Synced   Healthy
```

```bash
make argo-ui             # → https://localhost:8080
```

> 💡 From here on, **do not run `kubectl apply`**. ArgoCD owns the cluster state. Manual changes are reverted within 3 minutes by `selfHeal`.

---

<a id="stage-6--ci-pipelines"></a>

## ⚙️ Stage 6 — CI pipelines

### 6.1 Log in to Jenkins

Open `http://$JENKINS_IP:8080`. The Ansible playbook uses Jenkins Configuration as Code (JCasC) to bypass the setup wizard and automatically provision the admin user.
- **Username:** `admin`
- **Password:** `admin`

### 6.2 Credentials

**Manage Jenkins → Credentials → System → Global**

| ID | Kind | Value |
|---|---|---|
| `github-token` | Username with password | GitHub username + PAT |
| `sonar-token` | Secret text | From SonarQube → *My Account → Security* |

### 6.3 Shared library

```bash
# Create a repo named jenkins-shared-library, then:
git clone https://github.com/Waleeddarwesh/jenkins-shared-library.git
cp -r CloudDevOpsProject/05-Jenkins/vars jenkins-shared-library/
cd jenkins-shared-library
git add vars && git commit -m "feat: shared library" && git push
```

**Manage Jenkins → System → Global Pipeline Libraries → Add**
Name `shared-library`, default version `main`, *Modern SCM → Git*, credentials `github-token`.

### 6.4 SonarQube

**Manage Jenkins → System → SonarQube servers:** name `sonarqube`, URL `http://localhost:9000`, token `sonar-token`.
**Manage Jenkins → Tools → SonarQube Scanner:** name `sonar-scanner`, install automatically.

In SonarQube (`http://$JENKINS_IP:9000`): *Administration → Configuration → Webhooks → Create*
URL: `http://localhost:8080/sonarqube-webhook/`

> ⚠️ Without the webhook, `waitForQualityGate()` blocks until it times out.

### 6.5 Create the jobs

Three **Pipeline** jobs, *Pipeline script from SCM*, script paths:

- `05-Jenkins/Jenkinsfiles/frontend.Jenkinsfile`
- `05-Jenkins/Jenkinsfiles/auth-service.Jenkinsfile`
- `05-Jenkins/Jenkinsfiles/roadmap-service.Jenkinsfile`

Update `ecrRegistry` and `gitRepo` in each file first.

### 6.6 Run one

Click **Build Now**. It should end with a commit to `kustomization.yaml`, which ArgoCD then syncs.

---

<a id="stage-7--monitoring"></a>

## 📊 Stage 7 — Monitoring

```bash
# Change grafana.adminPassword in the values file first
make mon-install

helm install blackbox-exporter \
  prometheus-community/prometheus-blackbox-exporter -n monitoring --wait

kubectl apply -f 07-Monitoring/manifests/
kubectl get pods -n monitoring
```

```bash
make mon-grafana         # → http://localhost:3000
make mon-prometheus      # → http://localhost:9090
```

---

<a id="verification-checklist"></a>

## ✅ Verification checklist

```bash
# Infrastructure
terraform -chdir=02-Terraform output eks_cluster_name
kubectl get nodes -L topology.kubernetes.io/zone       # 2 nodes, 2 AZs
aws eks list-addons --cluster-name ivolve-dev-eks      # 4 add-ons

# Application
kubectl get pods -n ivolve                             # all Running
kubectl get pvc -n ivolve                              # data-mysql-0 Bound
kubectl get ingress -n ivolve                          # ADDRESS populated
kubectl get hpa -n ivolve                              # real targets, not <unknown>

# Security
kubectl exec -n ivolve deploy/frontend -- timeout 5 nc -zv mysql 3306   # must FAIL
kubectl get pods -n ivolve -o jsonpath='{.items[*].spec.securityContext.runAsNonRoot}'

# GitOps
kubectl get application ivolve-app -n argocd           # Synced / Healthy

# CI
# Jenkins build green; new tag visible:
aws ecr describe-images --repository-name ivolve-frontend \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags'

# Monitoring
kubectl get daemonset -n monitoring                    # desired == node count
# Prometheus → Alerts: 12 rules loaded
```

| # | Check | Expected |
|:-:|---|---|
| 1 | `make up` locally | 4 healthy containers, app usable |
| 2 | `terraform plan` | `81 to add, 0 errors` |
| 3 | Nodes | 2, in different AZs |
| 4 | Ansible second run | `changed=0` |
| 5 | `kubeconform` | `Valid: 37, Invalid: 0` |
| 6 | PVC | `data-mysql-0` Bound |
| 7 | Ingress | ALB address, app loads |
| 8 | HPA | Real percentages |
| 9 | NetworkPolicy | frontend→mysql times out |
| 10 | ArgoCD | Synced / Healthy |
| 11 | Jenkins | Green build, ECR tag, git commit |
| 12 | Trivy gate | Blocks a deliberately vulnerable base image |
| 13 | Grafana | Dashboard shows live data |
| 14 | Self-heal | Manual scale reverts within 3 min |

---

<a id="teardown"></a>

## 🧹 Teardown

**Order matters.**

```bash
# 1. ArgoCD Application first — its finalizer cascades
kubectl delete -f 06-ArgoCD/applications/
kubectl delete -f 06-ArgoCD/project.yaml

# 2. Ingress — releases the ALB before the VPC goes
kubectl delete ingress frontend -n ivolve

# 3. Monitoring (PVCs are not removed by helm uninstall)
helm uninstall monitoring blackbox-exporter -n monitoring
kubectl delete pvc --all -n monitoring

# 4. Infrastructure
make tf-destroy

# 5. State bucket
cd 02-Terraform/bootstrap && terraform destroy
```

> ⚠️ **Destroying the VPC while an ALB exists** leaves orphaned ENIs that block subnet deletion. `terraform destroy` hangs ~20 minutes then fails with `DependencyViolation`. Always delete the Ingress first.

> ⚠️ **The MySQL EBS volume survives** (`reclaimPolicy: Retain`) — intentional data protection.
> ```bash
> kubectl get pv
> aws ec2 delete-volume --volume-id vol-xxxxx
> ```

Verify nothing is left billing:

```bash
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Project,Values=ivolve \
  --query 'ResourceTagMappingList[].ResourceARN' --output table
```

---

**Problems?** → [TROUBLESHOOTING.md](TROUBLESHOOTING.md) · **Incidents?** → [RUNBOOK.md](RUNBOOK.md)
