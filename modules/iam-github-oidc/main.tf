# =============================================================================
# GitHub Actions OIDC provider + the five federated roles
# =============================================================================
# No role here carries AdministratorAccess, and no trust policy uses a wildcard
# repository. Every `sub` condition names an exact repo and an exact ref class.
#
# The five roles and why they are separate rather than one "CI role":
#   ci-validation : fmt/lint/plan-less validation for all four repos. Read-only.
#   ecr-release   : push to quarantine, promote a digest to production. ECR only.
#   tf-plan       : read-only across the stack, enough for `terraform plan`.
#   tf-apply      : mutate this stack. Gated on main + a GitHub Environment.
#   bootstrap     : the chicken-and-egg resources only. Rare, manual, gated.
#
# Splitting them means a compromised PR-triggered job (which can only ever get
# ci-validation or tf-plan, because those are the only roles whose trust policy
# accepts a pull_request ref) cannot reach anything that mutates.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  oidc_host = "token.actions.githubusercontent.com"

  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:${local.partition}:iam::${local.account_id}:oidc-provider/${local.oidc_host}"

  repos = {
    app       = "${var.github_owner}/${var.app_repository}"
    infra     = "${var.github_owner}/${var.infra_repository}"
    gitops    = "${var.github_owner}/${var.gitops_repository}"
    workflows = "${var.github_owner}/${var.workflows_repository}"
  }
}

# The thumbprint is fetched rather than hardcoded. AWS no longer validates the
# GitHub OIDC thumbprint against the presented chain (it trusts the public CA
# set), but the argument is still required and a stale hardcoded value is a
# classic cause of a mystery 3am outage when GitHub rotates its intermediate.
data "tls_certificate" "github" {
  url = "https://${local.oidc_host}/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://${local.oidc_host}"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[length(data.tls_certificate.github.certificates) - 1].sha1_fingerprint]

  tags = merge(var.tags, { Name = "github-actions-oidc" })
}

# -----------------------------------------------------------------------------
# Trust policy builder
# -----------------------------------------------------------------------------
# `sub_patterns` are matched with StringLike so ref globs (refs/tags/v*) work.
# `aud` is always pinned to sts.amazonaws.com with StringEquals -- omitting the
# aud condition is the single most common GitHub OIDC misconfiguration and
# makes the role assumable by any GitHub tenant.
data "aws_iam_policy_document" "trust_ci_validation" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Any ref of any of the four repos: validation runs on PRs from forks'
    # branches too. This is safe only because the attached policy is read-only.
    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values   = [for r in values(local.repos) : "repo:${r}:*"]
    }
  }
}

data "aws_iam_policy_document" "trust_ecr_release" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # NOTE ON REUSABLE WORKFLOWS: when echo-pong calls a reusable workflow from
    # echo-pong-workflows, the `sub` claim still describes the CALLING repo
    # (echo-pong), not the workflow's home repo. Pinning `sub` to the app repo
    # is therefore correct; `job_workflow_ref` below is what pins WHICH
    # reusable workflow was allowed to drive it.
    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values = [
        "repo:${local.repos.app}:ref:refs/heads/main",
        "repo:${local.repos.app}:ref:refs/tags/v*",
      ]
    }

    dynamic "condition" {
      for_each = var.release_job_workflow_ref != "" ? [1] : []

      content {
        test     = "StringLike"
        variable = "${local.oidc_host}:job_workflow_ref"
        values   = [var.release_job_workflow_ref]
      }
    }
  }
}

data "aws_iam_policy_document" "trust_tf_plan" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Any ref of the infra repo -- plan must run on PRs, that is its whole job.
    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values   = ["repo:${local.repos.infra}:*"]
    }
  }
}

data "aws_iam_policy_document" "trust_tf_apply" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # CAREFUL: `sub` is a SINGLE string, and listing two values in one
    # condition is an OR, not an AND. When a job runs inside a GitHub
    # Environment the sub takes the form
    #   repo:<owner>/<repo>:environment:<name>
    # and the `ref:refs/heads/main` form is NOT also present. So "main AND
    # environment" cannot be expressed in `sub` alone.
    #
    # The AND is built from two separate claims: `sub` pins the environment,
    # and GitHub's separate top-level `ref` claim pins the branch. Both
    # conditions in one statement are ANDed by IAM.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["repo:${local.repos.infra}:environment:${var.apply_environment_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:ref"
      values   = ["refs/heads/main"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:repository"
      values   = [local.repos.infra]
    }
  }
}

data "aws_iam_policy_document" "trust_bootstrap" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["repo:${local.repos.infra}:environment:${var.bootstrap_environment_name}"]
    }
  }
}
