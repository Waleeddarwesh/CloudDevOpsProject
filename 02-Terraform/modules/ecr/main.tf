# ==============================================================================
# ECR Module — private container registries
# ==============================================================================
# One repository per microservice:
#
#   <account>.dkr.ecr.<region>.amazonaws.com/ivolve-frontend
#   <account>.dkr.ecr.<region>.amazonaws.com/ivolve-auth-service
#   <account>.dkr.ecr.<region>.amazonaws.com/ivolve-roadmap-service
#
# Separate repositories (rather than one repository with a service prefix in the
# tag) give per-service IAM scoping, per-service lifecycle rules, and a clean
# per-service vulnerability history.
# ==============================================================================

resource "aws_ecr_repository" "this" {
  # for_each over a set, not count over a list. With `count`, removing the first
  # repository from the list would shift every index and Terraform would plan to
  # DESTROY AND RECREATE the remaining repositories — deleting live images.
  # for_each keys state by repository name, so unrelated entries are untouched.
  for_each = toset(var.repository_names)

  name = each.value

  # IMMUTABLE prevents an existing tag from being overwritten.
  #
  # This is the single most valuable setting here. With MUTABLE tags, a rebuild
  # can silently replace the image behind a tag that is already running in the
  # cluster, so `ivolve-frontend:42` no longer means what it meant when it was
  # scanned and approved. Immutability makes every tag a permanent, auditable
  # reference — which is exactly what a GitOps deployment records in Git.
  #
  # The pipeline therefore tags with <build>-<git-sha>, never a moving :latest.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    # Basic (free) CVE scan on every push. This is a second opinion alongside
    # the Trivy gate in the Jenkins pipeline: Trivy blocks the push, ECR keeps
    # re-evaluating stored images as new CVEs are published, so an image that
    # was clean at build time is re-flagged when a new advisory lands.
    scan_on_push = true
  }

  encryption_configuration {
    # AES-256 with an AWS-managed key. KMS would allow a customer-managed key
    # and cross-account grant control, at extra cost per API call.
    encryption_type = "AES256"
  }

  force_delete = var.force_delete

  tags = merge(var.tags, {
    Name    = each.value
    Service = each.value
  })
}

# ------------------------------------------------------------------------------
# Lifecycle policy
# ------------------------------------------------------------------------------
# Without this, storage grows forever. A pipeline that pushes on every commit
# accumulates hundreds of ~200 MB images, and ECR bills per GB-month.
#
# Rules are evaluated in ascending rulePriority and each image is actioned by
# the FIRST rule it matches — so the untagged rule must come first, otherwise
# the "keep last N" rule would already have claimed those images.
# ------------------------------------------------------------------------------
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${var.untagged_expiry_days} day(s)"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expiry_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the ${var.image_retention_count} most recent build images"
        selection = {
          tagStatus = "tagged"
          # Matches the pipeline's <buildNumber>-<gitSha> tag format.
          tagPrefixList = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
          countType     = "imageCountMoreThan"
          countNumber   = var.image_retention_count
        }
        action = { type = "expire" }
      },
    ]
  })
}

# ------------------------------------------------------------------------------
# Repository policy
# ------------------------------------------------------------------------------
# Restricts pull access to principals inside this AWS account. ECR repositories
# are private by default, but an explicit policy documents the intent and stops
# a later `aws ecr set-repository-policy` from silently widening access without
# a Terraform diff showing it.
# ------------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "repository" {
  statement {
    sid    = "AllowSameAccountPull"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
    ]
  }
}

resource "aws_ecr_repository_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name
  policy     = data.aws_iam_policy_document.repository.json
}
