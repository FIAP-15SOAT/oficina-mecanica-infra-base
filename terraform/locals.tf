locals {
  azs                    = slice(data.aws_availability_zones.azs_available.names, 0, 2)
  selected_public_cidrs  = slice(var.public_subnet_cidrs, 0, 2)
  selected_private_cidrs = slice(var.private_subnet_cidrs, 0, 2)

  vpc_name                   = "vpc-${var.project_name}"
  eks_cluster_name           = "eks-${var.project_name}"
  eks_subnet_name            = "subnet-eks-${var.project_name}"
  ecr_app_repo_name          = "ecr-${var.project_name}-app-repo"
  cw_lg_eks_cluster_tag_name = "cw-lg-eks-cluster-${var.project_name}"
  secgrp_eks_cluster_name    = "secgrp-eks-cluster-${var.project_name}"
  eks_node_group_name        = "ng-eks-${var.project_name}-default"
}
