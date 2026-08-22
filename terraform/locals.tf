locals {
  azs                    = slice(data.aws_availability_zones.azs_available.names, 0, 2)
  selected_public_cidrs  = slice(var.public_subnet_cidrs, 0, 2)
  selected_private_cidrs = slice(var.private_subnet_cidrs, 0, 2)

  vpc_name         = "vpc-${var.project_name}"
  eks_cluster_name = "eks-${var.project_name}"
  subnet_name      = "subnet-${var.project_name}"
}
