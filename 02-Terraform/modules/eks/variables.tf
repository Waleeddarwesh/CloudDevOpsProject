# ==============================================================================
# EKS module — inputs
# ==============================================================================

variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version for the control plane."
  type        = string
  default     = "1.31"
}

# NOTE: there is deliberately no `vpc_id` variable here. EKS derives the VPC
# from the subnets passed to vpc_config, so accepting a vpc_id would be an
# unused input — flagged by tflint's terraform_unused_declarations rule and
# misleading to anyone reading the module interface.

variable "private_subnet_ids" {
  description = "Private subnets for the worker nodes. Must span at least two AZs."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "EKS requires subnets in at least two availability zones."
  }
}

variable "public_subnet_ids" {
  description = "Public subnets. Attached to the cluster so internet-facing load balancers can be provisioned by the AWS Load Balancer Controller."
  type        = list(string)
}

variable "node_instance_types" {
  description = "Instance types for the managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = "Desired number of worker nodes."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes."
  type        = number
  default     = 4
}

variable "node_disk_size" {
  description = "EBS volume size in GiB per worker node."
  type        = number
  default     = 30
}

variable "node_capacity_type" {
  description = "ON_DEMAND for predictable capacity, or SPOT for up to 90% savings at the cost of 2-minute interruption notices. SPOT is viable for stateless workloads with a PodDisruptionBudget."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs permitted to reach the public Kubernetes API endpoint."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_log_types" {
  description = "Control-plane log types published to CloudWatch Logs."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cluster_log_retention_days" {
  description = "Retention for the control-plane CloudWatch log group. Audit logs are verbose; unlimited retention gets expensive quickly."
  type        = number
  default     = 14
}

variable "admin_principal_arns" {
  description = "IAM user/role ARNs granted cluster-admin through EKS Access Entries."
  type        = list(string)
  default     = []
}

variable "jenkins_role_arn" {
  description = "ARN of the Jenkins instance role, granted a scoped Access Entry so the pipeline can verify a rollout with kubectl."
  type        = string
  default     = null
}

variable "create_jenkins_access_entry" {
  description = <<-EOT
    Whether to create the EKS Access Entry for the Jenkins role.

    This exists as a SEPARATE flag rather than deriving the decision from
    `jenkins_role_arn != null`, and the reason is a hard Terraform constraint:

      `count` must be resolvable at PLAN time. jenkins_role_arn is
      module.server.iam_role_arn, which is "(known after apply)" on a fresh
      deployment. Using it in a count expression fails with:

          Error: Invalid count argument
          The "count" value depends on resource attributes that cannot be
          determined until apply.

    A plain bool is known at plan time, so the count resolves cleanly. The
    unknown ARN is still fine as an ATTRIBUTE value — only the count is
    constrained.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags merged onto every resource in this module."
  type        = map(string)
  default     = {}
}
