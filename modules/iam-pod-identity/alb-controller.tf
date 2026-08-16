# -----------------------------------------------------------------------------
# AWS Load Balancer Controller
# -----------------------------------------------------------------------------
# This role is the ONLY thing this repository contributes to the app's ALB.
# Terraform does not create an aws_lb, an aws_lb_listener, an aws_lb_target_group
# or an Ingress. The controller creates and owns all of them, driven by the
# Ingress object in echo-pong-gitops. Creating an aws_lb here would give two
# systems write access to one resource and guarantee reconciliation fights.
resource "aws_iam_role" "alb_controller" {
  name               = "${var.name_prefix}-alb-controller"
  description        = "EKS Pod Identity role for the AWS Load Balancer Controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-alb-controller" })
}

data "aws_iam_policy_document" "alb_controller" {
  # Read-only discovery. These APIs take no meaningful resource ARN.
  statement {
    sid    = "Discovery"
    effect = "Allow"
    actions = [
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeAddresses",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeVpcs",
      "ec2:DescribeVpcPeeringConnections",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeTags",
      "ec2:GetCoipPoolUsage",
      "ec2:DescribeCoipPools",
      "ec2:GetSecurityGroupsForVpc",
      "ec2:DescribeIpamPools",
      "ec2:DescribeRouteTables",
      "elasticloadbalancing:Describe*",
      "acm:ListCertificates",
      "acm:DescribeCertificate",
      "iam:ListServerCertificates",
      "iam:GetServerCertificate",
      "cognito-idp:DescribeUserPoolClient",
      "waf-regional:GetWebACL",
      "waf-regional:GetWebACLForResource",
      "wafv2:GetWebACL",
      "wafv2:GetWebACLForResource",
      "shield:GetSubscriptionState",
      "shield:DescribeProtection",
    ]
    resources = ["*"]
  }

  # The controller must be able to associate the REGIONAL Web ACL (the
  # origin-verification one from modules/cloudfront-waf) with the ALB it
  # creates, via the alb.ingress.kubernetes.io/wafv2-acl-arn annotation set in
  # echo-pong-gitops.
  statement {
    sid    = "AssociateRegionalWebAcl"
    effect = "Allow"
    actions = [
      "wafv2:AssociateWebACL",
      "wafv2:DisassociateWebACL",
      "waf-regional:AssociateWebACL",
      "waf-regional:DisassociateWebACL",
      "shield:CreateProtection",
      "shield:DeleteProtection",
    ]
    resources = ["*"]
  }

  # Security group lifecycle. Creation is gated on the request carrying the
  # controller's own cluster tag, so it cannot mint untagged groups.
  statement {
    sid       = "CreateSecurityGroup"
    effect    = "Allow"
    actions   = ["ec2:CreateSecurityGroup"]
    resources = ["*"]
  }

  statement {
    sid       = "TagOnCreate"
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:${local.partition}:ec2:${local.region}:${local.account_id}:security-group/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateSecurityGroup"]
    }

    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    sid       = "ManageOwnSecurityGroupsOnly"
    effect    = "Allow"
    actions   = ["ec2:CreateTags", "ec2:DeleteTags", "ec2:DeleteSecurityGroup"]
    resources = ["arn:${local.partition}:ec2:${local.region}:${local.account_id}:security-group/*"]

    # Only groups the controller itself tagged. It cannot delete ours.
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    sid       = "SecurityGroupRules"
    effect    = "Allow"
    actions   = ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress"]
    resources = ["*"]
  }

  statement {
    sid    = "CreateLoadBalancerAndTargetGroup"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:CreateTargetGroup",
    ]
    resources = ["*"]

    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    sid    = "ManageListenersAndRules"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:DeleteRule",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:ModifyRule",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ManageOwnLoadBalancersOnly"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:SetIpAddressType",
      "elasticloadbalancing:SetSecurityGroups",
      "elasticloadbalancing:SetSubnets",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:ModifyListenerAttributes",
      "elasticloadbalancing:SetWebAcl",
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
    ]
    resources = ["*"]

    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    sid    = "RegisterTargets"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
    ]
    resources = ["arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:targetgroup/*/*"]
  }

  statement {
    sid       = "ServiceLinkedRole"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["elasticloadbalancing.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "alb_controller" {
  name   = "alb-controller"
  role   = aws_iam_role.alb_controller.id
  policy = data.aws_iam_policy_document.alb_controller.json
}

resource "aws_eks_pod_identity_association" "alb_controller" {
  cluster_name    = var.cluster_name
  namespace       = var.alb_controller_namespace
  service_account = var.alb_controller_service_account
  role_arn        = aws_iam_role.alb_controller.arn

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb-controller" })
}
