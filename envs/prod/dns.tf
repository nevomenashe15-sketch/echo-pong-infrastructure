# =============================================================================
# The public alias record
# =============================================================================
# This lives in the root module rather than in modules/route53-acm because of a
# hard dependency-ordering constraint, not style:
#
#   modules/cloudfront-waf  needs  the viewer certificate  from modules/route53-acm
#   the alias record        needs  the distribution domain from modules/cloudfront-waf
#
# Putting the alias record inside modules/route53-acm would make the two
# modules mutually dependent, and Terraform rejects module-level cycles
# outright. The root module already sees both sides, so it is the correct
# place for the record that joins them.
# =============================================================================

resource "aws_route53_record" "apex_a" {
  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name    = module.cloudfront_waf.distribution_domain_name
    zone_id = module.cloudfront_waf.distribution_hosted_zone_id
    # false: CloudFront distributions do not report health to Route 53, and
    # setting this to true on a CloudFront alias makes the record fail closed
    # for reasons unrelated to actual origin health.
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "apex_aaaa" {
  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "AAAA"

  alias {
    name                   = module.cloudfront_waf.distribution_domain_name
    zone_id                = module.cloudfront_waf.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

# NOT created here: origin.<domain> -> the app's ALB. That ALB is owned by the
# AWS Load Balancer Controller, created from the Ingress in echo-pong-gitops.
# external-dns publishes the record from the Ingress annotation. Terraform must
# not own a record pointing at a resource it does not own.
