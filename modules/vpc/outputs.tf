output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs. Internet-facing ALBs are placed here by the AWS Load Balancer Controller."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs. All EKS nodes and pods live here."
  value       = aws_subnet.private[*].id
}

output "private_route_table_ids" {
  description = "Private route table IDs, one per AZ."
  value       = aws_route_table.private[*].id
}

output "nat_gateway_public_ips" {
  description = "Public IPs of the NAT Gateways -- the source addresses all outbound cluster traffic appears from. Useful for third-party allow-lists."
  value       = aws_eip.nat[*].public_ip
}

output "vpc_endpoint_security_group_id" {
  description = "Security group protecting the interface VPC endpoints."
  value       = aws_security_group.vpc_endpoints.id
}
