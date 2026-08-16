# =============================================================================
# Primary WAFv2 Web ACL -- scope CLOUDFRONT
# =============================================================================
# CLOUDFRONT-scoped Web ACLs are us-east-1 resources regardless of where the
# rest of the stack lives. Hence aws.useast1, same as the viewer certificate.
#
# Bot Control is deliberately NOT included: it is a paid managed rule group
# with a per-request charge on top of the base WAF cost, and echo-pong's
# clients are machines. Bot Control's value is telling human traffic from
# automated traffic, which is not a distinction this API cares about.
# =============================================================================

locals {
  cf_aliases = length(var.aliases) > 0 ? var.aliases : [var.domain_name]

  managed_rule_groups = [
    {
      name        = "AWSManagedRulesCommonRuleSet"
      vendor      = "AWS"
      priority    = 10
      description = "OWASP-ish baseline: bad UAs, path traversal, oversized bodies, generic injection."
    },
    {
      name        = "AWSManagedRulesKnownBadInputsRuleSet"
      vendor      = "AWS"
      priority    = 20
      description = "Request patterns tied to known CVEs, e.g. Log4Shell JNDI strings."
    },
    {
      name        = "AWSManagedRulesAmazonIpReputationList"
      vendor      = "AWS"
      priority    = 30
      description = "AWS threat-intelligence IP list: bots, recon sources, known-compromised hosts."
    },
  ]
}

resource "aws_wafv2_web_acl" "cloudfront" {
  provider = aws.useast1

  name        = "${var.name_prefix}-cloudfront"
  description = "Edge Web ACL for ${var.domain_name}"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = { for g in local.managed_rule_groups : g.name => g }

    content {
      name     = rule.value.name
      priority = rule.value.priority

      # override_action controls the GROUP:
      #   count {} -- every rule in the group is forced to count, so the group
      #               is observed but never blocks. This is the default.
      #   none {}  -- each rule uses its own configured action, i.e. blocks.
      override_action {
        dynamic "count" {
          for_each = lookup(var.waf_rule_action_override, rule.value.name, "count") == "count" ? [1] : []
          content {}
        }

        dynamic "none" {
          for_each = lookup(var.waf_rule_action_override, rule.value.name, "count") == "block" ? [1] : []
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = rule.value.vendor
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        sampled_requests_enabled   = true
        metric_name                = replace(rule.value.name, "/[^0-9A-Za-z_-]/", "")
      }
    }
  }

  # Rate limiting. Priority 100 so it evaluates after the managed groups: a
  # request that a managed group already blocked should not also consume rate
  # budget attributed to the source IP.
  rule {
    name     = "RateLimitPerIp"
    priority = 100

    action {
      dynamic "block" {
        for_each = var.rate_limit_action == "block" ? [1] : []
        content {
          custom_response {
            response_code = 429
          }
        }
      }

      dynamic "count" {
        for_each = var.rate_limit_action == "count" ? [1] : []
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit = var.rate_limit_per_5min
        # FORWARDED_IP would be wrong here: CloudFront is the only thing in
        # front of this ACL and it sets the true client IP itself, so IP is the
        # honest key. Using the forwarded header would let a client set its own
        # rate-limit bucket via X-Forwarded-For.
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "RateLimitPerIp"
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    sampled_requests_enabled   = true
    metric_name                = replace("${var.name_prefix}-cloudfront", "/[^0-9A-Za-z_-]/", "")
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-cloudfront" })
}
