# ==============================================================================
# EKS module — outputs
# ==============================================================================

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "HTTPS endpoint of the Kubernetes API server."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the control plane."
  value       = aws_eks_cluster.this.version
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA certificate for the cluster. kubectl uses it to verify the API server."
  value       = aws_eks_cluster.this.certificate_authority[0].data
  # Not secret (it is a public certificate), but marked sensitive to keep a
  # multi-kilobyte blob out of the plan output.
  sensitive = true
}

output "cluster_security_group_id" {
  description = "EKS-managed security group covering control-plane-to-node traffic."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

# ------------------------------------------------------------------------------
# OIDC / IRSA
# ------------------------------------------------------------------------------

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN. Needed to build additional IRSA roles for controllers such as ExternalDNS or the Secrets Store CSI driver."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  description = "OIDC issuer URL with the https:// scheme stripped, as used in IAM trust-policy conditions."
  value       = local.oidc_provider_url
}

output "aws_load_balancer_controller_role_arn" {
  description = "IRSA role for the AWS Load Balancer Controller. Pass to Helm as serviceAccount.annotations.\"eks\\.amazonaws\\.com/role-arn\"."
  value       = aws_iam_role.lb_controller.arn
}

output "ebs_csi_driver_role_arn" {
  description = "IRSA role used by the EBS CSI driver add-on."
  value       = aws_iam_role.ebs_csi.arn
}

output "cluster_autoscaler_role_arn" {
  description = "IRSA role for the Cluster Autoscaler, if you choose to install it."
  value       = aws_iam_role.cluster_autoscaler.arn
}

# ------------------------------------------------------------------------------
# Node group
# ------------------------------------------------------------------------------

output "node_group_arn" {
  description = "ARN of the managed node group."
  value       = aws_eks_node_group.this.arn
}

output "node_role_arn" {
  description = "IAM role assumed by the worker nodes."
  value       = aws_iam_role.node.arn
}

output "node_security_group_id" {
  description = "Security group attached to the worker nodes, from the node group's remote access configuration."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

# ------------------------------------------------------------------------------
# Encryption
# ------------------------------------------------------------------------------

output "kms_key_arn" {
  description = "KMS key encrypting Kubernetes Secrets at rest in etcd."
  value       = aws_kms_key.eks.arn
}
