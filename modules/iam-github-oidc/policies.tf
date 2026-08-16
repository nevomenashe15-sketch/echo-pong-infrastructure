# =============================================================================
# Permission policies for the five GitHub Actions roles
# =============================================================================

locals {
  # Every service this stack actually touches. Used to bound the read-only and
  # mutate policies -- the point is that the list is short and reviewable.
  stack_services = [
    "ec2", "eks", "ecr", "iam", "kms", "route53", "acm",
    "cloudfront", "wafv2", "s3", "secretsmanager", "logs",
    "dynamodb", "elasticloadbalancing", "sts", "autoscaling", "sqs", "ssm",
  ]
}

# -----------------------------------------------------------------------------
# 1. echo-pong-gh-ci-validation -- read-only, no mutation anywhere
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ci_validation" {
  statement {
    sid    = "CallerIdentityOnly"
    effect = "Allow"
    actions = [
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }

  # ECR metadata so a CI job can assert "the digest referenced by the chart
  # exists and its scan came back clean" without being able to push.
  statement {
    sid    = "EcrMetadataRead"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:DescribeRepositories",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
      "ecr:ListImages",
      "ecr:ListTagsForResource",
    ]
    resources = ["*"]
  }
}

# -----------------------------------------------------------------------------
# 2. echo-pong-gh-ecr-release -- quarantine push + digest promotion, nothing else
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ecr_release" {
  # GetAuthorizationToken is registry-wide by design: it takes no resource and
  # AWS rejects any resource other than "*". It only yields a docker login
  # token; what that token can then DO is bounded by the statements below plus
  # the repository policies in modules/ecr.
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PushAndPromoteOnNamedRepositoriesOnly"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
    ]
    resources = var.ecr_repository_arns
  }

  # Explicitly NOT granted anywhere in this role: ecr:DeleteRepository,
  # ecr:BatchDeleteImage, ecr:PutLifecyclePolicy, ecr:SetRepositoryPolicy,
  # ecr:PutImageTagMutability. A release job must never be able to weaken tag
  # immutability or delete the digest it is about to promote over.
}

# -----------------------------------------------------------------------------
# 3. echo-pong-gh-tf-plan -- enough to refresh + plan, provably unable to mutate
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "tf_plan" {
  statement {
    sid    = "ReadOnlyAcrossStackServices"
    effect = "Allow"
    actions = concat(
      [for svc in local.stack_services : "${svc}:Describe*"],
      [for svc in local.stack_services : "${svc}:List*"],
      [for svc in local.stack_services : "${svc}:Get*"],
    )
    resources = ["*"]
  }

  # A few read verbs that do not fit the Describe/List/Get shape.
  statement {
    sid    = "NonstandardReadVerbs"
    effect = "Allow"
    actions = [
      "sts:GetCallerIdentity",
      "iam:SimulatePrincipalPolicy",
      "wafv2:CheckCapacity",
      "tag:GetResources",
      "tag:GetTagKeys",
      "tag:GetTagValues",
    ]
    resources = ["*"]
  }

  # State access: read the state object, and take/release the lock. A plan
  # DOES need to write to DynamoDB -- refusing dynamodb:PutItem here means
  # every plan runs unlocked, which is worse than the tiny write grant.
  statement {
    sid       = "ReadTerraformState"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:ListBucket"]
    resources = [var.state_bucket_arn, "${var.state_bucket_arn}/*"]
  }

  statement {
    sid       = "TakeStateLock"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [var.state_lock_table_arn]
  }

  statement {
    sid       = "DecryptState"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [var.state_kms_key_arn]
  }

  # Belt and braces: even if a Get*/List*/Describe* glob ever expands to
  # something mutating in a future AWS API, these are hard-denied.
  statement {
    sid    = "HardDenyMutation"
    effect = "Deny"
    actions = [
      "iam:Create*", "iam:Delete*", "iam:Put*", "iam:Attach*", "iam:Detach*",
      "iam:Update*", "iam:Add*", "iam:Remove*", "iam:Set*", "iam:Tag*", "iam:Untag*",
      "kms:ScheduleKeyDeletion", "kms:Delete*", "kms:Disable*",
      "s3:PutObject", "s3:DeleteObject", "s3:DeleteBucket",
      "ec2:Create*", "ec2:Delete*", "ec2:Modify*", "ec2:Terminate*", "ec2:Run*",
      "eks:Create*", "eks:Delete*", "eks:Update*", "eks:Associate*",
      "ecr:Put*", "ecr:Delete*", "ecr:Set*", "ecr:Batch*Delete*", "ecr:Upload*", "ecr:Complete*", "ecr:Initiate*",
      "cloudfront:Create*", "cloudfront:Delete*", "cloudfront:Update*",
      "wafv2:Create*", "wafv2:Delete*", "wafv2:Update*", "wafv2:Put*", "wafv2:Associate*",
      "route53:Change*", "route53:Create*", "route53:Delete*",
      "acm:Request*", "acm:Delete*", "acm:Import*",
      "secretsmanager:Create*", "secretsmanager:Delete*", "secretsmanager:Put*", "secretsmanager:Update*",
    ]
    resources = ["*"]

    # ...except writing the state object and the lock item, which the
    # statements above legitimately need.
    condition {
      test     = "ArnNotEquals"
      variable = "aws:ResourceArn"
      values   = [var.state_bucket_arn, "${var.state_bucket_arn}/*", var.state_lock_table_arn]
    }
  }
}

# -----------------------------------------------------------------------------
# 4. echo-pong-gh-tf-apply -- mutate this stack, scoped by service
# -----------------------------------------------------------------------------
# This is the broadest role in the repo and it is still not AdministratorAccess.
# It is bounded three ways:
#   a) by service -- only the services this stack actually uses;
#   b) by an explicit deny on the account-level blast radius (Organizations,
#      account settings, IAM user/root credential surface, CloudTrail);
#   c) by an iam:PassRole condition restricting which services roles may be
#      handed to, so it cannot mint a role and pass it to something arbitrary.
data "aws_iam_policy_document" "tf_apply" {
  statement {
    sid    = "ManageStackServices"
    effect = "Allow"
    actions = [
      "ec2:*", "eks:*", "ecr:*", "kms:*", "route53:*", "acm:*",
      "cloudfront:*", "wafv2:*", "secretsmanager:*", "logs:*",
      "elasticloadbalancing:*", "autoscaling:*", "sqs:*", "ssm:GetParameter*",
      "dynamodb:*", "sts:GetCallerIdentity", "tag:*",
    ]
    resources = ["*"]
  }

  # IAM is granted for resource lifecycle only, and never over the credential
  # surface (users, access keys, login profiles, MFA, the account password
  # policy or SAML/OIDC identity providers other than via the bootstrap role).
  statement {
    sid    = "ManageStackIamResources"
    effect = "Allow"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:ListRoles",
      "iam:UpdateRole", "iam:UpdateRoleDescription", "iam:UpdateAssumeRolePolicy",
      "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies",
      "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy", "iam:ListPolicies",
      "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:GetPolicyVersion", "iam:ListPolicyVersions",
      "iam:TagPolicy", "iam:UntagPolicy",
      "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile", "iam:UntagInstanceProfile", "iam:ListInstanceProfiles",
      "iam:CreateServiceLinkedRole", "iam:ListInstanceProfilesForRole",
      "iam:GetOpenIDConnectProvider", "iam:ListOpenIDConnectProviders",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "PassRoleToStackServicesOnly"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "eks.amazonaws.com",
        "ec2.amazonaws.com",
        "pods.eks.amazonaws.com",
        "vpc-flow-logs.amazonaws.com",
        "delivery.logs.amazonaws.com",
      ]
    }
  }

  statement {
    sid       = "ReadWriteTerraformState"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketVersioning"]
    resources = [var.state_bucket_arn, "${var.state_bucket_arn}/*"]
  }

  statement {
    sid       = "StateLock"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:DescribeTable"]
    resources = [var.state_lock_table_arn]
  }

  statement {
    sid       = "StateKms"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [var.state_kms_key_arn]
  }

  # S3 for the CloudFront access-log bucket and anything else this stack owns.
  statement {
    sid    = "ManageStackBuckets"
    effect = "Allow"
    actions = [
      "s3:CreateBucket", "s3:DeleteBucket", "s3:Get*", "s3:List*", "s3:Put*", "s3:Delete*",
    ]
    resources = ["arn:${local.partition}:s3:::echo-pong-*"]
  }

  statement {
    sid    = "HardDenyAccountBlastRadius"
    effect = "Deny"
    actions = [
      "organizations:*",
      "account:*",
      "iam:CreateUser", "iam:DeleteUser", "iam:CreateAccessKey", "iam:DeleteAccessKey",
      "iam:UpdateAccessKey", "iam:CreateLoginProfile", "iam:UpdateLoginProfile",
      "iam:DeleteLoginProfile", "iam:CreateVirtualMFADevice", "iam:DeactivateMFADevice",
      "iam:UpdateAccountPasswordPolicy", "iam:CreateSAMLProvider", "iam:DeleteSAMLProvider",
      "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail",
      "kms:ScheduleKeyDeletion",
      "guardduty:Delete*", "guardduty:Disassociate*",
      "ec2:DeleteFlowLogs",
      "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutBucketPublicAccessBlock",
    ]
    resources = [
      "*",
    ]
  }

  # The deny above blocks bucket-policy writes account-wide; re-allow them for
  # this stack's own buckets, since Terraform legitimately manages those.
  statement {
    sid    = "AllowBucketPolicyOnOwnBucketsOnly"
    effect = "Allow"
    actions = [
      "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutBucketPublicAccessBlock",
    ]
    resources = ["arn:${local.partition}:s3:::echo-pong-*"]
  }
}

# -----------------------------------------------------------------------------
# 5. echo-pong-gh-bootstrap -- the chicken-and-egg resources only
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "bootstrap" {
  statement {
    sid    = "CreateStateBackend"
    effect = "Allow"
    actions = [
      "s3:CreateBucket", "s3:Put*", "s3:Get*", "s3:List*", "s3:DeleteObject",
      "dynamodb:CreateTable", "dynamodb:DescribeTable", "dynamodb:UpdateTable",
      "dynamodb:TagResource", "dynamodb:ListTagsOfResource", "dynamodb:DescribeContinuousBackups",
      "dynamodb:UpdateContinuousBackups", "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem",
      "kms:CreateKey", "kms:CreateAlias", "kms:DescribeKey", "kms:TagResource",
      "kms:PutKeyPolicy", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus",
      "kms:EnableKeyRotation", "kms:ListAliases", "kms:ListResourceTags",
      "kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey",
    ]
    resources = ["*"]
  }

  # The one place the OIDC provider itself may be created -- which is exactly
  # the resource that must exist before any of these roles are assumable.
  statement {
    sid    = "ManageGithubOidcProvider"
    effect = "Allow"
    actions = [
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviders",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:TagOpenIDConnectProvider",
      "iam:AddClientIDToOpenIDConnectProvider",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "CreateTheFederatedRolesThemselves"
    effect = "Allow"
    actions = [
      "iam:CreateRole", "iam:GetRole", "iam:ListRoles", "iam:TagRole",
      "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:GetRolePolicy",
      "iam:AttachRolePolicy", "iam:ListAttachedRolePolicies", "iam:ListRolePolicies",
      "iam:CreatePolicy", "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions",
      "iam:CreatePolicyVersion", "iam:TagPolicy",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "HardDenyEverythingElseDangerous"
    effect = "Deny"
    actions = [
      "organizations:*", "account:*",
      "iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile",
      "iam:DeleteRole", "iam:DeletePolicy",
      "cloudtrail:StopLogging", "cloudtrail:DeleteTrail",
      "ec2:*", "eks:*", "cloudfront:*", "rds:*",
    ]
    resources = ["*"]
  }
}
