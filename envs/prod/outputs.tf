# =============================================================================
# Outputs -- envs/prod
# =============================================================================
# These are the contract with the sibling repositories. echo-pong-gitops and
# echo-pong-workflows consume them; nothing here is decorative.
#
# There is deliberately NO output for the origin verification secret value and
# NO output for the app's API token. See modules/cloudfront-waf/outputs.tf and
# modules/secrets-metadata/outputs.tf.
# =============================================================================

# --- Network ----------------------------------------------------------------
output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnets. All nodes and pods run here."
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnets. The AWS Load Balancer Controller places the app's internet-facing ALB here."
  value       = module.vpc.public_subnet_ids
}

output "nat_gateway_public_ips" {
  description = "Source IPs all outbound cluster traffic appears from. Give these to any third party that maintains an allow-list."
  value       = module.vpc.nat_gateway_public_ips
}

# --- Cluster ----------------------------------------------------------------
output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes minor version on the control plane."
  value       = module.eks.cluster_version
}

output "kubeconfig_command" {
  description = "How to get credentials for this cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

# --- Handoff to echo-pong-gitops --------------------------------------------
output "gitops_values" {
  description = <<-EOT
    Everything echo-pong-gitops needs, in one place. Feed these into the Helm
    values for this environment.

    Note what is NOT here: an IAM role ARN for the app's own ServiceAccount.
    The app pod holds no AWS identity -- External Secrets Operator projects the
    token into a Kubernetes Secret and the app reads it from a file.
  EOT
  value = {
    aws_region   = var.aws_region
    cluster_name = module.eks.cluster_name

    # The controllers MUST be deployed into exactly these namespace/SA
    # coordinates or the Pod Identity associations will not match and they will
    # silently get no AWS credentials.
    pod_identity_targets = module.pod_identity.pod_identity_associations

    # Karpenter EC2NodeClass inputs.
    karpenter_instance_profile = module.eks.karpenter_instance_profile_name
    karpenter_node_role_arn    = module.eks.karpenter_node_role_arn
    karpenter_discovery_tag    = module.eks.cluster_name

    # Ingress annotations for the app.
    alb_certificate_arn = module.route53_acm.origin_certificate_arn
    alb_wafv2_acl_arn   = module.cloudfront_waf.regional_web_acl_arn
    ingress_hostname    = module.route53_acm.origin_fqdn
    ingress_subnet_ids  = module.vpc.public_subnet_ids

    # ExternalSecret remoteRef.
    app_secret_arn  = module.app_secret.secret_arn
    app_secret_name = module.app_secret.secret_name
  }
}

output "alb_ingress_annotations" {
  description = "Copy-paste annotations for the app's Ingress in echo-pong-gitops. The wafv2-acl-arn one is NOT optional -- without it the ALB is reachable directly and the entire CloudFront edge is bypassable."
  value = {
    "alb.ingress.kubernetes.io/certificate-arn"              = module.route53_acm.origin_certificate_arn
    "alb.ingress.kubernetes.io/wafv2-acl-arn"                = module.cloudfront_waf.regional_web_acl_arn
    "alb.ingress.kubernetes.io/scheme"                       = "internet-facing"
    "alb.ingress.kubernetes.io/target-type"                  = "ip"
    "alb.ingress.kubernetes.io/listen-ports"                 = "[{\"HTTPS\":443}]"
    "alb.ingress.kubernetes.io/ssl-policy"                   = "ELBSecurityPolicy-TLS13-1-2-2021-06"
    "alb.ingress.kubernetes.io/healthcheck-path"             = "/health"
    "alb.ingress.kubernetes.io/healthcheck-interval-seconds" = "15"
    # The app sleeps 10s before its listener opens, so a new target needs a
    # generous grace period before the ALB gives up on it.
    "alb.ingress.kubernetes.io/success-codes"           = "200"
    "alb.ingress.kubernetes.io/target-group-attributes" = "deregistration_delay.timeout_seconds=30"
    "external-dns.alpha.kubernetes.io/hostname"         = module.route53_acm.origin_fqdn
  }
}

# --- Edge -------------------------------------------------------------------
output "domain_name" {
  description = "Public FQDN clients use."
  value       = var.domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID."
  value       = module.cloudfront_waf.distribution_id
}

output "cloudfront_domain_name" {
  description = "CloudFront's own domain name."
  value       = module.cloudfront_waf.distribution_domain_name
}

output "origin_fqdn" {
  description = "Origin hostname CloudFront connects to. external-dns must publish this for the app's ALB."
  value       = module.route53_acm.origin_fqdn
}

output "cloudfront_web_acl_arn" {
  description = "CLOUDFRONT-scoped Web ACL ARN."
  value       = module.cloudfront_waf.cloudfront_web_acl_arn
}

output "regional_web_acl_arn" {
  description = "REGIONAL Web ACL ARN enforcing origin verification on the ALB."
  value       = module.cloudfront_waf.regional_web_acl_arn
}

output "origin_verify_header_name" {
  description = "Name of the origin verification header. The name is not secret; the value is never output."
  value       = module.cloudfront_waf.origin_verify_header_name
}

# --- Secrets ----------------------------------------------------------------
output "app_secret_arn" {
  description = "ARN of the app's API token secret. Terraform creates the container only -- the VALUE is set out of band, once, by a human."
  value       = module.app_secret.secret_arn
}

output "set_secret_value_command" {
  description = "The out-of-band command that populates the secret. Run once, from a trusted machine. Never put the value in a .tf or .tfvars file."
  value       = "aws secretsmanager put-secret-value --secret-id ${module.app_secret.secret_name} --region ${var.aws_region} --secret-string '<TOKEN>'"
}

# --- Account-global (populated only in the environment that owns them) -------
output "ecr_production_repository_url" {
  description = "Production ECR repository URL. echo-pong-gitops pins <url>@sha256:... here."
  value       = var.manage_account_globals ? module.ecr[0].production_repository_url : null
}

output "ecr_quarantine_repository_url" {
  description = "Quarantine ECR repository URL. echo-pong-workflows pushes here first."
  value       = var.manage_account_globals ? module.ecr[0].quarantine_repository_url : null
}

output "github_actions_role_arns" {
  description = "The five GitHub Actions role ARNs. echo-pong-workflows consumes these as repository variables."
  value       = var.manage_account_globals ? module.iam_github_oidc[0].role_arns : null
}

# --- Argo CD ----------------------------------------------------------------
output "argocd_access_command" {
  description = "How to reach the Argo CD UI. There is no Ingress by design."
  value       = var.enable_argocd ? module.argocd[0].argocd_access_command : null
}

output "argocd_bootstrap_application" {
  description = "Name of the single root Application Terraform created. Everything else in the cluster is Argo CD's."
  value       = var.enable_argocd ? module.argocd[0].bootstrap_application_name : null
}
