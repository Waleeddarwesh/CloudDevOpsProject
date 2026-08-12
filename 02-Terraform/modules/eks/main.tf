# ==============================================================================
# EKS Module — Control Plane and Managed Node Group
# ==============================================================================
#
#   ┌─ AWS-managed control plane (multi-AZ, you never see the EC2 instances) ─┐
#   │  api · etcd · scheduler · controller-manager                            │
#   └──────────────────────────────┬──────────────────────────────────────────┘
#                                  │ (cluster ENIs in your subnets)
#   ┌──────────────────────────────┴──────────────────────────────────────────┐
#   │  Managed node group — your EC2 instances, in PRIVATE subnets            │
#   │    node-1 (AZ-a, 10.0.10.0/24)      node-2 (AZ-b, 10.0.11.0/24)         │
#   └─────────────────────────────────────────────────────────────────────────┘
#
# Two AZs is a hard requirement, not a preference: EKS refuses to create a
# cluster whose subnets are all in one zone, because the control plane itself
# needs to survive a zone failure.
# ==============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ==============================================================================
# Control-plane IAM role
# ==============================================================================
# Assumed by the EKS service to manage AWS resources on your behalf — creating
# the cluster ENIs, and provisioning load balancers when a Service of type
# LoadBalancer is created.
# ==============================================================================

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster-role"
  description        = "EKS control-plane service role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster_eks_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ==============================================================================
# Control-plane logging
# ==============================================================================
# The log group is created explicitly so its retention can be controlled. If EKS
# creates it implicitly, retention defaults to "Never expire" and the audit
# stream accumulates cost indefinitely.
#
# Terraform must own it BEFORE the cluster starts writing, hence the depends_on
# from the cluster below — otherwise EKS wins the race, creates the group first,
# and the apply fails with ResourceAlreadyExistsException.
# ==============================================================================
resource "aws_cloudwatch_log_group" "cluster" {
  # This exact name is mandated by EKS — it is not configurable.
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.cluster_log_retention_days

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-logs"
  })
}

# ==============================================================================
# EKS cluster
# ==============================================================================

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    # Both tiers are attached. Worker nodes live in the private subnets; the
    # public subnets are what the Load Balancer Controller uses to place the
    # internet-facing ALB created by the frontend Ingress.
    subnet_ids = concat(var.private_subnet_ids, var.public_subnet_ids)

    # Private endpoint: worker nodes reach the API server over the VPC network
    # rather than out through the NAT Gateway and back in. Lower latency, and
    # kubelet traffic never touches the public internet.
    endpoint_private_access = true

    # Public endpoint: kept enabled so kubectl works from a laptop and from
    # Jenkins without a bastion or VPN. Narrow endpoint_public_access_cidrs to
    # lock it down. Note this endpoint is never anonymous — every request is
    # still signed with SigV4 and authorised by RBAC.
    endpoint_public_access = true
    public_access_cidrs    = var.endpoint_public_access_cidrs
  }

  # Ship control-plane logs to CloudWatch. 'audit' answers "who deleted that
  # deployment?" and 'authenticator' answers "which IAM identity was that?" —
  # neither question is answerable after the fact without these enabled.
  enabled_cluster_log_types = var.cluster_log_types

  access_config {
    # API_AND_CONFIG_MAP accepts both modern EKS Access Entries and the legacy
    # aws-auth ConfigMap. Pure "API" is cleaner, but leaves no recovery path if
    # every access entry is deleted by mistake — the cluster becomes permanently
    # unreachable. The hybrid mode keeps aws-auth as an escape hatch.
    authentication_mode = "API_AND_CONFIG_MAP"

    # Grants cluster-admin to whichever IAM identity runs `terraform apply`.
    # Without it the cluster comes up and nobody can talk to it: every kubectl
    # call returns "error: You must be logged in to the server (Unauthorized)".
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Envelope-encrypt Kubernetes Secrets at rest in etcd with a customer-managed
  # KMS key. Without this, Secrets are only base64-encoded inside etcd; with it,
  # reading them requires kms:Decrypt on the key as well.
  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  # IAM permissions must exist before EKS tries to use them, and the log group
  # must exist before EKS tries to create it. Terraform cannot infer either
  # ordering from the arguments above, so both are declared explicitly.
  depends_on = [
    aws_iam_role_policy_attachment.cluster_eks_policy,
    aws_cloudwatch_log_group.cluster,
  ]

  tags = merge(var.tags, {
    Name = var.cluster_name
  })
}

# ------------------------------------------------------------------------------
# KMS key for Secret envelope encryption
# ------------------------------------------------------------------------------
resource "aws_kms_key" "eks" {
  description = "Envelope encryption key for ${var.cluster_name} Kubernetes secrets"

  # Annual automatic rotation. AWS retains previous key material so data
  # encrypted under an older version stays readable.
  enable_key_rotation = true

  # Window before a scheduled deletion actually destroys the key material.
  # Deleting this key makes every encrypted Secret permanently unreadable, so
  # the maximum 30-day grace period is the right trade-off.
  deletion_window_in_days = 30

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-secrets-key"
  })
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-secrets"
  target_key_id = aws_kms_key.eks.key_id
}

# ==============================================================================
# Worker node IAM role
# ==============================================================================

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node-role"
  description        = "IAM role for EKS worker nodes"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = var.tags
}

# The three policies below are the mandatory minimum for a functioning node.
# Omitting any one produces a node that joins and then fails in a confusing way.

# Lets kubelet register the node with the control plane and describe EC2/ASG
# resources. Without it, nodes never reach Ready.
resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

# Lets the VPC CNI plugin allocate ENIs and secondary IPs for pods. Without it,
# pods sit in ContainerCreating forever with "failed to assign an IP address".
resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# Read-only pull access to ECR. Without it, every pod of this project's images
# fails with ImagePullBackOff / "no basic auth credentials".
resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Enables SSM Session Manager on the nodes. Since the nodes sit in private
# subnets with no public IP and no bastion, this is the only practical way to
# get a shell for debugging.
resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ==============================================================================
# Managed node group
# ==============================================================================
# "Managed" means AWS handles the launch template, the Auto Scaling Group,
# node draining during upgrades and automatic replacement of unhealthy nodes.
# ==============================================================================

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-ng-v2"
  node_role_arn   = aws_iam_role.node.arn

  # Passing BOTH private subnets is what satisfies the project requirement that
  # the two workers land in different subnets and different AZs — the node
  # group's ASG balances instances across every subnet it is given.
  subnet_ids = var.private_subnet_ids

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  # During a version upgrade, add one extra node before draining an old one, so
  # capacity never dips below desired_size and pods are not left Pending.
  update_config {
    max_unavailable = 1
  }

  instance_types = var.node_instance_types
  capacity_type  = var.node_capacity_type
  disk_size      = var.node_disk_size

  # AL2023 is the current default and successor to Amazon Linux 2, using nodeadm
  # for bootstrap. AL2 reached end of support for new EKS versions.
  ami_type = "AL2023_x86_64_STANDARD"

  # Kubernetes node labels, usable as nodeSelector targets by workloads.
  # `lookup` with a default is required because var.tags carries only the
  # module-level tags — Environment is injected by the provider's default_tags,
  # which are invisible here, so a bare var.tags["Environment"] would error.
  labels = {
    role        = "worker"
    environment = lookup(var.tags, "Environment", "dev")
  }

  lifecycle {
    # The cluster autoscaler and HPA change desired_size at runtime. Without
    # this, the next `terraform apply` would scale the cluster back down to the
    # value in code and evict running pods.
    ignore_changes = [scaling_config[0].desired_size]
  }

  # Nodes attempt to register the instant they boot. If the IAM policies are not
  # attached yet, registration fails and the node group creation times out after
  # ~20 minutes with an unhelpful error.
  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-nodes"
  })
}
