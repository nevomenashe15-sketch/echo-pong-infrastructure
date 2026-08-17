output "distribution_id" {
  description = "CloudFront distribution ID."
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_arn" {
  description = "CloudFront distribution ARN."
  value       = aws_cloudfront_distribution.this.arn
}

output "distribution_domain_name" {
  description = "dxxxx.cloudfront.net name. Consumed directly by the root module's dns.tf (aws_route53_record.apex_a/apex_aaaa) to create the alias record -- NOT fed back into modules/route53-acm, which has no input for it. Keeping the alias record in the root module (not inside either module/route53-acm or module/cloudfront-waf) is what avoids a module-level cycle: route53-acm's cert is needed by cloudfront-waf, and cloudfront-waf's domain name is needed for the alias, so neither module can own the record without depending on the other."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "distribution_hosted_zone_id" {
  description = "Hosted zone ID for CloudFront alias records."
  value       = aws_cloudfront_distribution.this.hosted_zone_id
}

output "cloudfront_web_acl_arn" {
  description = "ARN of the CLOUDFRONT-scoped Web ACL."
  value       = aws_wafv2_web_acl.cloudfront.arn
}

output "regional_web_acl_arn" {
  description = "ARN of the REGIONAL Web ACL enforcing origin verification. echo-pong-gitops MUST set this on the app Ingress as alb.ingress.kubernetes.io/wafv2-acl-arn -- without it the ALB is reachable directly and the whole edge is bypassable."
  value       = aws_wafv2_web_acl.regional.arn
}

output "origin_verify_header_name" {
  description = "Name of the origin verification header. The NAME is not secret; the value is."
  value       = local.origin_verify_header
}

output "origin_verify_secret_arn" {
  description = "Secrets Manager ARN holding the reference copy of the origin verification value, for rotation tracking and incident response."
  value       = aws_secretsmanager_secret.origin_verify.arn
}

output "log_bucket_name" {
  description = "Bucket receiving CloudFront access logs."
  value       = aws_s3_bucket.logs.id
}

# There is deliberately NO output for random_password.origin_verify.result.
# Marking it sensitive would keep it out of the console but it would still be
# in the state of every consumer of this module and in any `terraform output
# -json`. Nothing outside this module needs it: the CloudFront custom header
# and the WAF byte-match rule both reference the resource directly.
