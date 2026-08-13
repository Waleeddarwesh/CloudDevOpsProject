<div align="center">

# 🚦 START HERE — Your Execution Checklist

**Everything *you* must do to take this repository from a clone to a running application on AWS.**

![Time](https://img.shields.io/badge/Total_Time-~2.5_hours-blue?style=flat-square)
![Cost](https://img.shields.io/badge/AWS_Cost-~$0.30/hour-orange?style=flat-square)
![Steps](https://img.shields.io/badge/Manual_Steps-24-green?style=flat-square)

</div>

---

## 📖 How to read this file

Every other document in this repository explains **how things work**. This one is the opposite: it is a flat list of **actions you perform**, in order, with the exact command to run.

| Symbol | Meaning |
|:---:|---|
| 🤖 | Automated — run the command, wait |
| ✋ | **Manual** — you must click, type, or decide something. Cannot be scripted. |
| ⚠️ | Skipping this will break a later step |
| 💰 | Starts costing money |

> 💡 **Do the phases in order.** Phase 3 needs the server Phase 2 created; Phase 6 needs the images Phase 5 pushed. Jumping ahead produces confusing failures.

---

## 📑 Contents

- [Phase 0 · Prerequisites](#phase-0)
- [Phase 1 · Local Test (no AWS, free)](#phase-1)
- [Phase 2 · AWS Infrastructure](#phase-2)
- [Phase 3 · Configure Jenkins Server](#phase-3)
- [Phase 4 · Jenkins Web Setup](#phase-4)
- [Phase 5 · Cluster Prerequisites](#phase-5)
- [Phase 6 · Deploy the Application](#phase-6)
- [Phase 7 · Monitoring](#phase-7)
- [Final Verification](#verification)
- [Teardown](#teardown)
- [If Something Breaks](#troubleshooting)

---

<a id="cost"></a>

## 💰 Read This First — Cost

This project provisions real, billable AWS infrastructure.

| Resource | Est. Cost / Hr | Est. Cost / Mo |
| :--- | :--- | :--- |
| **AWS EKS Control Plane** | $0.100/hr | **~$73** |
| 2 × NAT Gateways | $0.090/hr | **~$65** |
| 3 × `m7i-flex.large` worker nodes | $0.000/hr (Free Tier) | **$0** |
| Jenkins `t3.small` | $0.000/hr (Free Tier) | **$0** |
| Application Load Balancer | $0.023/hr + LCU | ~$17 |
| **Total** | **~$0.21/hr** | **~$155** |

> ⚠️ **A forgotten cluster costs about $7 per day.** Run [`make tf-destroy`](#teardown) the moment you finish. Set an AWS Budget alert at $20 before you start — it takes two minutes and has saved many people a painful bill.

**Free-tier note:** While the EC2 instances (`m7i-flex.large` and `t3.small`) are fully Free Tier eligible, the EKS Control Plane ($0.10/hr) and NAT Gateways have no free tier.

---

<a id="phase-0"></a>

## ✅ Phase 0 · Prerequisites

*~20 minutes · free*

### 0.1 ✋ Install the tools

| Tool | Minimum | Verify |
|---|---|---|
| AWS CLI | v2 | `aws --version` |
| Terraform | **1.10+** ⚠️ | `terraform version` |
| Docker Desktop | any recent | `docker --version` |
| kubectl | 1.29+ | `kubectl version --client` |
| Helm | 3.x | `helm version` |
| Ansible | 2.15+ | `ansible --version` |
| Git | any | `git --version` |

> ⚠️ **Terraform must be 1.10 or newer.** The S3 backend uses `use_lockfile`, which does not exist in earlier versions. On 1.9 you get `Unsupported argument`.

**Windows users:** Ansible does not run natively on Windows. Use **WSL2** (`wsl --install`) and run all Ansible commands from inside it. Everything else works in PowerShell or Git Bash.

```bash
# One-shot check that everything is present
for t in aws terraform docker kubectl helm ansible git; do
  printf "%-12s " "$t"; command -v $t >/dev/null && $t --version 2>&1|head -1 || echo "MISSING"
done
```

### 0.2 ✋ Configure AWS credentials

```bash
aws configure
```

Verify — **note your Account ID from the output, you need it in step 0.4**:

```bash
aws sts get-caller-identity
```

```json
{
    "UserId": "AIDA...",
    "Account": "991216470475",     ← THIS NUMBER
    "Arn": "arn:aws:iam::991216470475:user/waleed"
}
```

> ⚠️ Your IAM user needs broad permissions (VPC, EC2, EKS, ECR, IAM, S3, KMS, CloudWatch). `AdministratorAccess` is simplest for a lab. Never use the root account.

### 0.3 ✋ Create the SSH key pair

```bash
aws ec2 create-key-pair --key-name ivolve-key \
  --query KeyMaterial --output text > ~/.ssh/ivolve-key.pem
chmod 400 ~/.ssh/ivolve-key.pem
```

<details>
<summary><b>Windows PowerShell</b> — <code>&gt;</code> corrupts the key encoding</summary>

```powershell
aws ec2 create-key-pair --key-name ivolve-key `
  --query KeyMaterial --output text | Out-File -Encoding ascii $HOME\.ssh\ivolve-key.pem
```
</details>

### 0.4 ✋ Find your public IP

```bash
curl -s https://checkip.amazonaws.com
```

Write it down. You need it as `YOUR_IP/32` in the next phase.

> ⚠️ **If your ISP gives you a dynamic IP**, it changes and you lose SSH access. Fix by re-running this command, updating `terraform.tfvars`, and `make tf-apply`. Session Manager is configured as a backup route in.

### 0.5 ✋ Create a GitHub Personal Access Token

The pipeline commits updated manifests back to your repo.

1. GitHub → **Settings → Developer settings → Personal access tokens → Fine-grained tokens**
2. **Generate new token**
3. Repository access → **Only select repositories** → `CloudDevOpsProject`
4. Permissions → Repository permissions → **Contents: Read and write**
5. Copy the token — **it is shown once**

> ⚠️ Use a **fine-grained** token scoped to this one repo. A classic token with `repo` scope grants access to *every* repository you own — if Jenkins is compromised, so is all of it.

### 0.6 ✋ Push this repository to GitHub

*(Task 1 of your project brief — the deliverable is this URL.)*

```bash
cd "R:/ivolve/Ivolve Final Project/CloudDevOpsProject"
git init -b main
git add .
git commit -m "feat: initial commit — cloud DevOps capstone"
git remote add origin https://github.com/Waleeddarwesh/CloudDevOpsProject.git
git push -u origin main
```

> ⚠️ **Before pushing, confirm no secrets are staged.** `.gitignore` covers `.env`, `*.tfvars`, `*.tfstate`, `.vault_pass`, `*.pem` — verify with:
> ```bash
> git status --short | grep -E "\.env$|\.tfvars$|\.tfstate|vault_pass|\.pem$" && echo "STOP — secret staged!" || echo "clean"
> ```

### 0.7 ✋ Update the ArgoCD repo URL

`06-ArgoCD/applications/ivolve-app.yaml` line 47 — point it at **your** repo:

```yaml
repoURL: https://github.com/Waleeddarwesh/CloudDevOpsProject.git
```

---

<a id="phase-1"></a>

## 🐳 Phase 1 · Local Test

*~10 minutes · **free**, nothing touches AWS*

**Do this before spending money.** It proves the application, the Dockerfiles and the compose wiring all work.

### 1.1 🤖 Create the local secrets file

```bash
cd 01-Docker
cp .env.example .env
```

### 1.2 ✋ Replace the three `CHANGE_ME` values in `.env`

```bash
# Generate strong values
openssl rand -base64 24   # run 3 times, one per variable
```

| Variable | Purpose |
|---|---|
| `MYSQL_ROOT_PASSWORD` | MySQL superuser |
| `MYSQL_PASSWORD` | app account the auth-service uses |
| `SESSION_SECRET` | signs the login cookie ⚠️ |

> ⚠️ `SESSION_SECRET` defaults to the literal string `change-me-in-k8s` in `server.js`. Anyone who knows that value can **forge a session cookie for any user and skip login entirely.**

### 1.3 🤖 Start the stack

```bash
cd ..
make up
```

First run takes 3–5 minutes (Maven downloads Spring Boot).

### 1.4 ✋ Verify in a browser

Open **<http://localhost:3000>**

1. Click **Sign up**, create an account (password ≥ 8 chars)
2. Log in
3. You should land on the **DevOps Roadmap** page listing 8 topics

```bash
make ps       # all 4 services should show (healthy)
make logs     # if anything failed
```

### 1.5 🤖 Stop it

```bash
make down     # keeps the database volume
```

> ✅ **Checkpoint:** if the roadmap page rendered, the application layer is proven. Any later failure is infrastructure, not code — which narrows debugging enormously.

---

<a id="phase-2"></a>

## 🏗️ Phase 2 · AWS Infrastructure

*~25 minutes · 💰 **billing starts here***

### 2.1 🤖 Create the Terraform state bucket

```bash
make tf-bootstrap
```

Copy the `state_bucket_name` from the output.

### 2.2 ✋ Configure the backend

```bash
cd 02-Terraform
cp backend.hcl.example backend.hcl
```

Edit `backend.hcl` — paste your bucket name:

```hcl
bucket = "ivolve-tfstate-991216470475-us-east-1"    # ← from step 2.1
key    = "capstone/dev/terraform.tfstate"
region = "us-east-1"
```

### 2.3 ✋ Set your variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` — **the only two lines you must change**:

```hcl
allowed_ssh_cidrs        = ["YOUR_IP/32"]   # ← from step 0.4
allowed_jenkins_ui_cidrs = ["YOUR_IP/32"]   # ← from step 0.4
```

> ⚠️ **Terraform refuses to apply if you put `0.0.0.0/0` here.** That guard is deliberate: an open SSH port is found by scanners within minutes and is the most common way a lab AWS account gets taken over for crypto mining.

### 2.4 🤖 Initialise, review, apply

```bash
cd ..
make tf-init
make tf-plan     # ← READ THIS. ~70 resources to create.
make tf-apply
```

**Takes 15–20 minutes.** The EKS control plane alone is ~10 of those. Go get coffee.

### 2.5 🤖 Save the outputs

```bash
make tf-output
```

Record these — you need them repeatedly:

| Output | Used in |
|---|---|
| `jenkins_public_ip` | Phase 4 |
| `ecr_registry` | Step 6.1 |
| `eks_cluster_name` | Step 2.6 |
| `aws_load_balancer_controller_role_arn` | Step 5.2 |

### 2.6 🤖 Connect kubectl

```bash
make kubeconfig
kubectl get nodes
```

Expected — **2 nodes, `Ready`, in different AZs**:

```text
NAME                         STATUS   ROLES    AGE   VERSION
ip-10-0-10-42.ec2.internal   Ready    <none>   3m    v1.31.x
ip-10-0-11-88.ec2.internal   Ready    <none>   3m    v1.31.x
```

> ✅ **Checkpoint:** two `Ready` nodes means the VPC, IAM, node group and CNI are all correct.

---

<a id="phase-3"></a>

## 🤖 Phase 3 · Configure the Jenkins Server

*~15 minutes*

### 3.1 🤖 Install Ansible collections

```bash
make ansible-deps
pip install boto3 botocore      # required by the aws_ec2 inventory plugin
```

### 3.2 ✋ Create the Ansible Vault

```bash
cd 03-Ansible

# 1 — vault password (gitignored)
openssl rand -base64 32 > .vault_pass
chmod 600 .vault_pass

# 2 — secrets file
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
```

Edit `group_vars/all/vault.yml`, replacing every `CHANGE_ME` (including your GitHub token from step 0.5), then **encrypt it**:

```bash
ansible-vault encrypt group_vars/all/vault.yml
head -1 group_vars/all/vault.yml     # must show $ANSIBLE_VAULT;1.1;AES256
```

> ⚠️ **Store the vault password in a password manager.** Lose it and the file is unrecoverable — AES-256 with no reset.

### 3.3 🤖 Confirm the server is discovered

```bash
cd ..
make ansible-inventory
```

Your instance must appear under `role_jenkins`. If the group is empty, the EC2 tag and the inventory filter disagree — see [Troubleshooting](#troubleshooting).

```bash
make ansible-ping     # expect: SUCCESS => "ping": "pong"
```

### 3.4 🤖 Run the playbook

```bash
make ansible-run
```

**Takes ~10 minutes.** Installs Java, Docker, Jenkins, Trivy, AWS CLI, kubectl, Helm and SonarQube.

The final task prints your **Jenkins initial admin password** — copy it now.

```bash
make ansible-check    # optional: re-run should report changed=0 (idempotent)
```

---

<a id="phase-4"></a>

## ⚙️ Phase 4 · Jenkins Web Setup

*~20 minutes · ✋ **entirely manual** — Jenkins' first-run wizard cannot be safely automated*

### 4.1 ✋ Unlock Jenkins

Open `http://<jenkins_public_ip>:8080`

Paste the password from step 3.4. If you lost it:

```bash
ssh -i ~/.ssh/ivolve-key.pem ubuntu@<JENKINS_IP> \
  'sudo cat /var/lib/jenkins/secrets/initialAdminPassword'
```

### 4.2 ✋ Complete the wizard

1. **Select plugins to install** → **Select none** *(Ansible already installed 25 plugins)*
2. Create your admin user
3. Confirm the Jenkins URL

### 4.3 ✋ Register the Shared Library

**Manage Jenkins → System → Global Pipeline Libraries → Add**

| Field | Value |
|---|---|
| Name | `shared-library` |
| Default version | `main` |
| Retrieval method | *Modern SCM* → *Git* |
| Project Repository | `https://github.com/Waleeddarwesh/jenkins-shared-library.git` |
| Credentials | *(add your GitHub PAT)* |

> ⚠️ **Push the library first** if you haven't:
> ```bash
> cd /r/ivolve/jenkins-shared-library && git push
> ```

### 4.4 ✋ Add credentials

**Manage Jenkins → Credentials → System → Global credentials → Add**

| ID *(must match exactly)* | Kind | Value |
|---|---|---|
| `github-token` | Username with password | your GitHub username + PAT |
| `sonar-token` | Secret text | generated in step 4.5 |

> ⚠️ The **ID strings are referenced verbatim** in the shared library. A typo produces `CredentialNotFoundException` at runtime, not at configuration time.

### 4.5 ✋ Set up SonarQube

Open `http://<jenkins_public_ip>:9000` — login `admin` / `admin`, change the password when prompted.

**a) Generate a token:** *My Account → Security → Generate Token* → copy it → add to Jenkins as `sonar-token` (step 4.4).

**b) Register the server in Jenkins:** *Manage Jenkins → System → SonarQube servers → Add*

| Field | Value |
|---|---|
| Name | `SonarQube` |
| Server URL | `http://localhost:9000` |
| Server authentication token | `sonar-token` |

**c) ⚠️ Add the webhook** — *SonarQube → Administration → Configuration → Webhooks → Create*

| Field | Value |
|---|---|
| Name | `Jenkins` |
| URL | `http://localhost:8080/sonarqube-webhook/` |

> ⚠️ **Without this webhook, `waitForQualityGate()` blocks until it times out** and every build hangs for 10 minutes before failing. This is the single most commonly missed step in the whole project.

### 4.6 ✋ Create the three pipeline jobs

For each service — **New Item → Pipeline**:

| Job name | Script Path |
|---|---|
| `ivolve-frontend` | `05-Jenkins/Jenkinsfiles/frontend.Jenkinsfile` |
| `ivolve-auth-service` | `05-Jenkins/Jenkinsfiles/auth-service.Jenkinsfile` |
| `ivolve-roadmap-service` | `05-Jenkins/Jenkinsfiles/roadmap-service.Jenkinsfile` |

In each job:
- **Pipeline → Definition:** *Pipeline script from SCM*
- **SCM:** Git → your `CloudDevOpsProject` URL → credentials `github-token`
- **Branch:** `*/main`
- **Script Path:** from the table above

### 4.7 ✋ Update the ECR registry in the Jenkinsfiles

Each Jenkinsfile has a placeholder account ID. Replace all three at once:

```bash
cd "R:/ivolve/Ivolve Final Project/CloudDevOpsProject"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
sed -i "s/123456789012/$ACCOUNT/g" 05-Jenkins/Jenkinsfiles/*.Jenkinsfile
sed -i "s/123456789012/$ACCOUNT/g" 04-Kubernetes/manifests/kustomization.yaml
git commit -am "chore: set real AWS account ID" && git push
```

---

<a id="phase-5"></a>

## ☸️ Phase 5 · Cluster Prerequisites

*~10 minutes*

### 5.1 ✋ Set the Kubernetes secrets

`04-Kubernetes/manifests/02-config.yaml` contains four `CHANGE_ME` placeholders.

```bash
openssl rand -base64 24    # run 4 times
```

| Key | Must match |
|---|---|
| `MYSQL_ROOT_PASSWORD` | — |
| `MYSQL_PASSWORD` | ⚠️ must equal `DB_PASSWORD` |
| `DB_PASSWORD` | ⚠️ must equal `MYSQL_PASSWORD` |
| `SESSION_SECRET` | — |

> ⚠️ `MYSQL_PASSWORD` and `DB_PASSWORD` are the **same credential** seen from two sides — MySQL creates the account with one, the auth-service authenticates with the other. If they differ, MySQL starts fine and auth-service fails with `Access denied`.

> 💡 **A plaintext Secret in Git is a known compromise** made here for assessment visibility. `docs/SECURITY.md` documents the production fix (Sealed Secrets / External Secrets Operator). Say so explicitly if you present this.

### 5.2 🤖 Install the AWS Load Balancer Controller

**Required — the Ingress does nothing without it.**

```bash
CLUSTER=$(terraform -chdir=02-Terraform output -raw eks_cluster_name)
ROLE_ARN=$(terraform -chdir=02-Terraform output -raw aws_load_balancer_controller_role_arn)

helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ROLE_ARN"

kubectl -n kube-system rollout status deploy/aws-load-balancer-controller
```

> ⚠️ The ServiceAccount name **must** be `aws-load-balancer-controller`. The IRSA trust policy Terraform created only accepts tokens from that exact namespace/ServiceAccount pair.

### 5.3 🤖 Install ArgoCD

```bash
make argo-install
make argo-password     # save this
```

---

<a id="phase-6"></a>

## 🚀 Phase 6 · Deploy the Application

*~15 minutes*

### 6.1 🤖 Run the pipelines

In Jenkins, **Build Now** on each job, in this order:

1. `ivolve-auth-service`
2. `ivolve-roadmap-service`
3. `ivolve-frontend`

Each runs 9 stages: checkout → test → Sonar → build → **Trivy scan** → push → cleanup → update manifest → push manifest.

> 💡 **A failed Trivy stage means the gate worked.** Read the report in the build artifacts; it lists fixable CRITICAL CVEs. That is the pipeline doing its job, not a bug.

Verify the images landed:

```bash
aws ecr list-images --repository-name ivolve-frontend --query 'imageIds[*].imageTag'
```

### 6.2 🤖 Point ArgoCD at your repo and sync

```bash
make argo-apply
```

### 6.3 ✋ Watch it deploy

```bash
make argo-ui      # then open https://localhost:8080 — user: admin
kubectl get pods -n ivolve -w
```

Expected once settled:

```text
NAME                               READY   STATUS    RESTARTS
auth-service-xxxxxxxxx-xxxxx       1/1     Running   0
auth-service-xxxxxxxxx-xxxxx       1/1     Running   0
frontend-xxxxxxxxx-xxxxx           1/1     Running   0
frontend-xxxxxxxxx-xxxxx           1/1     Running   0
mysql-0                            1/1     Running   0
roadmap-service-xxxxxxxxx-xxxxx    1/1     Running   0
roadmap-service-xxxxxxxxx-xxxxx    1/1     Running   0
```

> 💡 `mysql-0` starts **first** — sync wave 1. The app pods have an initContainer that waits for it, so they sit in `Init:0/1` for a minute. That is correct behaviour, not a hang.

### 6.4 ✋ Open the application

```bash
kubectl get ingress -n ivolve
```

Copy the `ADDRESS` (an ALB DNS name) into a browser.

> ⚠️ **Wait 2–3 minutes** after the address first appears. DNS propagation plus ALB target-group health checks take that long; a `503` before then is expected.

Sign up, log in, see the roadmap. **That is the full loop: your commit → Jenkins → ECR → Git → ArgoCD → EKS → browser.**

---

<a id="phase-7"></a>

## 📊 Phase 7 · Monitoring

*~10 minutes · optional but recommended*

### 7.1 ✋ Set the Grafana password

`07-Monitoring/kube-prometheus-stack-values.yaml` → replace `CHANGE_ME_grafana_password`.

### 7.2 🤖 Install and open

```bash
make mon-install         # ~5 min: Prometheus, Grafana, Alertmanager, node-exporter
make grafana-dashboard   # loads the custom iVolve dashboard
make mon-grafana         # port-forward → http://localhost:3000
```

Log in as `admin`. Open **Dashboards → iVolve — Application Overview**.

---

<a id="verification"></a>

## ✅ Final Verification

Run this to confirm every deliverable:

```bash
echo "── Terraform ──"        && terraform -chdir=02-Terraform state list | wc -l
echo "── Nodes (expect 2) ──" && kubectl get nodes --no-headers | wc -l
echo "── Pods ──"             && kubectl get pods -n ivolve
echo "── PVC (expect Bound)──"&& kubectl get pvc -n ivolve
echo "── Ingress ──"          && kubectl get ingress -n ivolve
echo "── ArgoCD ──"           && kubectl get application -n argocd
echo "── ECR ──"              && aws ecr describe-repositories --query 'repositories[].repositoryName'
```

### Deliverables checklist

| # | Brief requirement | Where | ✓ |
|:-:|---|---|:-:|
| 1 | GitHub repository | your repo URL | ☐ |
| 2 | `docker-compose.yml` | `01-Docker/` | ☐ |
| 3 | Terraform modules (network/server/EKS/ECR) + S3 backend | `02-Terraform/` | ☐ |
| 4 | Ansible roles + dynamic inventory | `03-Ansible/` | ☐ |
| 5 | K8s: ns, Deployments, Services, StatefulSet, headless svc, StorageClass, ConfigMap, Secret, Ingress | `04-Kubernetes/` | ☐ |
| 6 | Jenkins pipelines + shared library `vars/` | `05-Jenkins/` | ☐ |
| 7 | ArgoCD Application | `06-ArgoCD/` | ☐ |
| 8 | Documentation | `README.md` + `docs/` | ☐ |

---

<a id="teardown"></a>

## 🧹 Teardown — **Do Not Skip**

> 💰 **~$7/day if you forget.**

```bash
# 1 — Kubernetes first. The ALB is created by the Ingress controller, NOT by
#     Terraform. Destroying the VPC while it exists leaves an orphaned ALB and
#     Terraform hangs for ~20 min on DependencyViolation.
kubectl delete ingress --all -n ivolve
kubectl delete namespace ivolve argocd monitoring --ignore-not-found

# 2 — Wait for the load balancer to actually disappear
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'

# 3 — Now destroy the infrastructure
make tf-destroy

# 4 — Clean up what Terraform does not own
aws ec2 delete-key-pair --key-name ivolve-key
rm -f ~/.ssh/ivolve-key.pem
```

### ✋ Confirm nothing is left

```bash
aws ec2 describe-instances --filters "Name=tag:Project,Values=ivolve" \
  --query 'Reservations[].Instances[?State.Name!=`terminated`].InstanceId'
aws eks list-clusters
aws ec2 describe-nat-gateways --query 'NatGateways[?State==`available`].NatGatewayId'
```

All three should be empty. The state bucket survives on purpose — delete it manually if you are finished for good.

---

<a id="troubleshooting"></a>

## 🔧 If Something Breaks

| Symptom | Cause | Fix |
|---|---|---|
| `Unsupported argument: use_lockfile` | Terraform < 1.10 | Upgrade Terraform |
| `Refusing to open SSH to the entire internet` | `0.0.0.0/0` in tfvars | Set `YOUR_IP/32` — the guard is intentional |
| Ansible: `skipping: no hosts matched` | Instance not discovered | `make ansible-inventory`; check the `Role=jenkins` tag; `--flush-cache` |
| Ansible: `Failed to connect via ssh` | Your IP changed | Re-run step 0.4, update tfvars, `make tf-apply` |
| Jenkins build hangs at SonarQube | **Webhook missing** | Step 4.5c |
| `CredentialNotFoundException` | Credential ID typo | Must be exactly `github-token` / `sonar-token` |
| Pod `ImagePullBackOff` | Image not in ECR, or wrong account ID | Check pipeline ran; verify step 4.7 |
| PVC stuck `Pending` | EBS CSI driver / IRSA | `kubectl get pods -n kube-system \| grep ebs` |
| Ingress has no `ADDRESS` | LB Controller missing | Step 5.2 |
| Ingress `503` | Targets still registering | Wait 2–3 min |
| auth-service `Access denied` | `MYSQL_PASSWORD` ≠ `DB_PASSWORD` | Step 5.1 |
| `terraform destroy` hangs | Orphaned ALB | Delete Ingress first (Teardown step 1) |

Full guide: **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**

---

<div align="center">

**Stuck?** → [SETUP.md](docs/SETUP.md) (detailed) · [ARCHITECTURE.md](docs/ARCHITECTURE.md) (why) · [RUNBOOK.md](docs/RUNBOOK.md) (operations)

</div>
