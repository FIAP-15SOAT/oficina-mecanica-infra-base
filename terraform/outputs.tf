output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.eks_cluster.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = aws_eks_cluster.eks_cluster.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded EKS cluster certificate authority data"
  value       = aws_eks_cluster.eks_cluster.certificate_authority[0].data
}

output "cluster_version" {
  description = "Kubernetes version in use"
  value       = aws_eks_cluster.eks_cluster.version
}

output "vpc_id" {
  description = "VPC ID for EKS"
  value       = aws_vpc.vpc.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = aws_subnet.subnet_eks_private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = aws_subnet.subnet_eks_public[*].id
}

output "zz_next_steps" {
  description = "Post-deploy quick guide shown at the end of terraform output"
  value       = <<-EOT
  1) Set AWS credentials first
  Bash:
    export AWS_ACCESS_KEY_ID="<YOUR_ACCESS_KEY_ID>"
    export AWS_SECRET_ACCESS_KEY="<YOUR_SECRET_ACCESS_KEY>"
    export AWS_SESSION_TOKEN="<YOUR_SESSION_TOKEN>"
    export AWS_DEFAULT_REGION="${var.aws_region}"

  PowerShell:
    $Env:AWS_ACCESS_KEY_ID="<YOUR_ACCESS_KEY_ID>"
    $Env:AWS_SECRET_ACCESS_KEY="<YOUR_SECRET_ACCESS_KEY>"
    $Env:AWS_SESSION_TOKEN="<YOUR_SESSION_TOKEN>"
    $Env:AWS_DEFAULT_REGION="${var.aws_region}"

  2) Update kubeconfig for this cluster
    aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.eks_cluster.name}

  3) Validate kubectl access
    kubectl get nodes
  EOT
}
