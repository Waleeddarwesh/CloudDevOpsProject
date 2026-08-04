# ==============================================================================
# Provider configuration
# ==============================================================================

provider "aws" {
  region = var.aws_region

  # default_tags applies these tags to every taggable resource created by this
  # provider — across all four modules — without repeating a `tags` block on
  # each resource.
  #
  # This matters well beyond tidiness:
  #   * Cost allocation: AWS Cost Explorer can break spend down by Project and
  #     Environment only if the tags are actually present.
  #   * Cleanup: `aws resourcegroupstaggingapi get-resources --tag-filters
  #     Key=Project,Values=CloudDevOpsProject` finds every orphaned resource.
  #   * Incident response: ManagedBy=Terraform tells an on-call engineer not to
  #     fix this by hand in the console, because the next apply would revert it.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = var.owner
      Repository  = "CloudDevOpsProject"
    }
  }
}

# ------------------------------------------------------------------------------
# Identity / region lookups
# ------------------------------------------------------------------------------
# Resolved from the credentials Terraform is currently using, so the account ID
# and region never have to be hardcoded anywhere in this configuration.
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}
