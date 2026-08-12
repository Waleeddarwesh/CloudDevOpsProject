# ==============================================================================
# Server Module — Jenkins CI Server
# ==============================================================================
# Provisions a hardened EC2 instance that Ansible later configures (Java,
# Jenkins, Docker, Trivy, AWS CLI, kubectl, Helm, SonarQube).
#
# Three deliberate choices worth calling out:
#
#   1. IAM instance profile instead of access keys. The instance receives
#      temporary, auto-rotating credentials from the instance metadata service.
#      No AKIA... key is ever written to the disk or into Jenkins credentials —
#      which is the leak that most commonly turns a compromised CI box into a
#      compromised AWS account.
#
#   2. IMDSv2 enforced. Version 1 of the metadata service answers any HTTP GET
#      from inside the instance, so a Server-Side Request Forgery bug in ANY
#      application on the host can read the role's credentials. IMDSv2 requires
#      a PUT to obtain a session token first, which SSRF cannot perform.
#
#   3. Elastic IP. A stopped/started instance gets a new public IP, which would
#      break the Ansible inventory, the GitHub webhook, and every bookmark. The
#      EIP pins it.
# ==============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ------------------------------------------------------------------------------
# AMI lookup — latest Ubuntu 22.04 LTS
# ------------------------------------------------------------------------------
# Resolved at plan time rather than hardcoded, because AMI IDs are region-specific
# and are replaced whenever Canonical publishes a patched image. A hardcoded ID
# silently pins the server to an unpatched kernel forever.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's official AWS account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# ==============================================================================
# Security Group
# ==============================================================================
# Rules are defined as separate aws_vpc_security_group_*_rule resources rather
# than inline `ingress {}` blocks. Inline blocks are authoritative: Terraform
# deletes any rule it does not know about, so a rule added in the console during
# an incident disappears on the next apply with no warning. Separate resources
# also produce a readable plan diff when a single rule changes.
# ==============================================================================

resource "aws_security_group" "jenkins" {
  name        = "${var.name_prefix}-jenkins-sg"
  description = "Jenkins CI server - SSH, web UI, and SonarQube access"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-jenkins-sg"
  })

  lifecycle {
    # The SG is referenced by the running instance's ENI. Creating the
    # replacement before destroying the original avoids a
    # DependencyViolation error when a rule change forces replacement.
    create_before_destroy = true
  }
}

# --- Ingress: SSH ---
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  # count over the list: one rule resource per allowed CIDR. A Security Group
  # rule accepts exactly one CIDR, so a list input must be expanded.
  count = length(var.allowed_ssh_cidrs)

  security_group_id = aws_security_group.jenkins.id
  description       = "SSH from ${var.allowed_ssh_cidrs[count.index]} (Ansible + admin)"

  cidr_ipv4   = var.allowed_ssh_cidrs[count.index]
  ip_protocol = "tcp"
  from_port   = 22
  to_port     = 22

  tags = merge(var.tags, { Name = "${var.name_prefix}-ssh-${count.index}" })
}

# --- Ingress: Jenkins web UI ---
resource "aws_vpc_security_group_ingress_rule" "jenkins_ui" {
  count = length(var.allowed_jenkins_ui_cidrs)

  security_group_id = aws_security_group.jenkins.id
  description       = "Jenkins UI from ${var.allowed_jenkins_ui_cidrs[count.index]}"

  cidr_ipv4   = var.allowed_jenkins_ui_cidrs[count.index]
  ip_protocol = "tcp"
  from_port   = 8080
  to_port     = 8080

  tags = merge(var.tags, { Name = "${var.name_prefix}-ui-${count.index}" })
}

# --- Ingress: SonarQube ---
resource "aws_vpc_security_group_ingress_rule" "sonarqube" {
  # Reuses the Jenkins UI allowlist: whoever may administer Jenkins is also the
  # person who reads the code-quality dashboard.
  count = var.enable_sonarqube ? length(var.allowed_jenkins_ui_cidrs) : 0

  security_group_id = aws_security_group.jenkins.id
  description       = "SonarQube UI from ${var.allowed_jenkins_ui_cidrs[count.index]}"

  cidr_ipv4   = var.allowed_jenkins_ui_cidrs[count.index]
  ip_protocol = "tcp"
  from_port   = 9000
  to_port     = 9000

  tags = merge(var.tags, { Name = "${var.name_prefix}-sonar-${count.index}" })
}

# --- Egress ---
# Unrestricted outbound. Jenkins must reach GitHub, Docker Hub, Maven Central,
# npm, PyPI, the Trivy vulnerability database and the AWS APIs — an allowlist of
# those endpoints would be a large, constantly-changing set of CDN IP ranges.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.jenkins.id
  description       = "Allow all outbound (package registries, GitHub, AWS APIs)"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1" # all protocols

  tags = merge(var.tags, { Name = "${var.name_prefix}-egress" })
}

# ==============================================================================
# IAM — instance role, policies, and instance profile
# ==============================================================================

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins" {
  name               = "${var.name_prefix}-jenkins-role"
  description        = "Role assumed by the Jenkins EC2 instance for ECR push and EKS access"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-jenkins-role"
  })
}

# ------------------------------------------------------------------------------
# Policy: ECR push/pull
# ------------------------------------------------------------------------------
data "aws_iam_policy_document" "ecr" {
  # ecr:GetAuthorizationToken is account-scoped and CANNOT be restricted to a
  # repository ARN — the token is issued for the whole registry, so AWS only
  # accepts "*" here. Splitting it into its own statement keeps the wildcard
  # confined to this one harmless read action.
  statement {
    sid       = "EcrAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # The actions that actually move image data ARE scoped, to the three
  # repositories this project owns.
  statement {
    sid    = "EcrPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
    ]
    resources = var.ecr_repository_arns
  }
}

resource "aws_iam_role_policy" "ecr" {
  name   = "${var.name_prefix}-jenkins-ecr"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.ecr.json
}

# ------------------------------------------------------------------------------
# Policy: EKS describe
# ------------------------------------------------------------------------------
# Enough for `aws eks update-kubeconfig` to generate a kubeconfig. It grants NO
# Kubernetes permissions by itself — what this role can actually do inside the
# cluster is decided separately by the EKS Access Entry created in the EKS
# module. Two independent gates: IAM to reach the endpoint, RBAC to act on it.
data "aws_iam_policy_document" "eks" {
  statement {
    sid    = "EksDescribe"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
      "eks:ListClusters",
    ]
    # ARN reconstructed from known parts rather than read from the EKS module,
    # which would create a module dependency cycle.
    resources = [
      "arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/${var.eks_cluster_name}"
    ]
  }

  statement {
    sid       = "Ec2Describe"
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "eks" {
  name   = "${var.name_prefix}-jenkins-eks"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.eks.json
}

# ------------------------------------------------------------------------------
# Managed policy: SSM Session Manager
# ------------------------------------------------------------------------------
# Provides browser/CLI shell access with no inbound port and no SSH key, and
# every session is logged in CloudTrail. This is the escape hatch for the day
# your home IP changes and the SSH rule locks you out of your own server.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ------------------------------------------------------------------------------
# Instance profile — the wrapper that binds an IAM role to an EC2 instance
# ------------------------------------------------------------------------------
resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.name_prefix}-jenkins-profile"
  role = aws_iam_role.jenkins.name

  tags = var.tags
}

# ==============================================================================
# EC2 instance
# ==============================================================================

resource "aws_instance" "jenkins" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.jenkins.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins.name

  # --- Instance Metadata Service v2 (see module header) ---
  metadata_options {
    http_endpoint = "enabled"
    # "required" = IMDSv2 only. An SSRF or a curl from a compromised build job
    # can no longer read the instance role's temporary credentials.
    http_tokens = "required"
    # Hop limit 1 stops a container on this host from reaching the metadata
    # endpoint — a container's packet has already taken one hop.
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_size = var.root_volume_size
    # gp3 gives a 3,000 IOPS / 125 MB-s baseline independent of volume size,
    # unlike gp2 where throughput scales with capacity. Faster Docker builds,
    # and cheaper per GiB.
    volume_type = "gp3"
    # Encryption at rest using the AWS-managed EBS key. Jenkins workspaces hold
    # source code and build secrets; an unencrypted snapshot leaks all of it.
    encrypted             = true
    delete_on_termination = true

    tags = merge(var.tags, {
      Name = "${var.name_prefix}-jenkins-root"
    })
  }

  # Minimal bootstrap only. Everything else is Ansible's job (Phase 3) — the
  # point of separating provisioning from configuration is that re-running the
  # playbook must not require replacing the instance.
  user_data                   = file("${path.module}/user_data.sh")
  user_data_replace_on_change = false

  # Guards against `terraform destroy` wiping a Jenkins server that holds build
  # history and job configuration. Set to false when you genuinely want it gone.
  lifecycle {
    ignore_changes = [
      # Canonical publishes new AMIs regularly. Without this, every plan would
      # show a pending REPLACEMENT of the whole instance, destroying Jenkins.
      # Rebuild deliberately by tainting the resource instead.
      ami,
    ]
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-jenkins"
    # Consumed by the Ansible aws_ec2 dynamic inventory plugin, which filters on
    # tag:Role = jenkins to build the `role_jenkins` group. Changing this string
    # breaks Phase 3 — the two must stay in sync.
    Role = "jenkins"
  })
}

# ------------------------------------------------------------------------------
# Elastic IP
# ------------------------------------------------------------------------------
resource "aws_eip" "jenkins" {
  instance = aws_instance.jenkins.id
  domain   = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-jenkins-eip"
  })
}
