output "alb_controller_role_arn" {
  description = "ARN of the AWS Load Balancer Controller role. Provided for reference/audit -- with Pod Identity, echo-pong-gitops does NOT need to annotate the ServiceAccount with it."
  value       = aws_iam_role.alb_controller.arn
}

output "external_secrets_role_arn" {
  description = "ARN of the External Secrets Operator role."
  value       = aws_iam_role.external_secrets.arn
}

output "karpenter_controller_role_arn" {
  description = "ARN of the Karpenter controller role."
  value       = aws_iam_role.karpenter_controller.arn
}

output "pod_identity_associations" {
  description = "Map of controller -> namespace/serviceaccount the association is bound to. echo-pong-gitops MUST deploy each controller into exactly these coordinates or it will silently get no AWS credentials."
  value = {
    alb_controller   = "${var.alb_controller_namespace}/${var.alb_controller_service_account}"
    external_secrets = "${var.external_secrets_namespace}/${var.external_secrets_service_account}"
    karpenter        = "${var.karpenter_namespace}/${var.karpenter_service_account}"
  }
}
