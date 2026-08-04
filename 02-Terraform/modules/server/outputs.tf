# ==============================================================================
# Server module — outputs
# ==============================================================================

output "instance_id" {
  description = "EC2 instance ID of the Jenkins server."
  value       = aws_instance.jenkins.id
}

output "public_ip" {
  description = "Elastic IP of the Jenkins server — stable across stop/start."
  value       = aws_eip.jenkins.public_ip
}

output "private_ip" {
  description = "Private IP inside the VPC."
  value       = aws_instance.jenkins.private_ip
}

output "security_group_id" {
  description = "ID of the Jenkins Security Group."
  value       = aws_security_group.jenkins.id
}

output "iam_role_arn" {
  description = "ARN of the instance role. Consumed by the EKS module to create an Access Entry granting Jenkins kubectl access to the cluster."
  value       = aws_iam_role.jenkins.arn
}

output "iam_role_name" {
  description = "Name of the instance role."
  value       = aws_iam_role.jenkins.name
}

output "instance_profile_name" {
  description = "Name of the IAM instance profile attached to the server."
  value       = aws_iam_instance_profile.jenkins.name
}

output "ami_id" {
  description = "AMI the instance was launched from."
  value       = data.aws_ami.ubuntu.id
}
