# ==============================================================================
# Network module — outputs
# ==============================================================================

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC. Used by the server module to scope Security Group rules to in-VPC sources."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, ordered to match availability_zones."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets, ordered to match availability_zones."
  value       = aws_subnet.private[*].id
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway."
  value       = aws_internet_gateway.this.id
}

output "nat_gateway_ids" {
  description = "IDs of the NAT Gateway(s) providing outbound access for private subnets."
  value       = aws_nat_gateway.this[*].id
}

output "nat_public_ips" {
  description = "Elastic IPs of the NAT Gateway(s). These are the source addresses the internet sees for all worker-node egress — allowlist them on any third-party API the workload calls."
  value       = aws_eip.nat[*].public_ip
}

output "public_route_table_id" {
  description = "ID of the shared public route table."
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "IDs of the per-AZ private route tables."
  value       = aws_route_table.private[*].id
}

output "public_network_acl_id" {
  description = "ID of the Network ACL guarding the public subnets."
  value       = aws_network_acl.public.id
}

output "private_network_acl_id" {
  description = "ID of the Network ACL guarding the private subnets."
  value       = aws_network_acl.private.id
}

output "flow_log_group_name" {
  description = "CloudWatch Logs group receiving VPC Flow Logs, or null when disabled."
  value       = var.enable_flow_logs ? aws_cloudwatch_log_group.flow_logs[0].name : null
}
