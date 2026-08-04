# ==============================================================================
# Network module — inputs
# ==============================================================================

variable "name_prefix" {
  description = "Prefix for all resource names, e.g. ivolve-dev."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "availability_zones" {
  description = "Availability Zones to distribute subnets across."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets, index-aligned with availability_zones."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_cidrs) >= 2
    error_message = "At least two public subnets are required — an internet-facing ALB must have subnets in two different AZs."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets, index-aligned with availability_zones."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_cidrs) >= 2
    error_message = "At least two private subnets are required so the two EKS worker nodes land in different AZs."
  }
}

variable "single_nat_gateway" {
  description = "Share one NAT Gateway across all AZs (cheap, single point of failure) instead of one per AZ (resilient, costs more)."
  type        = bool
  default     = true
}

variable "cluster_name" {
  description = "EKS cluster name. Used only for the kubernetes.io/cluster/<name> subnet discovery tag; passed in rather than read from the EKS module to avoid a dependency cycle."
  type        = string
}

variable "enable_flow_logs" {
  description = "Capture VPC Flow Logs into CloudWatch Logs."
  type        = bool
  default     = true
}

variable "flow_logs_retention_days" {
  description = "CloudWatch Logs retention in days for flow logs."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Additional tags merged onto every resource in this module."
  type        = map(string)
  default     = {}
}
