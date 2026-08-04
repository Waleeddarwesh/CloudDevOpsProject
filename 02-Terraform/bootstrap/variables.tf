variable "project_name" {
  description = "Project identifier, used as the bucket-name prefix. Must match project_name in the parent configuration."
  type        = string
  default     = "ivolve"
}

variable "aws_region" {
  description = "Region for the state bucket. Keep it the same as the infrastructure region to avoid cross-region latency on every plan."
  type        = string
  default     = "us-east-1"
}

variable "state_version_retention_days" {
  description = "Days to retain non-current state versions before the lifecycle rule expires them."
  type        = number
  default     = 90
}
