output "viewer_certificate_arn" {
  description = "ARN of the us-east-1 ACM certificate for CloudFront."
  value       = aws_acm_certificate_validation.viewer.certificate_arn
}

output "origin_certificate_arn" {
  description = "ARN of the regional ACM certificate for the ALB. echo-pong-gitops sets this on the Ingress via alb.ingress.kubernetes.io/certificate-arn."
  value       = aws_acm_certificate_validation.origin.certificate_arn
}

output "domain_name" {
  description = "Public FQDN served by CloudFront."
  value       = var.domain_name
}

output "origin_fqdn" {
  description = "FQDN CloudFront uses as its origin. external-dns in echo-pong-gitops must publish this name for the app's ALB."
  value       = local.origin_fqdn
}
