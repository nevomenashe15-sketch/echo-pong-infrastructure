# -----------------------------------------------------------------------------
# Karpenter controller
# -----------------------------------------------------------------------------
# IAM PREREQUISITES ONLY. This repository gives Karpenter an identity and the
# permission to launch instances. It does NOT declare what Karpenter may
# launch -- the NodePool (instance families, arch, limits, disruption budget)
# and the EC2NodeClass (AMI, subnets, security groups, instance profile) are
# Kubernetes objects living in echo-pong-gitops, applied by Argo CD.
#
# The boundary is deliberate: capacity policy changes weekly, IAM does not.
resource "aws_iam_role" "karpenter_controller" {
  name               = "${var.name_prefix}-karpenter-controller"
  description        = "EKS Pod Identity role for the Karpenter controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-karpenter-controller" })
}

data "aws_iam_policy_document" "karpenter_controller" {
  statement {
    sid    = "Discovery"
    effect = "Allow"
    actions = [
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
      "ec2:DescribeAvailabilityZones",
      "pricing:GetProducts",
      "ssm:GetParameter",
      "eks:DescribeCluster",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "LaunchCapacity"
    effect = "Allow"
    actions = [
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
      "ec2:RunInstances",
    ]
    resources = ["*"]

    # Karpenter may only launch into resources tagged for THIS cluster. The
    # tag is applied by modules/vpc (subnets) and modules/eks (security group).
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
  }

  # RunInstances also reads the subnet/SG/image/launch-template resources, which
  # the tag condition above cannot cover (they carry the discovery tag, not the
  # request tag). Split out so the mutating verbs stay tag-conditioned.
  statement {
    sid     = "ReadResourcesForRunInstances"
    effect  = "Allow"
    actions = ["ec2:RunInstances", "ec2:CreateFleet"]
    resources = [
      "arn:${local.partition}:ec2:${local.region}::image/*",
      "arn:${local.partition}:ec2:${local.region}::snapshot/*",
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:security-group/*",
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:subnet/*",
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:launch-template/*",
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:capacity-reservation/*",
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:spot-instances-request/*",
    ]
  }

  statement {
    sid       = "TagOnCreate"
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
    }
  }

  statement {
    sid       = "TerminateOwnInstancesOnly"
    effect    = "Allow"
    actions   = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"]
    resources = ["*"]

    # Only nodes Karpenter itself provisioned. Without this condition the
    # controller could terminate the system node group and deadlock the
    # cluster, because Karpenter cannot reschedule the Karpenter pod.
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
  }

  # Karpenter attaches the node instance profile to instances it launches.
  # Scoped to exactly one role: it cannot escalate by passing a more privileged
  # role to an instance it controls.
  statement {
    sid       = "PassNodeRoleOnly"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [var.karpenter_node_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  statement {
    sid    = "ManageInstanceProfiles"
    effect = "Allow"
    actions = [
      "iam:GetInstanceProfile",
      "iam:CreateInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:DeleteInstanceProfile",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/*"]
  }

  # Spot interruption / rebalance / health events. Without this Karpenter finds
  # out a spot node is gone when the kubelet stops reporting, ~2 minutes after
  # it could have started draining.
  dynamic "statement" {
    for_each = var.karpenter_interruption_queue_arn != "" ? [1] : []

    content {
      sid    = "InterruptionQueue"
      effect = "Allow"
      actions = [
        "sqs:DeleteMessage",
        "sqs:GetQueueUrl",
        "sqs:ReceiveMessage",
        "sqs:GetQueueAttributes",
      ]
      resources = [var.karpenter_interruption_queue_arn]
    }
  }
}

resource "aws_iam_role_policy" "karpenter_controller" {
  name   = "karpenter-controller"
  role   = aws_iam_role.karpenter_controller.id
  policy = data.aws_iam_policy_document.karpenter_controller.json
}

resource "aws_eks_pod_identity_association" "karpenter_controller" {
  cluster_name    = var.cluster_name
  namespace       = var.karpenter_namespace
  service_account = var.karpenter_service_account
  role_arn        = aws_iam_role.karpenter_controller.arn

  tags = merge(var.tags, { Name = "${var.name_prefix}-karpenter-controller" })
}
