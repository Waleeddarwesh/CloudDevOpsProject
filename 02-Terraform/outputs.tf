# ==============================================================================
# Root module outputs
# ==============================================================================
# These are the hand-off points between Terraform and every later phase:
# Ansible reads the Jenkins IP, the Jenkins pipelines read the ECR registry,
# and kubectl/ArgoCD read the cluster name.
#
# Retrieve a single value in a script with:
#     terraform output -raw jenkins_public_ip
# ==============================================================================

# ------------------------------------------------------------------------------
# Network
# ------------------------------------------------------------------------------

output "vpc_id" {
  description = "ID of the VPC hosting all project resources."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (Jenkins, NAT Gateway, internet-facing ALB)."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (EKS worker nodes)."
  value       = module.network.private_subnet_ids
}

# ------------------------------------------------------------------------------
# Jenkins server
# ------------------------------------------------------------------------------

output "jenkins_public_ip" {
  description = "Elastic IP of the Jenkins server. Stable across stop/start, so the Ansible inventory and any GitHub webhook stay valid."
  value       = module.server.public_ip
}

output "jenkins_url" {
  description = "Jenkins web UI address."
  value       = "http://${module.server.public_ip}:8080"
}

output "jenkins_ssh_command" {
  description = "Ready-to-paste SSH command for the Jenkins server."
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${module.server.public_ip}"
}

output "jenkins_iam_role_arn" {
  description = "IAM role attached to the Jenkins instance profile. Grants ECR push and EKS describe without any long-lived access key on the instance."
  value       = module.server.iam_role_arn
}

# ------------------------------------------------------------------------------
# EKS
# ------------------------------------------------------------------------------

output "eks_cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "eks_oidc_provider_arn" {
  description = "IAM OIDC provider ARN for the cluster. Required to create IRSA roles for controllers such as the AWS Load Balancer Controller."
  value       = module.eks.oidc_provider_arn
}

output "aws_load_balancer_controller_role_arn" {
  description = "IRSA role ARN to annotate onto the aws-load-balancer-controller ServiceAccount during Helm installation."
  value       = module.eks.aws_load_balancer_controller_role_arn
}

output "configure_kubectl" {
  description = "Command that writes this cluster into your local kubeconfig."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

# ------------------------------------------------------------------------------
# ECR
# ------------------------------------------------------------------------------

output "ecr_registry" {
  description = "Private registry hostname. Substitute for ECR_REGISTRY in the Jenkins pipelines and for the image prefix in the Kubernetes manifests."
  value       = local.ecr_registry
}

output "ecr_repository_urls" {
  description = "Full push/pull URL of each microservice repository."
  value       = module.ecr.repository_urls
}

output "ecr_login_command" {
  description = "Authenticate the local Docker daemon against this account's ECR registry."
  value       = "aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${local.ecr_registry}"
}

# ------------------------------------------------------------------------------
# Convenience summary
# ------------------------------------------------------------------------------

output "next_steps" {
  description = "What to run after `terraform apply` completes."
  value       = <<-EOT

    ┌────────────────────────────────────────────────────────────────────────┐
    │  Infrastructure ready — next steps                                     │
    └────────────────────────────────────────────────────────────────────────┘

    1. Configure the Jenkins server with Ansible:
         cd ../03-Ansible
         ansible-inventory --graph          # confirm the EC2 instance is discovered
         ansible-playbook playbook.yml --vault-password-file .vault_pass

    2. Open Jenkins and unlock it:
         ${module.server.public_ip}:8080
         ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${module.server.public_ip} \
           'sudo cat /var/lib/jenkins/secrets/initialAdminPassword'

    3. Connect kubectl to the cluster:
         aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}
         kubectl get nodes

    4. Install the AWS Load Balancer Controller (required by the Ingress),
       annotating its ServiceAccount with this IRSA role:
         ${module.eks.aws_load_balancer_controller_role_arn}

    5. Update the ECR registry ID in 04-Kubernetes/manifests/kustomization.yaml:
         ${local.ecr_registry}

  EOT
}
