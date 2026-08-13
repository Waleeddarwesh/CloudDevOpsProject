# ==============================================================================
# EKS Managed Add-ons
# ==============================================================================
# A bare EKS cluster is not a working cluster. These four components must be
# running before a single application pod can start, and EKS does NOT install
# all of them for you.
#
#   vpc-cni      Assigns a real VPC IP to every pod.  Without it: no pod networking.
#   kube-proxy   Programs iptables/nftables for Services. Without it: ClusterIP
#                DNS resolves but connections hang.
#   coredns      In-cluster DNS. Without it, `mysql:3306` and every other
#                service name fails to resolve.
#   aws-ebs-csi  Provisions EBS volumes for PersistentVolumeClaims. Without it,
#                the MySQL StatefulSet's PVC stays Pending forever.
#
# Managing them as EKS add-ons (rather than raw manifests) means AWS handles
# version compatibility with the control plane and upgrades them in place.
#
# The EBS CSI driver in particular is the one most often missed: it stopped
# being bundled with EKS in 1.23, which is why a StatefulSet that worked on an
# older cluster silently hangs on a new one.
# ==============================================================================

# ------------------------------------------------------------------------------
# Resolve the newest compatible version of each add-on
# ------------------------------------------------------------------------------
# Add-on versions are tied to the Kubernetes minor version. Looking them up
# rather than hardcoding means bumping `kubernetes_version` does not also
# require hunting down four new add-on version strings.
data "aws_eks_addon_version" "this" {
  for_each = toset([
    "vpc-cni",
    "kube-proxy",
    "coredns",
    "aws-ebs-csi-driver",
  ])

  addon_name         = each.value
  kubernetes_version = aws_eks_cluster.this.version

  # Use the version AWS marks as default for this Kubernetes release — the
  # conservative, most-tested choice — rather than the absolute newest.
  most_recent = false
}

# ------------------------------------------------------------------------------
# VPC CNI — pod networking
# ------------------------------------------------------------------------------
resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "vpc-cni"
  addon_version = data.aws_eks_addon_version.this["vpc-cni"].version

  # OVERWRITE: if a self-managed copy of the CNI already exists (every EKS
  # cluster boots with one), replace it instead of failing the apply.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Enable Prefix Delegation to massively increase pod density on small instances
  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
  })

  tags = var.tags
}

# ------------------------------------------------------------------------------
# kube-proxy — Service networking
# ------------------------------------------------------------------------------
resource "aws_eks_addon" "kube_proxy" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "kube-proxy"
  addon_version = data.aws_eks_addon_version.this["kube-proxy"].version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

# ------------------------------------------------------------------------------
# CoreDNS — cluster DNS
# ------------------------------------------------------------------------------
resource "aws_eks_addon" "coredns" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "coredns"
  addon_version = data.aws_eks_addon_version.this["coredns"].version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # CoreDNS runs as a Deployment, so unlike the two DaemonSets above it needs a
  # NODE to schedule onto. Installing it before the node group exists leaves its
  # pods Pending and the add-on stuck in DEGRADED.
  depends_on = [aws_eks_node_group.this]

  tags = var.tags
}

# ------------------------------------------------------------------------------
# EBS CSI Driver — dynamic PersistentVolume provisioning
# ------------------------------------------------------------------------------
resource "aws_eks_addon" "ebs_csi" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = data.aws_eks_addon_version.this["aws-ebs-csi-driver"].version

  # This is the link that makes IRSA work: EKS annotates the driver's
  # ServiceAccount (kube-system/ebs-csi-controller-sa) with this role ARN, and
  # the trust policy in irsa.tf only accepts tokens from that exact
  # namespace/ServiceAccount pair.
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.this,
    aws_iam_role_policy_attachment.ebs_csi,
  ]

  tags = var.tags
}
