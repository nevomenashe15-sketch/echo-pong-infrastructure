# =============================================================================
# ECR: production + quarantine
# =============================================================================
# DECISION: ONE shared registry pair for the whole estate, not one pair per
# environment. Reasoning:
#
#   The entire point of the quarantine -> production promotion flow is that the
#   artifact which was scanned is bit-identical to the artifact that runs. A
#   digest is only meaningful within one repository path; per-environment
#   repositories would force a re-push (or a cross-repo copy) between dev and
#   prod, at which point "dev tested digest X" and "prod runs digest X" become
#   two different claims about two different objects. With a single registry,
#   dev and prod pull the SAME sha256, and a dev soak test is real evidence
#   about the prod artifact.
#
#   The counter-argument -- blast radius, a compromised dev push poisoning prod
#   -- is handled by IAM instead: only echo-pong-gh-ecr-release can write, and
#   its trust policy is pinned to refs/heads/main and refs/tags/v* of the
#   echo-pong repo. Nothing in dev has push rights at all.
#
#   The alternative (echo-pong-dev / echo-pong-prod) is documented in
#   docs/future-extensions.md as the path to take IF the estate ever splits
#   into separate AWS accounts, where a single registry stops being free.
#
# These repositories are therefore instantiated exactly once, from envs/shared.
# =============================================================================

locals {
  repositories = {
    production = var.production_repository_name
    quarantine = var.quarantine_repository_name
  }
}

resource "aws_ecr_repository" "this" {
  for_each = local.repositories

  name = each.value

  # Immutable tags: a promoted v1.2.3 can never be silently repointed at a
  # different digest. This is the single most important supply-chain control
  # in this module and applies to quarantine too, so a scanned tag cannot be
  # swapped before promotion.
  image_tag_mutability = "IMMUTABLE"

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  image_scanning_configuration {
    # DECISION: basic scan-on-push, not Inspector enhanced scanning.
    # Enhanced scanning is configured at REGISTRY scope
    # (aws_ecr_registry_scanning_configuration), is account-global, and
    # implicitly enables Amazon Inspector for the whole account -- a side
    # effect well outside this repository's ownership boundary and one that
    # bills per-image continuously. Basic scan-on-push is self-contained and
    # gates the promotion step, which is what the pipeline actually needs.
    # Upgrading is a one-resource change, documented in
    # docs/future-extensions.md.
    scan_on_push = true
  }

  force_delete = false

  tags = merge(var.tags, { Name = each.value, ImageRole = each.key })
}

# -----------------------------------------------------------------------------
# Lifecycle: production
# -----------------------------------------------------------------------------
# Rules are evaluated in priority order and an image is matched by the FIRST
# rule that applies, so ordering here is load-bearing.
resource "aws_ecr_lifecycle_policy" "production" {
  repository = aws_ecr_repository.this["production"].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 10
        description  = "Retain the last ${var.production_release_image_count} v* SemVer releases -- this is the rollback horizon."
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = var.production_release_image_count
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 20
        description  = "Retain the last 10 sha-prefixed promotion candidates (non-release rollback candidates)."
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 30
        description  = "Expire untagged manifests after ${var.production_untagged_expiry_days} days."
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.production_untagged_expiry_days
        }
        action = { type = "expire" }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Lifecycle: quarantine
# -----------------------------------------------------------------------------
resource "aws_ecr_lifecycle_policy" "quarantine" {
  repository = aws_ecr_repository.this["quarantine"].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 10
        description  = "Quarantine is a holding area, not storage: expire everything after ${var.quarantine_expiry_days} days regardless of tag state."
        selection = {
          tagStatus   = "any"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.quarantine_expiry_days
        }
        action = { type = "expire" }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Repository policies
# -----------------------------------------------------------------------------
# HONEST NOTE ON WHAT THESE ACTUALLY ENFORCE:
# Within a SINGLE AWS account, ECR authorises a request if EITHER the caller's
# identity policy OR the repository policy allows it -- they are a union, not
# an intersection. So these Allow-only repository policies do NOT stop an
# in-account principal that already has ecr:* from its identity policy.
#
# They are still worth having, for two reasons: they are the binding control
# for any future cross-account access (where the resource policy IS required),
# and they document intent at the resource. The control that actually bounds
# in-account access is the identity policies in modules/iam-github-oidc, where
# the release role is scoped to exactly these two repository ARNs.
#
# If hard enforcement in-account is wanted, add an explicit Deny statement with
# an ArnNotEquals condition on aws:PrincipalArn. That is deliberately NOT done
# here: a Deny on the repository the cluster pulls from is a cluster-wide
# outage the first time a legitimate new principal is added, and the blast
# radius does not justify it for a private registry in a single-tenant account.
data "aws_iam_policy_document" "production" {
  dynamic "statement" {
    for_each = length(var.push_principal_arns) > 0 ? [1] : []

    content {
      sid    = "AllowPromotionPush"
      effect = "Allow"
      actions = [
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:ListImages",
      ]

      principals {
        type        = "AWS"
        identifiers = var.push_principal_arns
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.pull_principal_arns) > 0 ? [1] : []

    content {
      sid    = "AllowClusterPull"
      effect = "Allow"
      actions = [
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
      ]

      principals {
        type        = "AWS"
        identifiers = var.pull_principal_arns
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.read_only_principal_arns) > 0 ? [1] : []

    content {
      sid    = "AllowMetadataRead"
      effect = "Allow"
      actions = [
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:ListImages",
        "ecr:DescribeImageScanFindings",
      ]

      principals {
        type        = "AWS"
        identifiers = var.read_only_principal_arns
      }
    }
  }
}

data "aws_iam_policy_document" "quarantine" {
  dynamic "statement" {
    for_each = length(var.push_principal_arns) > 0 ? [1] : []

    content {
      sid    = "AllowCiPushAndPromotionRead"
      effect = "Allow"
      actions = [
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:DescribeImages",
        "ecr:DescribeImageScanFindings",
        "ecr:DescribeRepositories",
        "ecr:ListImages",
      ]

      principals {
        type        = "AWS"
        identifiers = var.push_principal_arns
      }
    }
  }

  # Deliberately NO pull grant for cluster node roles: nothing unscanned is
  # ever allowed to run. If a node role could pull from quarantine, the
  # promotion gate would be advisory rather than enforced.
  dynamic "statement" {
    for_each = length(var.read_only_principal_arns) > 0 ? [1] : []

    content {
      sid    = "AllowMetadataRead"
      effect = "Allow"
      actions = [
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:ListImages",
        "ecr:DescribeImageScanFindings",
      ]

      principals {
        type        = "AWS"
        identifiers = var.read_only_principal_arns
      }
    }
  }
}

resource "aws_ecr_repository_policy" "production" {
  count = length(var.push_principal_arns) + length(var.pull_principal_arns) + length(var.read_only_principal_arns) > 0 ? 1 : 0

  repository = aws_ecr_repository.this["production"].name
  policy     = data.aws_iam_policy_document.production.json
}

resource "aws_ecr_repository_policy" "quarantine" {
  count = length(var.push_principal_arns) + length(var.read_only_principal_arns) > 0 ? 1 : 0

  repository = aws_ecr_repository.this["quarantine"].name
  policy     = data.aws_iam_policy_document.quarantine.json
}
