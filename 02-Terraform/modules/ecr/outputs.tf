# ==============================================================================
# ECR module — outputs
# ==============================================================================

output "repository_urls" {
  description = "Map of repository name to full push/pull URL."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "repository_arns" {
  description = "ARNs of every repository. Consumed by the server module to scope the Jenkins IAM policy to these repositories only, rather than granting ecr:* on Resource \"*\"."
  value       = [for repo in aws_ecr_repository.this : repo.arn]
}

output "repository_names" {
  description = "Names of the created repositories."
  value       = [for repo in aws_ecr_repository.this : repo.name]
}

output "registry_id" {
  description = "AWS account ID that owns the registry."
  value       = data.aws_caller_identity.current.account_id
}
