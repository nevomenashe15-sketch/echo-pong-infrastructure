# =============================================================================
# WAF logging -- with mandatory header redaction
# =============================================================================
# THIS IS NOT THE SAME AS CLOUDFRONT ACCESS LOGGING, AND THE DIFFERENCE MATTERS.
#
# CloudFront standard access logs have a fixed field set with no facility for
# arbitrary request headers, so Authorization cannot appear in them (see
# logging.tf). WAF logs are the opposite: a WAF log record contains the
# REQUEST HEADERS BY DEFAULT, because the whole point is to show you what the
# rule matched on.
#
# So for WAF -- and only for WAF -- redaction is a real, required control
# rather than a property we get for free:
#
#   - Authorization: the bearer token echo-pong authenticates with. Logging it
#     would put live credentials in CloudWatch for every /ping and /pong
#     request, readable by anyone with logs:GetLogEvents.
#   - x-echo-pong-origin-verify: the CloudFront->ALB shared secret. Logging it
#     in the REGIONAL ACL would defeat the entire origin-verification control,
#     since the value is exactly what an attacker needs to bypass CloudFront.
#
# Both are redacted below. WAF replaces the value with "REDACTED" while still
# recording that the header was present, which is all the tuning workflow needs.
#
# Logging exists at all because the count-mode rollout documented in
# variables.tf is not actionable without it: "run in count, read the sampled
# requests, then promote to block" requires a queryable record of what WOULD
# have been blocked.
# =============================================================================

# AWS requires WAF log destinations to be named with an aws-waf-logs- prefix.
# This is a hard service constraint, not a convention.
resource "aws_cloudwatch_log_group" "waf_cloudfront" {
  provider = aws.useast1

  name              = "aws-waf-logs-${var.name_prefix}-cloudfront"
  retention_in_days = var.waf_log_retention_days

  tags = merge(var.tags, { Name = "aws-waf-logs-${var.name_prefix}-cloudfront" })
}

resource "aws_cloudwatch_log_group" "waf_regional" {
  name              = "aws-waf-logs-${var.name_prefix}-regional"
  retention_in_days = var.waf_log_retention_days

  tags = merge(var.tags, { Name = "aws-waf-logs-${var.name_prefix}-regional" })
}

data "aws_iam_policy_document" "waf_log_delivery" {
  statement {
    sid    = "AWSLogDeliveryWrite"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "${aws_cloudwatch_log_group.waf_cloudfront.arn}:*",
      "${aws_cloudwatch_log_group.waf_regional.arn}:*",
    ]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "waf_cloudfront" {
  provider = aws.useast1

  # Distinct name (not just "-waf-log-delivery" shared with waf_regional
  # below): CloudWatch Logs resource policies are scoped per account+region,
  # not per log group, so if var.aws_region were ever us-east-1 (this stack
  # already forces several other resources there), an identical name would
  # collide -- two Terraform-managed resources representing one AWS object.
  policy_name     = "${var.name_prefix}-waf-log-delivery-cloudfront"
  policy_document = data.aws_iam_policy_document.waf_log_delivery.json
}

resource "aws_cloudwatch_log_resource_policy" "waf_regional" {
  policy_name     = "${var.name_prefix}-waf-log-delivery-regional"
  policy_document = data.aws_iam_policy_document.waf_log_delivery.json
}

resource "aws_wafv2_web_acl_logging_configuration" "cloudfront" {
  provider = aws.useast1

  resource_arn            = aws_wafv2_web_acl.cloudfront.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf_cloudfront.arn]

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = local.origin_verify_header
    }
  }

  # Only log requests a rule actually acted on. Logging every ALLOW would be
  # the full request volume at WAF-log prices for no additional signal -- the
  # CloudFront access log already records every request.
  logging_filter {
    default_behavior = "DROP"

    filter {
      behavior    = "KEEP"
      requirement = "MEETS_ANY"

      condition {
        action_condition {
          action = "BLOCK"
        }
      }

      # COUNT is the important one while the managed groups are in count mode:
      # these are the requests that WOULD be blocked after promotion.
      condition {
        action_condition {
          action = "COUNT"
        }
      }
    }
  }

  depends_on = [aws_cloudwatch_log_resource_policy.waf_cloudfront]
}

resource "aws_wafv2_web_acl_logging_configuration" "regional" {
  resource_arn            = aws_wafv2_web_acl.regional.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf_regional.arn]

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  # Non-negotiable: without this, every blocked request logs the exact header
  # value an attacker needs to bypass CloudFront entirely.
  redacted_fields {
    single_header {
      name = local.origin_verify_header
    }
  }

  # On the regional ACL the default action is BLOCK, so a BLOCK log line means
  # "something reached the ALB directly" -- the single highest-signal event
  # this whole stack produces. Keep all of them.
  logging_filter {
    default_behavior = "DROP"

    filter {
      behavior    = "KEEP"
      requirement = "MEETS_ANY"

      condition {
        action_condition {
          action = "BLOCK"
        }
      }
    }
  }

  depends_on = [aws_cloudwatch_log_resource_policy.waf_regional]
}
