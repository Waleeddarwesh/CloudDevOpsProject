# ==============================================================================
# ECR module — inputs
# ==============================================================================

variable "name_prefix" {
  description = "Prefix used in resource names and tags."
  type        = string
}

variable "repository_names" {
  description = "Repository names to create — one per microservice."
  type        = list(string)
}

variable "image_retention_count" {
  description = "How many tagged images to keep per repository before the lifecycle policy expires the oldest."
  type        = number
  default     = 10
}

variable "untagged_expiry_days" {
  description = "Days before an untagged image is deleted. Untagged images are the previous versions of a moving tag such as :latest — they consume storage and can never be pulled by tag again."
  type        = number
  default     = 1
}

variable "force_delete" {
  description = "Permit `terraform destroy` to remove repositories that still contain images."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags merged onto every resource in this module."
  type        = map(string)
  default     = {}
}
