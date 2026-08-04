# 🏗️ Phase 2: Infrastructure Provisioning with Terraform

## 📌 Overview

This phase builds the entire AWS foundation from code: a two-AZ VPC, a Jenkins CI server, an EKS cluster with two worker nodes, and three ECR repositories — **81 resources** in total, defined across four reusable modules with remote state in S3.

Nothing is clicked in the console. That is the point: the infrastructure is versioned, reviewable, reproducible, and destroyable with one command.

> ✅ **Verified against live AWS.** `terraform plan` returns **`81 to add, 0 to change, 0 to destroy`** with zero errors and zero warnings.

---

# 📖 Understanding Terraform Modules

A module is a reusable, parameterised package of resources. Without modules everything lands in one enormous `main.tf`:

```text
   Monolithic                          Modular (used here)
┌────────────────────────┐      ┌────────────────────────────────┐
│ main.tf   (900 lines)  │      │ main.tf  (120 lines)           │
│  aws_vpc               │      │   module "network" { … }       │
│  aws_subnet × 4        │      │   module "server"  { … }       │
│  aws_nat_gateway       │      │   module "eks"     { … }       │
│  aws_instance          │      │   module "ecr"     { … }       │
│  aws_eks_cluster       │      │                                │
│  aws_iam_role × 6      │      │ modules/network/  ← self-contained
│  …                     │      │ modules/server/   ← testable
│                        │      │ modules/eks/      ← reusable
│ unreviewable           │      │ modules/ecr/      ← composable
│ un-reusable            │      └────────────────────────────────┘
└────────────────────────┘
```

Each module here has the same four-file shape:

| File | Purpose |
|---|---|
| `main.tf` | The resources |
| `variables.tf` | The input contract — every variable has a `description`, most have `validation` |
| `outputs.tf` | The output contract — what other modules may consume |
| `versions.tf` | Provider constraints, so the module validates independently |

---

# 📖 Understanding Remote State

Terraform's **state file** is the only record mapping your code to real AWS resource IDs. Lose it, and Terraform will happily try to re-create infrastructure that already exists.

```text
   Local state (the default)          S3 remote state (used here)
┌──────────────────────────────┐   ┌──────────────────────────────────┐
│ ./terraform.tfstate          │   │ s3://ivolve-tfstate-<acct>-<rgn> │
│                              │   │                                  │
│ ✗ one laptop only            │   │ ✓ shared: laptop + Jenkins       │
│ ✗ no locking → corruption    │   │ ✓ locked  (.tflock object)       │
│   when two applies overlap   │   │ ✓ versioned → recoverable        │
│ ✗ plaintext secrets on disk  │   │ ✓ encrypted at rest (AES-256)    │
│ ✗ one disk failure = gone    │   │ ✓ TLS enforced by bucket policy  │
└──────────────────────────────┘   └──────────────────────────────────┘
```

> ⚠️ **State contains secrets in plaintext.** Every value Terraform touches — generated passwords, private keys, certificates — is written to state verbatim. Treat the state bucket as a secrets store, because that is what it is.

### The chicken-and-egg problem, and how `bootstrap/` solves it

The S3 bucket must exist *before* the backend can initialise. So `bootstrap/` is a **separate root module using local state on purpose**. It creates exactly one thing — the bucket — and is run once, ever.

```text
  bootstrap/  (local state)          02-Terraform/  (S3 state)
┌───────────────────────┐          ┌─────────────────────────┐
│ terraform apply       │  bucket  │ terraform init          │
│  → S3 bucket          │ ───────► │   -backend-config=…     │
│    versioned          │   name   │ terraform apply         │
│    encrypted          │          │   → 81 resources        │
│    public-blocked     │          │                         │
└───────────────────────┘          └─────────────────────────┘
```

### Locking without DynamoDB

Terraform 1.10 introduced **S3-native locking** via a conditional write on a `<key>.tflock` object:

```hcl
terraform {
  backend "s3" {
    encrypt      = true
    use_lockfile = true    # ← replaces the legacy dynamodb_table
  }
}
```

The old `dynamodb_table` argument required a separate table purely to hold one lock row, and is **deprecated as of Terraform 1.11**. One less resource to provision, pay for, and forget to delete.

---

# 📖 Understanding the Network Design

```text
                        Internet
                            │
              ┌─────────────▼─────────────┐
              │     Internet Gateway      │
              └─────────────┬─────────────┘
   ┌──────────────────────────────────────────────────┐
   │ VPC 10.0.0.0/16                                  │
   │                                                  │
   │  PUBLIC  10.0.1.0/24 (az-a)   10.0.2.0/24 (az-b) │
   │   · Jenkins EC2 + Elastic IP                     │
   │   · NAT Gateway                                  │
   │   · ALB (created by the Ingress in Phase 4)      │
   │         │                                        │
   │         │ NAT — outbound only                    │
   │         ▼                                        │
   │  PRIVATE 10.0.10.0/24 (az-a) 10.0.11.0/24 (az-b) │
   │   · EKS worker node 1     · EKS worker node 2    │
   │   · No public IP — unreachable from the internet │
   └──────────────────────────────────────────────────┘
```

### Security Groups vs Network ACLs — not redundant

| | Security Group | Network ACL |
|---|---|---|
| **Attaches to** | ENI (instance) | Subnet |
| **State** | **Stateful** — replies auto-allowed | **Stateless** — return traffic needs its own rule |
| **Rules** | Allow only | Allow **and Deny** |
| **Evaluation** | All rules | First match by rule number |
| **Role here** | Precise per-instance filtering | Coarse subnet-level backstop |

Because NACLs are stateless, the public NACL must explicitly allow inbound on **ephemeral ports 1024–65535** — otherwise the NAT Gateway's outbound replies are dropped and every private-subnet package download hangs. This trips up nearly everyone the first time.

### Subnet tags that EKS silently requires

```hcl
"kubernetes.io/role/elb"                    = "1"        # public
"kubernetes.io/role/internal-elb"           = "1"        # private
"kubernetes.io/cluster/${var.cluster_name}" = "shared"
```

The AWS Load Balancer Controller **discovers subnets by these tags**. Omit them and Ingress creation fails with `couldn't auto-discover subnets` — one of the most common EKS Ingress bugs.

---

# 📖 Understanding IRSA (IAM Roles for Service Accounts)

This is the mechanism that lets a *pod* hold AWS permissions without any static key.

```text
  ┌─────────┐  1. projected JWT   ┌──────────────────┐
  │   Pod   │ ──────────────────► │  EKS OIDC issuer │
  │  (SA:   │                     └────────┬─────────┘
  │ ebs-csi)│                              │ 2. registered with IAM
  └────┬────┘                     ┌────────▼─────────┐
       │ 3. AssumeRoleWithWebIdentity  │  IAM Role   │
       │    sub == system:serviceaccount:kube-system:ebs-csi-controller-sa
       ▼                              └────────┬─────────┘
  ┌─────────────────┐                          │ 4. temporary creds
  │  EC2 CreateVolume ◄──────────────────────┘
  └─────────────────┘
```

Without IRSA the only options are (a) ship static keys in a Secret, or (b) let every pod inherit the **node's** role — so one compromised sidecar gets whatever the EBS driver has. IRSA scopes permissions to a single ServiceAccount.

Three IRSA roles are created:

| Role | ServiceAccount | Why it is required |
|---|---|---|
| **EBS CSI driver** | `kube-system:ebs-csi-controller-sa` | **Without it the MySQL PVC stays `Pending` forever** |
| **AWS Load Balancer Controller** | `kube-system:aws-load-balancer-controller` | **Without it the Ingress creates no ALB** |
| **Cluster Autoscaler** | `kube-system:cluster-autoscaler` | Optional — scales nodes for the HPA |

---

# 📖 Understanding EKS Add-ons

A bare EKS cluster is **not a working cluster**. Four components must be running before a single application pod can start:

| Add-on | Without it |
|---|---|
| `vpc-cni` | Pods get no IP — stuck in `ContainerCreating` |
| `kube-proxy` | Service ClusterIPs resolve but connections hang |
| `coredns` | `mysql:3306` and every other service name fails to resolve |
| `aws-ebs-csi-driver` | **The MySQL PVC never binds** |

> ⚠️ **The EBS CSI driver is the one people miss.** It stopped being bundled with EKS in version 1.23. A StatefulSet that worked on an older cluster silently hangs on a new one, with the real cause buried in the CSI controller logs.

---

## 🎯 Objectives

- Provision a two-AZ VPC with public and private subnets, IGW, NAT Gateway, route tables and **Network ACLs**.
- Provision a hardened EC2 instance for Jenkins with an IAM instance profile and IMDSv2 enforced.
- Provision an EKS cluster with **2 worker nodes in different private subnets and Availability Zones**.
- Provision three ECR repositories with immutable tags, scan-on-push and lifecycle policies.
- Use an **S3 backend** for remote state with encryption, versioning and native locking.
- Structure everything as reusable modules with validated inputs and documented outputs.

---

## 📂 Project Structure

```text
02-Terraform/
│
├── bootstrap/                      # Run ONCE — creates the state bucket
│   ├── main.tf                     #   S3 + versioning + encryption + TLS policy
│   ├── variables.tf
│   └── outputs.tf                  #   prints a ready-made backend.hcl
│
├── versions.tf                     # terraform >= 1.10, aws ~> 5.80, tls ~> 4.0
├── providers.tf                    # provider + default_tags + identity lookups
├── backend.tf                      # S3 backend (partial config)
├── backend.hcl.example             # → copy to backend.hcl (gitignored)
├── locals.tf                       # name_prefix, cluster_name, ecr_registry
├── main.tf                         # composes the four modules
├── variables.tf                    # 28 inputs, validated
├── outputs.tf                      # IPs, cluster name, registry, next steps
├── terraform.tfvars.example        # → copy to terraform.tfvars (gitignored)
├── zz_local_backend_override.tf.disabled   # offline-plan helper
│
└── modules/
    ├── network/
    │   ├── main.tf                 # VPC, subnets, IGW, NAT, RTs, NACLs, flow logs
    │   ├── variables.tf  outputs.tf  versions.tf
    ├── server/
    │   ├── main.tf                 # AMI lookup, SG, IAM role+profile, EC2, EIP
    │   ├── user_data.sh            # minimal bootstrap — Ansible does the rest
    │   ├── variables.tf  outputs.tf  versions.tf
    ├── eks/
    │   ├── main.tf                 # cluster, KMS, node group, IAM
    │   ├── irsa.tf                 # OIDC provider + 3 IRSA roles
    │   ├── addons.tf               # vpc-cni, kube-proxy, coredns, ebs-csi
    │   ├── access.tf               # EKS Access Entries (replaces aws-auth)
    │   ├── policies/aws-load-balancer-controller.json
    │   ├── variables.tf  outputs.tf  versions.tf
    └── ecr/
        ├── main.tf                 # repos, lifecycle, repo policy
        ├── variables.tf  outputs.tf  versions.tf
```

---

## 🛠 Technologies Used

- Terraform 1.10+
- AWS Provider `~> 5.80`, TLS Provider `~> 4.0`
- AWS: VPC, EC2, EKS, ECR, S3, IAM, KMS, CloudWatch Logs, NAT Gateway, Elastic IP
- HCL2

---

## ✅ Prerequisites

- **Terraform ≥ 1.10** (required for `use_lockfile`)
  ```bash
  terraform version
  ```
- **AWS CLI configured** with credentials that can create VPC/EC2/EKS/ECR/IAM resources
  ```bash
  aws sts get-caller-identity
  ```
- **An existing EC2 key pair** in the target region:
  ```bash
  aws ec2 create-key-pair --key-name ivolve-key \
    --query KeyMaterial --output text > ~/.ssh/ivolve-key.pem
  chmod 400 ~/.ssh/ivolve-key.pem
  ```
  > 💡 **PowerShell users:** `>` corrupts the key encoding. Use:
  > ```powershell
  > aws ec2 create-key-pair --key-name ivolve-key --query KeyMaterial --output text |
  >   Out-File -Encoding ascii $HOME\.ssh\ivolve-key.pem
  > ```
- **Your public IP**, for the security group rules:
  ```bash
  curl -s https://checkip.amazonaws.com
  ```

---

# 📋 Steps

## 1. Create the remote state bucket

```bash
cd 02-Terraform/bootstrap
terraform init
terraform apply
```

Expected output:

```text
Apply complete! Resources: 7 added, 0 changed, 0 destroyed.

Outputs:

backend_hcl = <<EOT
    bucket = "ivolve-tfstate-991216470475-us-east-1"
    key    = "capstone/dev/terraform.tfstate"
    region = "us-east-1"
EOT
state_bucket_name = "ivolve-tfstate-991216470475-us-east-1"
```

The bucket name embeds your account ID because **S3 bucket names are globally unique across all AWS accounts** — a fixed name like `ivolve-terraform-state` is already taken.

---

## 2. Configure the backend

```bash
cd ..
cp backend.hcl.example backend.hcl
```

Paste the values from the bootstrap output:

```hcl
bucket = "ivolve-tfstate-991216470475-us-east-1"
key    = "capstone/dev/terraform.tfstate"
region = "us-east-1"
```

> 💡 Backend blocks **cannot use variables or interpolation** — a hard Terraform limitation, because the backend initialises before variables are evaluated. Partial configuration via `-backend-config` is the supported workaround, and it keeps an account-specific bucket name out of Git.

---

## 3. Set your variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit the two **required** values:

```hcl
allowed_ssh_cidrs        = ["203.0.113.9/32"]   # ← YOUR IP
allowed_jenkins_ui_cidrs = ["203.0.113.9/32"]   # ← YOUR IP
```

> 🔒 **Terraform refuses to apply with `0.0.0.0/0` here.** A validation block rejects it:
> ```text
> Error: Invalid value for variable
> Refusing to open SSH (port 22) to the entire internet.
> ```
> An open SSH port is found by automated scanners within minutes; the usual outcome is a crypto-mining bill.

---

## 4. Initialise

```bash
terraform init -backend-config=backend.hcl
```

```text
Initializing the backend...
Successfully configured the backend "s3"!
Initializing modules...
- ecr in modules/ecr
- eks in modules/eks
- network in modules/network
- server in modules/server
Initializing provider plugins...
- Installed hashicorp/aws v5.100.0 (signed by HashiCorp)
- Installed hashicorp/tls v4.3.0 (signed by HashiCorp)

Terraform has been successfully initialized!
```

> 💡 Commit `.terraform.lock.hcl`. It pins provider **checksums**, which is what makes `terraform init` reproducible on another machine.

---

## 5. Validate and plan

```bash
terraform fmt -recursive -check
terraform validate
terraform plan
```

```text
Success! The configuration is valid.

Plan: 81 to add, 0 to change, 0 to destroy.
```

Read the plan before applying. `plan` is read-only and creates nothing.

---

## 6. Apply

```bash
terraform apply
```

⏱ **Expect 15–20 minutes.** The EKS control plane alone takes ~10 minutes, and the managed node group another ~5.

```text
Apply complete! Resources: 81 added, 0 changed, 0 destroyed.

Outputs:

configure_kubectl   = "aws eks update-kubeconfig --region us-east-1 --name ivolve-dev-eks"
ecr_registry        = "991216470475.dkr.ecr.us-east-1.amazonaws.com"
eks_cluster_name    = "ivolve-dev-eks"
jenkins_public_ip   = "54.211.x.x"
jenkins_url         = "http://54.211.x.x:8080"
```

---

## 7. Verify

```bash
terraform output next_steps
```

```bash
# Cluster reachable and both nodes Ready, in different AZs
aws eks update-kubeconfig --region us-east-1 --name ivolve-dev-eks
kubectl get nodes -o wide
```
```text
NAME                          STATUS   ROLES    AGE   VERSION
ip-10-0-10-42.ec2.internal    Ready    <none>   3m    v1.31.x
ip-10-0-11-88.ec2.internal    Ready    <none>   3m    v1.31.x
```

```bash
# Confirm the two nodes really are in different AZs (the project requirement)
kubectl get nodes -L topology.kubernetes.io/zone
```
```text
NAME                          STATUS   ZONE
ip-10-0-10-42.ec2.internal    Ready    us-east-1a
ip-10-0-11-88.ec2.internal    Ready    us-east-1b
```

```bash
# All four add-ons ACTIVE
aws eks list-addons --cluster-name ivolve-dev-eks
```

```bash
# ECR repositories with IMMUTABLE tags
aws ecr describe-repositories \
  --query 'repositories[].[repositoryName,imageTagMutability]' --output table
```

---

# 📸 Screenshots

| Description | Image |
|---|---|
| `terraform apply` completing with 81 resources | `Screenshots/tf_apply.png` |
| Terraform outputs | `Screenshots/tf_outputs.png` |
| VPC resource map in the AWS console | `Screenshots/vpc_map.png` |
| EKS cluster overview | `Screenshots/eks_console.png` |
| `kubectl get nodes` showing two AZs | `Screenshots/nodes_azs.png` |
| ECR repositories | `Screenshots/ecr_repos.png` |
| S3 state bucket with versioning enabled | `Screenshots/state_bucket.png` |

---

## 📚 Key Learning Outcomes

- Structure infrastructure as composable modules with validated input contracts.
- Configure an S3 remote backend with encryption, versioning and native locking, and solve the bootstrap chicken-and-egg problem.
- Design a two-AZ VPC and explain the stateful/stateless distinction between Security Groups and NACLs.
- Understand why EKS requires specific subnet tags for load-balancer discovery.
- Configure IRSA end to end: OIDC provider → trust policy → ServiceAccount → temporary credentials.
- Install the EKS add-ons that a cluster is unusable without.
- Replace the fragile `aws-auth` ConfigMap with EKS Access Entries.
- Enforce IMDSv2 and understand the SSRF class of attack it prevents.
- Recognise the `count` plan-time constraint and design around it.

---

## 💡 Best Practices

- **Pin versions** — `required_version` and `~>` provider constraints, and commit `.terraform.lock.hcl`.
- **Use `for_each` over `count` for named collections.** Removing an item from a `count` list shifts every index and Terraform destroys and recreates the survivors — which for ECR means deleting live images. The ECR module uses `for_each` deliberately.
- **Never hardcode AMI IDs.** They are region-specific and are replaced on every security patch. Use a `data` source.
- **Apply `default_tags` at the provider level** — cost allocation, cleanup and incident response all depend on consistent tagging.
- **Scope IAM to ARNs, not `"*"`.** The Jenkins ECR policy grants push only on this project's three repositories.
- **Use `lifecycle { ignore_changes = [...] }`** for values controlled at runtime — the node group's `desired_size` is owned by the autoscaler, not by code.
- **Run `terraform plan` before every apply**, and read it.
- **Never apply with local state.** The `zz_local_backend_override.tf.disabled` file exists for offline plan validation only, and ships disabled by design.
- **Set `reclaimPolicy`/`force_delete` deliberately** — decide in advance whether a `destroy` may take your data with it.

---

## 🌍 Real-World Use Cases

- **Multi-environment deployments** — the same modules with different `.tfvars` produce dev, staging and prod.
- **Disaster recovery** — rebuild an entire region from code in under an hour.
- **Compliance evidence** — Git history is an auditable record of every infrastructure change and who approved it.
- **Cost governance** — `default_tags` makes Cost Explorer breakdowns by project and environment possible.
- **Team collaboration** — remote state with locking lets several engineers and a CI system work on the same infrastructure safely.
- **Ephemeral environments** — spin up a full stack per pull request, destroy it on merge.

---

## 🧹 Cleanup

```bash
# 1. Delete the Kubernetes Ingress FIRST so the ALB is released
kubectl delete ingress frontend -n ivolve

# 2. Destroy the infrastructure
terraform destroy

# 3. Destroy the state bucket (empty it first — versioning is on)
cd bootstrap && terraform destroy
```

> ⚠️ **Order matters.** Destroying the VPC while an ALB still exists leaves orphaned ENIs that block subnet deletion, and `terraform destroy` hangs for ~20 minutes before failing with `DependencyViolation`.

> ⚠️ **`reclaimPolicy: Retain`** on the StorageClass means the MySQL EBS volume **survives** a destroy. That is intentional data protection — delete it manually with `aws ec2 delete-volume` once you are sure.

---

## ✅ Result

A complete, production-shaped AWS foundation provisioned entirely from code: a **two-AZ VPC** with public/private subnets, NAT, layered NACLs and flow logs; a **hardened Jenkins EC2** instance with an IAM instance profile, IMDSv2 enforced and an encrypted root volume; an **EKS 1.31 cluster** with two worker nodes in separate AZs, KMS-encrypted Secrets, control-plane logging, an OIDC provider, three IRSA roles and all four required add-ons; and **three ECR repositories** with immutable tags, scan-on-push and lifecycle expiry — all with state in an encrypted, versioned, natively-locked S3 backend.

**Validated:** `terraform validate` ✅ · `terraform fmt -check` ✅ · **live `terraform plan` → 81 to add, 0 errors** ✅

**Next:** [Phase 3 — Configuration Management with Ansible →](../03-Ansible/)
