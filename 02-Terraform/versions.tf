# ==============================================================================
# Terraform and provider version constraints
# ==============================================================================
# Pinning versions is what makes infrastructure reproducible. Without these
# blocks, `terraform init` resolves the newest provider available on the day it
# runs — so the same code can produce a different plan next month, or fail
# outright after a major-version release removes an argument.
# ==============================================================================

terraform {
  # >= 1.10 is required for S3 native state locking (`use_lockfile`) in
  # backend.tf, which replaces the legacy DynamoDB lock table.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # ~> 5.80 means ">= 5.80.0, < 6.0.0" — patch and minor upgrades are
      # allowed (bug fixes, new resources), but a breaking 6.x release cannot
      # be pulled in silently.
      version = "~> 5.80"
    }

    # Reads the EKS OIDC issuer's TLS certificate so its SHA-1 thumbprint can be
    # registered with IAM. Required to enable IRSA (IAM Roles for Service
    # Accounts) — see modules/eks/irsa.tf.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
