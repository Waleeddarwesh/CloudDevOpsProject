# ==============================================================================
# Server module — inputs
# ==============================================================================

variable "name_prefix" {
  description = "Prefix used in resource names and tags."
  type        = string
}

variable "vpc_id" {
  description = "VPC in which to create the Security Group."
  type        = string
}

variable "subnet_id" {
  description = "Public subnet to launch the Jenkins instance into."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 50
}

variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH access."
  type        = string
}

variable "allowed_ssh_cidrs" {
  description = "CIDRs permitted to reach TCP/22. Should be your public IP only."
  type        = list(string)
  default     = []
}

variable "allowed_jenkins_ui_cidrs" {
  description = "CIDRs permitted to reach the Jenkins UI on TCP/8080."
  type        = list(string)
  default     = []
}

variable "enable_sonarqube" {
  description = "Also open TCP/9000 for the SonarQube container installed by Ansible."
  type        = bool
  default     = true
}

variable "ecr_repository_arns" {
  description = "ECR repository ARNs the Jenkins role may push to. Scoping to these ARNs rather than \"*\" means a compromised Jenkins cannot overwrite images in unrelated repositories."
  type        = list(string)
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster Jenkins may describe. The ARN is reconstructed inside the module to avoid a dependency cycle with the EKS module."
  type        = string
}

variable "tags" {
  description = "Additional tags merged onto every resource in this module."
  type        = map(string)
  default     = {}
}
