# =============================================================================
# Regional WAFv2 Web ACL -- scope REGIONAL, attached to the app's ALB
# =============================================================================
# One job: enforce that a request arrived via CloudFront.
#
# It is created in the REGIONAL provider (the stack's own region) because a
# REGIONAL Web ACL must live in the same region as the ALB it protects.
#
# IT IS NOT ASSOCIATED HERE. There is no aws_wafv2_web_acl_association resource
# in this module, because the ALB does not exist at terraform-apply time -- the
# AWS Load Balancer Controller creates it from the Ingress in echo-pong-gitops.
# The association is made by the controller, from the Ingress annotation:
#
#   alb.ingress.kubernetes.io/wafv2-acl-arn: <regional_web_acl_arn output>
#
# Terraform creating the association would mean Terraform holding a reference
# to an ALB it does not own -- the exact single-owner violation this design
# avoids everywhere else.
# =============================================================================

resource "aws_wafv2_web_acl" "regional" {
  name        = "${var.name_prefix}-alb-origin-verify"
  description = "Blocks any request to the ALB that did not come through CloudFront."
  scope       = "REGIONAL"

  # DEFAULT DENY. This is the correct default for an origin that should only
  # ever be reached by one client. It also means that if the rule below is ever
  # accidentally deleted, the failure is a hard outage rather than a silent
  # loss of protection.
  default_action {
    block {
      custom_response {
        response_code = 403
      }
    }
  }

  rule {
    name     = "AllowCloudFrontOnly"
    priority = 10

    action {
      allow {}
    }

    statement {
      byte_match_statement {
        # EXACTLY matches the full header value. A "contains" match would be
        # satisfiable by an attacker who learned only a prefix.
        positional_constraint = "EXACTLY"
        search_string         = random_password.origin_verify.result

        field_to_match {
          single_header {
            # WAFv2 lowercases header names for matching.
            name = local.origin_verify_header
          }
        }

        # No transformation: the value is compared as raw bytes. Applying
        # LOWERCASE or similar would collapse the entropy of a mixed-case
        # secret and make an offline guess cheaper.
        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = false # a sampled request would surface the header value in the console
      metric_name                = "AllowCloudFrontOnly"
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    sampled_requests_enabled   = false
    metric_name                = replace("${var.name_prefix}-alb-origin-verify", "/[^0-9A-Za-z_-]/", "")
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb-origin-verify" })
}
