# =============================================================================
# Terraform state backend bootstrap
# =============================================================================
# This root module is applied ONCE, by hand or by the echo-pong-gh-bootstrap
# role, before any other root module can `terraform init`.
#
# It has no backend of its own (see versions.tf). See bootstrap/README.md for
# how its own state is handled.
# =============================================================================

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  # Mirrors the common_tags shape used by the sibling echo-ai-pipeline-infra
  # repo so tagging stays uniform across the estate.
  common_tags = merge({
    Environment = "shared"
    ManagedBy   = "terraform"
    Project     = "echo-pong"
  }, var.tags)
}

# -----------------------------------------------------------------------------
# KMS CMK for state-at-rest
# -----------------------------------------------------------------------------
# A CMK rather than SSE-S3: Terraform state contains resolved secret material
# (see docs/architecture.md, "Secrets in state"). A CMK gives per-key rotation
# and an auditable CloudTrail record of every decrypt, which the AWS-managed
# S3 key does not.
resource "aws_kms_key" "state" {
  description             = "Encrypts the echo-pong Terraform state bucket"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = local.common_tags
}

resource "aws_kms_alias" "state" {
  name          = "alias/echo-pong-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

# -----------------------------------------------------------------------------
# State bucket
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name
  tags   = local.common_tags

  # Deliberate: destroying the state bucket is never a routine operation.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Access logs for the state bucket. Reading state is a high-signal audit event.
resource "aws_s3_bucket" "state_logs" {
  bucket = "${var.state_bucket_name}-logs"
  tags   = local.common_tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "state_logs" {
  bucket = aws_s3_bucket.state_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state_logs" {
  bucket = aws_s3_bucket.state_logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "state_logs" {
  bucket = aws_s3_bucket.state_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 (not the CMK) on the log bucket: S3 server access logging cannot write
# to a bucket encrypted with a CMK unless the delivery principal is granted
# kms:GenerateDataKey, and that grant is broader than the log data warrants.
resource "aws_s3_bucket_server_side_encryption_configuration" "state_logs" {
  bucket = aws_s3_bucket.state_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state_logs" {
  bucket = aws_s3_bucket.state_logs.id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_logging" "state" {
  bucket        = aws_s3_bucket.state.id
  target_bucket = aws_s3_bucket.state_logs.id
  target_prefix = "s3-access/state/"
}

data "aws_iam_policy_document" "state_logs" {
  statement {
    sid       = "AllowS3ServerAccessLogDelivery"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state_logs.arn}/s3-access/*"]

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.state.arn]
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
    resources = [aws_s3_bucket.state_logs.arn, "${aws_s3_bucket.state_logs.arn}/*"]

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

resource "aws_s3_bucket_policy" "state_logs" {
  bucket = aws_s3_bucket.state_logs.id
  policy = data.aws_iam_policy_document.state_logs.json
}

# -----------------------------------------------------------------------------
# Least-privilege bucket policy on the state bucket
# -----------------------------------------------------------------------------
# The policy is additive to IAM: it hard-denies plaintext transport and any
# write that is not encrypted with our CMK, and -- once the principal lists are
# populated -- denies every principal that is not on the allow list.
data "aws_iam_policy_document" "state" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

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

  statement {
    sid       = "DenyWrongKmsKey"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [aws_kms_key.state.arn]
    }
  }

  # Only rendered once the caller supplies at least one role ARN, in EITHER
  # list. Applying this statement with both lists empty would lock everyone
  # out, so it is guarded -- but the guard must cover both lists: the
  # ArnNotEquals condition below allow-lists both state_writer_principal_arns
  # AND state_reader_principal_arns, so gating on only the writer list meant
  # populating readers alone (a plausible partial rollout -- read access
  # before write access) silently skipped rendering this statement entirely,
  # leaving the bucket with no principal restriction at all despite
  # terraform.tfvars looking correctly configured.
  dynamic "statement" {
    for_each = (length(var.state_writer_principal_arns) > 0 || length(var.state_reader_principal_arns) > 0) ? [1] : []

    content {
      sid       = "DenyNonApprovedPrincipals"
      effect    = "Deny"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

      principals {
        type        = "AWS"
        identifiers = ["*"]
      }

      condition {
        test     = "ArnNotEquals"
        variable = "aws:PrincipalArn"
        values = concat(
          var.state_writer_principal_arns,
          var.state_reader_principal_arns,
          ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"],
        )
      }
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json
}

# -----------------------------------------------------------------------------
# State locking: DynamoDB
# -----------------------------------------------------------------------------
# DECISION: DynamoDB, not S3 native locking (`use_lockfile`).
# `use_lockfile` requires Terraform >= 1.10. The toolchain this repo is
# validated against is Terraform 1.9.8, so native locking is simply not
# available. The migration is a two-line backend change (drop `dynamodb_table`,
# add `use_lockfile = true`) once every consumer -- local dev, CI runners, and
# Atlantis/whatever runs apply -- is on >= 1.10. Keeping DynamoDB until then
# avoids a split where some clients lock via S3 and some via DynamoDB, which
# silently provides NO mutual exclusion at all.
resource "aws_dynamodb_table" "locks" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.state.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  deletion_protection_enabled = true

  tags = local.common_tags
}
