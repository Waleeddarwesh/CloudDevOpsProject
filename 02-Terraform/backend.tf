# ==============================================================================
# Remote State Backend — Amazon S3
# ==============================================================================
# By default Terraform writes terraform.tfstate to the local disk. That is fatal
# for team work and for CI:
#
#   * State is the only record mapping your code to real AWS resource IDs.
#     Lose it and Terraform will try to re-create infrastructure that already
#     exists, or orphan resources it can no longer see.
#   * A local file cannot be shared, so two engineers (or Jenkins and a laptop)
#     immediately diverge.
#   * State contains sensitive values in plaintext — DB passwords, private keys.
#
# Moving state to S3 solves all three: one shared, versioned, encrypted copy,
# with locking so two `apply` runs cannot interleave and corrupt it.
#
# ------------------------------------------------------------------------------
# IMPORTANT — chicken-and-egg
# ------------------------------------------------------------------------------
# The S3 bucket must exist BEFORE this backend can initialise. Create it once
# with the separate root module in ./bootstrap (which uses local state on
# purpose), then run `terraform init` here:
#
#     cd bootstrap && terraform init && terraform apply
#     cd ..         && terraform init -backend-config=backend.hcl
#
# The bucket name is intentionally NOT hardcoded here — S3 bucket names are
# globally unique across all AWS accounts, so a literal value in Git would break
# for the next person to clone this repo. Values come from backend.hcl, which is
# gitignored (see backend.hcl.example).
# ==============================================================================

terraform {
  backend "s3" {
    # bucket / key / region are supplied via:
    #     terraform init -backend-config=backend.hcl
    #
    # Backend blocks cannot use variables or interpolation — this is a hard
    # Terraform limitation, because the backend is initialised before variables
    # are evaluated. Partial configuration is the supported workaround.

    # Server-side encryption of the state object at rest (AES-256 / SSE-KMS).
    encrypt = true

    # State locking via a native S3 conditional-write lock file
    # (`<key>.tflock`). Terraform 1.10+ only.
    #
    # This replaces the old `dynamodb_table` argument, which required a separate
    # DynamoDB table purely to hold a lock row and is deprecated as of Terraform
    # 1.11. One less resource to provision, pay for, and forget to clean up.
    use_lockfile = true
  }
}
