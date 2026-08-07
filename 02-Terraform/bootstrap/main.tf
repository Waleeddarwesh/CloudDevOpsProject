# ==============================================================================
# Terraform Backend Bootstrap
# ==============================================================================
# Solves the chicken-and-egg problem: the main configuration stores its state in
# an S3 bucket, but that bucket has to exist before `terraform init` can run.
#
# This is a SEPARATE root module that uses LOCAL state on purpose. It creates
# exactly one thing — the state bucket — and is run once, ever.
#
#     cd 02-Terraform/bootstrap
#     terraform init
#     terraform apply
#     # copy the bucket name into ../backend.hcl
#
# Its own terraform.tfstate describes a single bucket, so losing it is a
# five-minute `terraform import`, not a disaster. Commit it or don't; it holds
# nothing sensitive.
#
# NOTE: no DynamoDB lock table. Terraform 1.10+ locks state with a conditional
# write on an S3 object (`use_lockfile = true` in ../backend.tf), which makes
# the separate table redundant. It was deprecated in Terraform 1.11.
# ==============================================================================

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.57"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "Terraform"
      Purpose   = "terraform-remote-state"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  # S3 bucket names are globally unique across ALL AWS accounts, so a fixed
  # name like "ivolve-terraform-state" is almost certainly taken. Embedding the
  # account ID and region makes collision effectively impossible while keeping
  # the name predictable and readable.
  bucket_name = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
}

# ------------------------------------------------------------------------------
# State bucket
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  # Deliberately NOT force_destroy. This bucket holds the only record of what
  # infrastructure exists; `terraform destroy` here must not be able to silently
  # delete it along with every state version.
  force_destroy = false

  tags = {
    Name = local.bucket_name
  }
}

# ------------------------------------------------------------------------------
# Versioning — the single most important setting on this bucket
# ------------------------------------------------------------------------------
# Terraform overwrites the state object on every apply. Without versioning, a
# corrupted or accidentally-emptied state is unrecoverable, and Terraform loses
# track of every resource it manages — leaving orphaned infrastructure that must
# be imported by hand.
#
# With versioning, recovery is one command:
#     aws s3api list-object-versions --bucket <name> --prefix capstone/
#     aws s3api get-object --bucket <name> --key <key> --version-id <id> restored.tfstate
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ------------------------------------------------------------------------------
# Encryption at rest
# ------------------------------------------------------------------------------
# State files contain every value Terraform touched in PLAINTEXT — RDS
# passwords, private keys, generated secrets. They must be treated as a secrets
# store, because that is effectively what they are.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    # Uses the bucket key to reduce KMS request costs; harmless with AES256 and
    # correct if the algorithm is later switched to aws:kms.
    bucket_key_enabled = true
  }
}

# ------------------------------------------------------------------------------
# Block all public access
# ------------------------------------------------------------------------------
# Four independent switches, all enabled. Publicly readable state buckets are a
# recurring source of real-world cloud breaches — the state file hands an
# attacker a complete inventory of the environment plus its credentials.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------------------------------
# Ownership controls
# ------------------------------------------------------------------------------
# Disables ACLs entirely; access is governed by bucket policy and IAM only.
# This is the AWS-recommended default for new buckets.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ------------------------------------------------------------------------------
# Lifecycle — prune old state versions
# ------------------------------------------------------------------------------
# Versioning means every apply leaves another copy behind forever. Ninety days
# of history is far more than any realistic rollback needs, and keeps storage
# cost flat instead of growing linearly with pipeline activity.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.state_version_retention_days
    }

    # Multipart uploads that failed midway are invisible in the console but
    # still billed. This cleans them up.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ------------------------------------------------------------------------------
# Enforce TLS in transit
# ------------------------------------------------------------------------------
# Denies any request that did not arrive over HTTPS. Encryption at rest protects
# stored state; this protects it while it moves.
data "aws_iam_policy_document" "state" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  # The public access block must be in place first, otherwise applying a policy
  # with a "*" principal can trip the account-level public-policy guard.
  depends_on = [aws_s3_bucket_public_access_block.state]
}
