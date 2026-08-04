output "state_bucket_name" {
  description = "Name of the state bucket. Copy this into ../backend.hcl as the `bucket` value."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket."
  value       = aws_s3_bucket.state.arn
}

output "backend_hcl" {
  description = "Ready-made backend.hcl contents for the parent configuration."
  value       = <<-EOT

    Write the following to ../backend.hcl, then run:
        cd .. && terraform init -backend-config=backend.hcl

    ────────────────────────────────────────────────────────────
    bucket = "${aws_s3_bucket.state.id}"
    key    = "capstone/dev/terraform.tfstate"
    region = "${var.aws_region}"
    ────────────────────────────────────────────────────────────

  EOT
}
