output "vpc_id" {
  description = "VPC id."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "VPC CIDR."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet ids (ordered by AZ name)."
  value       = [for az in sort(keys(aws_subnet.public)) : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  description = "Private subnet ids (ordered by AZ name)."
  value       = [for az in sort(keys(aws_subnet.private)) : aws_subnet.private[az].id]
}

output "availability_zones" {
  description = "AZs used by this network."
  value       = local.azs
}

output "nat_gateway_id" {
  description = "NAT gateway id when enabled."
  value       = try(aws_nat_gateway.this[0].id, null)
}
