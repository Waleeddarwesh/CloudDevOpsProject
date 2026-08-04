# ==============================================================================
# IRSA — IAM Roles for Service Accounts
# ==============================================================================
# The problem IRSA solves:
#
#   Without it, any pod that needs AWS permissions has to either (a) ship static
#   access keys in a Secret, or (b) borrow the NODE's instance role. Option (a)
#   leaks keys; option (b) means EVERY pod on that node inherits those
#   permissions — one compromised sidecar gets whatever the EBS CSI driver has.
#
# How IRSA works:
#
#   1. EKS runs an OIDC identity provider that issues a signed JWT for each pod,
#      naming its namespace and ServiceAccount.
#   2. That provider is registered with IAM (aws_iam_openid_connect_provider).
#   3. An IAM role's trust policy says "trust tokens from this provider, but
#      ONLY when sub == system:serviceaccount:<namespace>:<name>".
#   4. The pod's projected token is exchanged for temporary credentials scoped
#      to exactly that role.
#
#   Result: per-ServiceAccount permissions, no static keys, automatic rotation.
# ==============================================================================

# ------------------------------------------------------------------------------
# Fetch the OIDC issuer's TLS certificate
# ------------------------------------------------------------------------------
# IAM pins the provider by the SHA-1 thumbprint of the CA that signed the
# issuer's certificate. Reading it dynamically means this keeps working when AWS
# rotates the certificate — a hardcoded thumbprint would eventually break every
# IRSA-enabled pod at once.
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer

  # The audience AWS STS expects in the projected service-account token.
  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-oidc"
  })
}

locals {
  # "oidc.eks.us-east-1.amazonaws.com/id/ABCDEF..." — the issuer URL with the
  # scheme stripped. IAM condition keys are written against this bare form.
  oidc_provider_url = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

# ==============================================================================
# IRSA role 1 — EBS CSI Driver
# ==============================================================================
# REQUIRED for this project to work at all.
#
# The MySQL StatefulSet in Phase 4 declares a volumeClaimTemplate backed by the
# `ivolve-storage` StorageClass, whose provisioner is ebs.csi.aws.com. Something
# must call CreateVolume/AttachVolume against the EC2 API on the cluster's
# behalf; that something is this driver, and these are its permissions.
#
# Without this role the PVC stays Pending forever and the MySQL pod never
# starts — with an error buried in the CSI controller's logs.
# ==============================================================================

data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    # Restricts the role to ONE specific ServiceAccount. Without this condition
    # any pod in the cluster could assume the role and detach volumes from other
    # workloads.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    # Confirms the token was minted for STS rather than replayed from another
    # audience.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi-irsa"
  description        = "IRSA role for the EBS CSI driver — provisions PersistentVolumes"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role = aws_iam_role.ebs_csi.name
  # AWS-managed policy covering exactly the EC2 volume/snapshot actions the
  # driver needs. Maintained by AWS, so new driver features do not require a
  # hand-written policy update.
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Permission to use the cluster KMS key, needed only when the StorageClass sets
# `encrypted: "true"` (which ours does) — the driver must be able to generate a
# data key to encrypt each new volume.
data "aws_iam_policy_document" "ebs_csi_kms" {
  statement {
    effect = "Allow"
    actions = [
      "kms:CreateGrant",
      "kms:ListGrants",
      "kms:RevokeGrant",
    ]
    resources = [aws_kms_key.eks.arn]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.eks.arn]
  }
}

resource "aws_iam_role_policy" "ebs_csi_kms" {
  name   = "${var.cluster_name}-ebs-csi-kms"
  role   = aws_iam_role.ebs_csi.id
  policy = data.aws_iam_policy_document.ebs_csi_kms.json
}

# ==============================================================================
# IRSA role 2 — AWS Load Balancer Controller
# ==============================================================================
# REQUIRED by the frontend Ingress in Phase 4.
#
# `kind: Ingress` on its own does nothing — an Ingress resource is inert until a
# controller watches it and provisions real infrastructure. On EKS that
# controller is the AWS Load Balancer Controller, which turns the Ingress into
# an Application Load Balancer, target groups and listener rules.
#
# Terraform creates the ROLE here; the controller itself is installed with Helm
# (see the Setup guide), annotating its ServiceAccount with this role's ARN.
# ==============================================================================

data "aws_iam_policy_document" "lb_controller_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  name               = "${var.cluster_name}-lb-controller-irsa"
  description        = "IRSA role for the AWS Load Balancer Controller — provisions ALBs from Ingress resources"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_assume_role.json

  tags = var.tags
}

# The controller's permission set is large and has no AWS-managed equivalent, so
# the upstream policy document is vendored into this module as JSON. Refresh it
# from:
#   https://github.com/kubernetes-sigs/aws-load-balancer-controller
#     /blob/main/docs/install/iam_policy.json
resource "aws_iam_policy" "lb_controller" {
  name        = "${var.cluster_name}-lb-controller-policy"
  description = "Permissions for the AWS Load Balancer Controller"
  policy      = file("${path.module}/policies/aws-load-balancer-controller.json")

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

# ==============================================================================
# IRSA role 3 — Cluster Autoscaler (optional but wired up)
# ==============================================================================
# Watches for Pending pods that cannot be scheduled and raises the node group's
# desired capacity, then scales back down when nodes sit idle. Pairs with the
# HPA in Phase 4: the HPA adds pods, the autoscaler adds nodes to hold them.
# ==============================================================================

data "aws_iam_policy_document" "cluster_autoscaler_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:cluster-autoscaler"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  name               = "${var.cluster_name}-autoscaler-irsa"
  description        = "IRSA role for the Kubernetes Cluster Autoscaler"
  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_assume_role.json

  tags = var.tags
}

data "aws_iam_policy_document" "cluster_autoscaler" {
  # Read-only discovery of the Auto Scaling Groups behind the node group.
  statement {
    sid    = "Discovery"
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "eks:DescribeNodegroup",
    ]
    resources = ["*"]
  }

  # The mutating actions are restricted by tag to ASGs belonging to THIS cluster,
  # so the autoscaler cannot resize unrelated Auto Scaling Groups in the account.
  statement {
    sid    = "Scale"
    effect = "Allow"
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
  }
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name   = "${var.cluster_name}-autoscaler-policy"
  role   = aws_iam_role.cluster_autoscaler.id
  policy = data.aws_iam_policy_document.cluster_autoscaler.json
}
