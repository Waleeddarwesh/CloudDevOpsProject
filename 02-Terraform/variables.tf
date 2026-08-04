# ==============================================================================
# Root module input variables
# ==============================================================================
# Every variable carries a `description` (rendered by `terraform-docs` and shown
# in the plan) and, where a wrong value would fail late and expensively, a
# `validation` block that fails immediately at plan time instead.
# ==============================================================================

# ------------------------------------------------------------------------------
# Project identity
# ------------------------------------------------------------------------------

variable "project_name" {
  description = "Project identifier. Used as the prefix for every resource name and as the Project cost-allocation tag."
  type        = string
  default     = "ivolve"

  validation {
    # Resource names derived from this end up in DNS names, IAM role names and
    # S3 keys, all of which reject uppercase or underscores.
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project_name))
    error_message = "project_name must be 2-21 characters, lowercase alphanumeric or hyphen, and start with a letter."
  }
}

variable "environment" {
  description = "Deployment environment. Separates resource names and state keys so dev and prod can never collide."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "owner" {
  description = "Team or individual responsible for these resources. Applied as the Owner tag for accountability and cleanup."
  type        = string
  default     = "waleed-darwesh"
}

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

# ------------------------------------------------------------------------------
# Networking
# ------------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC. /16 leaves ample room for subnets and for the large number of ENIs the VPC CNI assigns to EKS pods."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block, e.g. 10.0.0.0/16."
  }
}

variable "availability_zones" {
  description = "Availability Zones to spread subnets across. At least two are required: EKS refuses to create a cluster in a single AZ, and the project brief requires the two worker nodes to land in different AZs."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least two availability zones are required for EKS high availability."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDRs for the public subnets (one per AZ). Hosts the NAT Gateway, the Jenkins EC2 instance, and the internet-facing ALB created by the Ingress."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDRs for the private subnets (one per AZ). Hosts the EKS worker nodes, which have no public IP and reach the internet only through the NAT Gateway."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "single_nat_gateway" {
  description = <<-EOT
    Deploy one shared NAT Gateway (true) instead of one per AZ (false).

    true  — ~$32/month. Cheapest, and the default for this project. The trade-off
            is a single point of failure: if that AZ goes down, private subnets in
            every other AZ lose outbound internet (so pods cannot pull images).
    false — ~$32/month PER AZ, but each AZ egresses independently. This is the
            correct setting for production.
  EOT
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Publish VPC Flow Logs to CloudWatch Logs. Essential for network forensics and for debugging Security Group / NACL rejections, at the cost of CloudWatch ingestion charges."
  type        = bool
  default     = true
}

variable "flow_logs_retention_days" {
  description = "CloudWatch retention for VPC Flow Logs. 0 means retain forever (and bill forever)."
  type        = number
  default     = 14
}

# ------------------------------------------------------------------------------
# Jenkins server
# ------------------------------------------------------------------------------

variable "jenkins_instance_type" {
  description = "EC2 instance type for Jenkins. t3.medium (2 vCPU / 4 GiB) is the practical minimum — Jenkins plus a Maven build plus a Trivy scan will OOM on t3.small."
  type        = string
  default     = "t3.medium"
}

variable "jenkins_root_volume_size" {
  description = "Root EBS volume size in GiB. Docker layer cache, the Maven ~/.m2 repository and the Trivy vulnerability database together consume far more than the 8 GiB default."
  type        = number
  default     = 50
}

variable "key_name" {
  description = "Name of an existing EC2 key pair used for SSH access. Create it first with: aws ec2 create-key-pair --key-name ivolve-key --query KeyMaterial --output text > ~/.ssh/ivolve-key.pem"
  type        = string
  default     = "ivolve-key"
}

variable "allowed_ssh_cidrs" {
  description = <<-EOT
    CIDR blocks permitted to reach port 22 on the Jenkins server.

    SECURITY: leave this as the placeholder and Terraform will refuse to apply.
    Set it to YOUR_PUBLIC_IP/32 — an SSH port open to 0.0.0.0/0 is found by
    automated scanners within minutes and is the single most common way a lab
    AWS account gets compromised and used for crypto mining.

    Find your IP with: curl -s https://checkip.amazonaws.com
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.allowed_ssh_cidrs, "0.0.0.0/0")
    error_message = "Refusing to open SSH (port 22) to the entire internet. Set allowed_ssh_cidrs to your own IP, e.g. [\"203.0.113.9/32\"]."
  }
}

variable "allowed_jenkins_ui_cidrs" {
  description = "CIDR blocks permitted to reach the Jenkins web UI on port 8080. Restrict to your own IP; the setup wizard is unauthenticated until you complete it."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.allowed_jenkins_ui_cidrs, "0.0.0.0/0")
    error_message = "Refusing to expose the Jenkins UI to the entire internet. Set allowed_jenkins_ui_cidrs to your own IP."
  }
}

variable "enable_sonarqube" {
  description = "Open port 9000 on the Jenkins server for the SonarQube container installed by the Ansible role."
  type        = bool
  default     = true
}

# ------------------------------------------------------------------------------
# EKS
# ------------------------------------------------------------------------------

variable "kubernetes_version" {
  description = "EKS control-plane version. AWS supports roughly the latest four minor versions; staying within them avoids forced upgrades."
  type        = string
  default     = "1.31"
}

variable "node_instance_types" {
  description = "Instance types for the managed node group. t3.medium supports up to 17 pods each under the VPC CNI, which comfortably covers this workload."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = "Desired worker node count. The project brief requires 2, one per private subnet / AZ."
  type        = number
  default     = 2

  validation {
    condition     = var.node_desired_size >= 2
    error_message = "At least 2 nodes are required so pods can be spread across availability zones."
  }
}

variable "node_min_size" {
  description = "Minimum worker node count for the managed node group's autoscaling group."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum worker node count. Headroom for HPA-driven scale-out and for surge capacity during a rolling node upgrade."
  type        = number
  default     = 4
}

variable "node_disk_size" {
  description = "EBS volume size in GiB per worker node, holding the container image cache and ephemeral pod storage."
  type        = number
  default     = 30
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Narrow this to your IP and the Jenkins EIP in a real deployment; 0.0.0.0/0 still requires valid IAM credentials but leaves the endpoint enumerable."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_log_types" {
  description = "EKS control-plane log streams to publish to CloudWatch. 'audit' and 'authenticator' are the two that matter for security investigations."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cluster_admin_principals" {
  description = "Additional IAM user/role ARNs granted cluster-admin via EKS Access Entries. The identity that runs `terraform apply` is added automatically. Leave empty unless a teammate also needs kubectl access."
  type        = list(string)
  default     = []
}

# ------------------------------------------------------------------------------
# ECR
# ------------------------------------------------------------------------------

variable "ecr_repository_names" {
  description = "ECR repositories to create — one per microservice. These names must match the imageName passed to the Jenkins shared library."
  type        = list(string)
  default     = ["ivolve-frontend", "ivolve-auth-service", "ivolve-roadmap-service"]
}

variable "ecr_image_retention_count" {
  description = "Number of tagged images to keep per repository before the lifecycle policy expires the oldest. Prevents unbounded storage growth from a pipeline that pushes on every commit."
  type        = number
  default     = 10
}

variable "ecr_force_delete" {
  description = "Allow `terraform destroy` to delete repositories that still contain images. Convenient for a lab; set to false in production so a destroy cannot silently discard the only copy of a released image."
  type        = bool
  default     = true
}
