output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.vpc.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = var.vpc_cidr
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = aws_subnet.subnet_eks_private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = aws_subnet.subnet_eks_public[*].id
}
