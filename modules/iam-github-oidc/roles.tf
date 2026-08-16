locals {
  roles = {
    "echo-pong-gh-ci-validation" = {
      trust       = data.aws_iam_policy_document.trust_ci_validation.json
      policy      = data.aws_iam_policy_document.ci_validation.json
      description = "GitHub Actions: read-only CI validation across all four echo-pong repositories. No deploy permissions."
    }
    "echo-pong-gh-ecr-release" = {
      trust       = data.aws_iam_policy_document.trust_ecr_release.json
      policy      = data.aws_iam_policy_document.ecr_release.json
      description = "GitHub Actions: push to echo-pong-quarantine and promote a digest into echo-pong. ECR only."
    }
    "echo-pong-gh-tf-plan" = {
      trust       = data.aws_iam_policy_document.trust_tf_plan.json
      policy      = data.aws_iam_policy_document.tf_plan.json
      description = "GitHub Actions: read-only, sufficient for terraform plan on echo-pong-infrastructure."
    }
    "echo-pong-gh-tf-apply" = {
      trust       = data.aws_iam_policy_document.trust_tf_apply.json
      policy      = data.aws_iam_policy_document.tf_apply.json
      description = "GitHub Actions: terraform apply for echo-pong-infrastructure. Gated on main + a protected GitHub Environment."
    }
    "echo-pong-gh-bootstrap" = {
      trust       = data.aws_iam_policy_document.trust_bootstrap.json
      policy      = data.aws_iam_policy_document.bootstrap.json
      description = "GitHub Actions: rare one-time bootstrap of the state backend and the OIDC provider itself."
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = local.roles

  name                 = each.key
  description          = each.value.description
  assume_role_policy   = each.value.trust
  max_session_duration = var.max_session_duration

  # No permissions boundary is set. A boundary would be the right control in a
  # multi-team account; here the roles are the only federated principals and
  # each already carries an explicit Deny for the account blast radius, so a
  # boundary would duplicate that with a second place to keep in sync.

  tags = merge(var.tags, { Name = each.key })
}

resource "aws_iam_policy" "this" {
  for_each = local.roles

  name        = "${each.key}-policy"
  description = each.value.description
  policy      = each.value.policy

  tags = merge(var.tags, { Name = "${each.key}-policy" })
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each = local.roles

  role       = aws_iam_role.this[each.key].name
  policy_arn = aws_iam_policy.this[each.key].arn
}
