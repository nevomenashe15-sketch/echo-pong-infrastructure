# -----------------------------------------------------------------------------
# External Secrets Operator
# -----------------------------------------------------------------------------
# ESO is the ONLY principal in this design that reads the app's secret value.
# It reads; it never writes. Terraform creates the secret's metadata (see
# modules/secrets-metadata) but never its value, and the app pod has no AWS
# identity at all -- it just reads the file ESO materialises.
resource "aws_iam_role" "external_secrets" {
  name               = "${var.name_prefix}-external-secrets"
  description        = "EKS Pod Identity role for External Secrets Operator. Read-only on named secrets."
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-external-secrets" })
}

data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid    = "ReadNamedSecretsOnly"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    # Explicit ARN list, not a prefix wildcard. A wildcard like
    # "echo-pong/*" would silently widen every time someone adds a secret.
    resources = var.secret_arns
  }

  # ListSecretVersionIds is how ESO detects rotation. It cannot be scoped to a
  # resource in a way ESO's client honours, but it leaks only version IDs.
  statement {
    sid       = "DetectRotation"
    effect    = "Allow"
    actions   = ["secretsmanager:ListSecretVersionIds"]
    resources = var.secret_arns
  }

  statement {
    sid       = "DecryptSecrets"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [var.secret_kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${local.region}.amazonaws.com"]
    }
  }

  # ESO must never be able to change what it reads.
  statement {
    sid    = "DenyAnySecretMutation"
    effect = "Deny"
    actions = [
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:CreateSecret",
      "secretsmanager:RestoreSecret",
      "secretsmanager:RotateSecret",
      "secretsmanager:PutResourcePolicy",
      "secretsmanager:DeleteResourcePolicy",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "external-secrets"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets.json
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = var.cluster_name
  namespace       = var.external_secrets_namespace
  service_account = var.external_secrets_service_account
  role_arn        = aws_iam_role.external_secrets.arn

  tags = merge(var.tags, { Name = "${var.name_prefix}-external-secrets" })
}
