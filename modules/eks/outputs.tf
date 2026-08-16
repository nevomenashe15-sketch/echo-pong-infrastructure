output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster. Used as the aws:SourceArn condition in every Pod Identity trust policy."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA bundle for the Kubernetes API."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  description = "Kubernetes minor version actually running on the control plane."
  value       = aws_eks_cluster.this.version
}

output "cluster_security_group_id" {
  description = "Security group attached to the control plane ENIs."
  value       = aws_security_group.cluster.id
}

output "cluster_primary_security_group_id" {
  description = "The EKS-managed cluster security group. This is what the AWS Load Balancer Controller expects to find on node ENIs."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group attached to worker nodes. Tagged for Karpenter discovery."
  value       = aws_security_group.node.id
}

output "system_node_role_arn" {
  description = "IAM role ARN of the system managed node group. Granted pull on the production ECR repository."
  value       = aws_iam_role.node.arn
}

output "karpenter_node_role_arn" {
  description = "IAM role ARN Karpenter-launched nodes assume. echo-pong-gitops references this from its EC2NodeClass."
  value       = aws_iam_role.karpenter_node.arn
}

output "karpenter_node_role_name" {
  description = "Name of the Karpenter node IAM role."
  value       = aws_iam_role.karpenter_node.name
}

output "karpenter_instance_profile_name" {
  description = "Instance profile name for Karpenter-launched nodes. Set this as spec.instanceProfile in the EC2NodeClass in echo-pong-gitops."
  value       = aws_iam_instance_profile.karpenter_node.name
}

output "oidc_provider_arn" {
  description = "ARN of the cluster IRSA OIDC provider, or empty if disabled. No IRSA roles use it today -- it is the documented fallback if a controller lacks Pod Identity support."
  value       = var.enable_irsa_oidc_provider ? aws_iam_openid_connect_provider.cluster[0].arn : ""
}

output "oidc_provider_url" {
  description = "Issuer URL of the cluster OIDC provider."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}
