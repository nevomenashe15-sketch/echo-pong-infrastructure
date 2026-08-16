# =============================================================================
# CloudFront access logging
# =============================================================================
# ON THE Authorization HEADER IN LOGS -- verified, not assumed:
#
# CloudFront standard access logs emit a FIXED field set. The full list is
# documented at
# https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/AccessLogs.html
# and it contains no facility for logging arbitrary request headers: the only
# header-derived fields are cs(Host), cs(Referer), cs(User-Agent),
# cs(Cookie) and the cs-protocol/ssl fields. There is no cs(Authorization)
# field and no way to add one. Real-time logs use the same fixed field set.
#
# So the Authorization header is not logged, and the correct statement is "the
# log format has no field that can carry it", NOT "we configured it off" --
# there is no switch to configure. The `fields` list below is the explicit
# allow-list we opt into, which makes that visible to a reviewer instead of
# implicit.
#
# The one place credentials COULD leak is cs-uri-query, if a client ever put a
# token in a query string. echo-pong only reads Authorization, so that is a
# client-side mistake rather than a design flaw here, but it is the thing to
# grep for if this log bucket is ever shared more widely.
#
# Cookie logging is switched off below (the cookie field is omitted): the app
# uses no cookies, so anything appearing there would be noise or a leak.
# =============================================================================

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "logs" {
  bucket = var.log_bucket_name
  tags   = merge(var.tags, { Name = var.log_bucket_name })
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# BucketOwnerEnforced disables ACLs entirely. This is possible only because we
# use CloudFront standard logging v2 (the CloudWatch Logs delivery path below),
# which writes via a service principal and a bucket policy. The LEGACY
# CloudFront logging_config on aws_cloudfront_distribution requires ACLs and
# the awslogsdelivery canonical grantee, and therefore forces ObjectWriter
# ownership -- one of the concrete reasons v2 is used here.
resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3, not a CMK: the log delivery service would need kms:GenerateDataKey on
# the CMK, and granting a broadly-scoped AWS service principal use of a key
# that also protects the app secret is a worse trade than SSE-S3 on access logs
# that contain no credentials (see the header discussion above).
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = var.log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "logs" {
  statement {
    sid       = "AllowLogDeliveryWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/*"]

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

  statement {
    sid       = "AllowLogDeliveryAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = [aws_s3_bucket.logs.arn]

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

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.logs.arn, "${aws_s3_bucket.logs.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs.json
}

# -----------------------------------------------------------------------------
# Standard logging v2 via CloudWatch Logs delivery
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_delivery_source" "cloudfront" {
  provider = aws.useast1

  name         = "${var.name_prefix}-cf-access-logs"
  log_type     = "ACCESS_LOGS"
  resource_arn = aws_cloudfront_distribution.this.arn

  tags = var.tags
}

resource "aws_cloudwatch_log_delivery_destination" "cloudfront" {
  provider = aws.useast1

  name          = "${var.name_prefix}-cf-access-logs-s3"
  output_format = "parquet"

  delivery_destination_configuration {
    destination_resource_arn = aws_s3_bucket.logs.arn
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_delivery" "cloudfront" {
  provider = aws.useast1

  delivery_source_name     = aws_cloudwatch_log_delivery_source.cloudfront.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.cloudfront.arn

  s3_delivery_configuration {
    suffix_path                 = "/{DistributionId}/{yyyy}/{MM}/{dd}/{HH}"
    enable_hive_compatible_path = true
  }

  # Explicit allow-list of fields. See the header discussion at the top of this
  # file: there is no Authorization field available, and cs(Cookie) is
  # deliberately omitted.
  record_fields = [
    "date",
    "time",
    "x-edge-location",
    "sc-bytes",
    "c-ip",
    "cs-method",
    "cs-uri-stem",
    "sc-status",
    "cs(Referer)",
    "cs(User-Agent)",
    "cs-uri-query",
    "x-edge-result-type",
    "x-edge-request-id",
    "x-host-header",
    "cs-protocol",
    "cs-bytes",
    "time-taken",
    "ssl-protocol",
    "ssl-cipher",
    "x-edge-response-result-type",
    "cs-protocol-version",
    "c-country",
    "time-to-first-byte",
    "x-edge-detailed-result-type",
    "sc-content-type",
    "sc-range-start",
    "sc-range-end",
  ]

  tags = var.tags
}
