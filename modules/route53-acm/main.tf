# =============================================================================
# Route 53 records + the TWO ACM certificates
# =============================================================================
# WHY TWO CERTIFICATES:
#
# The request path is  client --HTTPS--> CloudFront --HTTPS--> ALB --> pod.
# The second hop is a real TLS connection that CloudFront originates, not a
# passthrough, so there are two independent TLS terminations and each needs its
# own certificate:
#
#   1. The VIEWER certificate, on CloudFront, covering domain_name. CloudFront
#      only accepts certificates from us-east-1 -- this is an AWS hard
#      requirement with no workaround, and it is why this module takes an
#      aws.useast1 provider alias. The rest of the stack lives in
#      var.aws_region, whatever the caller set that to.
#
#   2. The ORIGIN certificate, on the ALB, covering origin.domain_name, issued
#      in the REGIONAL provider because an ALB can only use a certificate from
#      its own region. Without it, CloudFront's origin_protocol_policy would
#      have to be http-only and the CloudFront-to-ALB hop would cross the
#      public internet in plaintext, carrying the Authorization header.
#
# A single certificate cannot serve both: they are in different regions and
# attached to different services.
# =============================================================================

locals {
  origin_fqdn = "${var.origin_hostname}.${var.domain_name}"
}

# -----------------------------------------------------------------------------
# 1. Viewer certificate -- us-east-1, for CloudFront
# -----------------------------------------------------------------------------
resource "aws_acm_certificate" "viewer" {
  provider = aws.useast1

  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method         = "DNS"

  tags = merge(var.tags, { Name = "${var.domain_name}-viewer" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "viewer_validation" {
  for_each = {
    for dvo in aws_acm_certificate.viewer.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = var.route53_zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60

  # ACM re-uses the same validation CNAME for a domain across certificate
  # renewals; without this a re-issue collides with the existing record.
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "viewer" {
  provider = aws.useast1

  certificate_arn         = aws_acm_certificate.viewer.arn
  validation_record_fqdns = [for r in aws_route53_record.viewer_validation : r.fqdn]
}

# -----------------------------------------------------------------------------
# 2. Origin certificate -- regional, for the ALB
# -----------------------------------------------------------------------------
resource "aws_acm_certificate" "origin" {
  domain_name       = local.origin_fqdn
  validation_method = "DNS"

  tags = merge(var.tags, { Name = "${local.origin_fqdn}-origin" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "origin_validation" {
  for_each = {
    for dvo in aws_acm_certificate.origin.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "origin" {
  certificate_arn         = aws_acm_certificate.origin.arn
  validation_record_fqdns = [for r in aws_route53_record.origin_validation : r.fqdn]
}

# -----------------------------------------------------------------------------
# What this module deliberately does NOT create
# -----------------------------------------------------------------------------
# 1. THE HOSTED ZONE. It is supplied by the caller as var.route53_zone_id.
#
# 2. THE ALIAS RECORD (<domain> -> CloudFront). This module produces the
#    certificate that the CloudFront distribution needs, so the distribution
#    depends on this module. If this module also consumed the distribution's
#    domain name to build the alias record, the two would form a dependency
#    cycle that Terraform rejects outright. The alias record therefore lives in
#    the root module (envs/*/dns.tf), which is the layer that already sees both
#    sides. This is a real constraint, not a style choice.
#
# 3. THE ORIGIN RECORD (origin.<domain> -> the ALB). That ALB is created by the
#    AWS Load Balancer Controller from the Ingress in echo-pong-gitops, so its
#    DNS name does not exist at terraform-apply time, and Terraform must not
#    own a record pointing at a resource it does not own. echo-pong-gitops sets
#      external-dns.alpha.kubernetes.io/hostname: origin.<domain>
#    on the Ingress and external-dns publishes it. Until that happens
#    CloudFront returns 502, which is the correct and visible failure mode.
#    See docs/architecture.md.
