# =============================================================================
# Secrets Manager -- METADATA ONLY
# =============================================================================
#   ####################################################################
#   #  TERRAFORM CREATES THE CONTAINER. TERRAFORM NEVER SETS THE VALUE. #
#   ####################################################################
#
# There is deliberately NO aws_secretsmanager_secret_version resource here and
# NO secret_string / secret_binary argument anywhere in this module.
#
# Why this is a hard rule and not a preference:
#   - Anything passed to secret_string is written verbatim into the Terraform
#     state file, and is rendered into `terraform plan` output where it lands
#     in CI logs, PR comments and anyone's scrollback.
#   - A value in a .tf file is in Git forever, including in every fork and
#     every developer's reflog, and rotating it does not remove it.
#   - A value in a .tfvars file is one `git add -A` away from the same fate.
#
# HOW THE VALUE ACTUALLY GETS SET (once, out of band, by a human):
#
#   aws secretsmanager put-secret-value \
#     --secret-id echo-pong/prod/api-token \
#     --secret-string file:///dev/stdin <<< "$(read -rs T; echo "$T")"
#
# and after that nothing writes it again. Terraform's lifecycle block below
# ignores the value so a subsequent apply never reverts it, and never even
# reads it into state.
#
# WHO READS IT: External Secrets Operator, and only ESO. It projects the value
# into a native Kubernetes Secret, which echo-pong-gitops mounts as a file, and
# the app loads that file once at startup via SECRET_FILE_PATH. The app pod
# holds no AWS credentials.
# =============================================================================

resource "aws_secretsmanager_secret" "this" {
  name        = var.secret_name
  description = "Bearer token echo-pong compares the Authorization header against. VALUE IS SET OUT OF BAND -- never by Terraform."

  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_in_days

  # Rotation placeholder. Automatic rotation needs a Lambda that knows how to
  # roll the token on both sides, and echo-pong loads its secret ONCE at
  # startup with no reload path -- so rotating the value without restarting
  # every pod would break auth. Rotation is therefore left off deliberately and
  # documented as a future extension gated on the app supporting reload.
  # To enable later, add an aws_secretsmanager_secret_rotation resource; do not
  # set rotation_rules here without solving the reload problem first.

  tags = merge(var.tags, {
    Name         = var.secret_name
    ValueOwner   = "out-of-band-human"
    ManagedValue = "false"
  })

  lifecycle {
    # If someone ever adds a version out of band, Terraform must not care.
    ignore_changes = [
      description,
    ]
  }
}

data "aws_iam_policy_document" "resource_policy" {
  count = length(var.reader_role_arns) > 0 ? 1 : 0

  statement {
    sid       = "AllowExternalSecretsRead"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = var.reader_role_arns
    }
  }

  # Defence in depth against a future over-broad identity policy: nothing may
  # write this secret through the API, regardless of what IAM says. A human
  # setting the value out of band must first remove this statement, which is a
  # deliberate, reviewable act rather than an accident.
  statement {
    sid    = "DenyProgrammaticValueWrites"
    effect = "Deny"
    actions = [
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecret",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    # The break-glass carve-out: a principal explicitly tagged as the secret
    # custodian may still write. Everything automated is denied.
    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalTag/SecretCustodian"
      values   = ["true"]
    }
  }
}

resource "aws_secretsmanager_secret_policy" "this" {
  count = length(var.reader_role_arns) > 0 ? 1 : 0

  secret_arn = aws_secretsmanager_secret.this.arn
  policy     = data.aws_iam_policy_document.resource_policy[0].json
}
