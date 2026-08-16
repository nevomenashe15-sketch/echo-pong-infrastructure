# =============================================================================
# EKS Pod Identity roles for the three platform controllers
# =============================================================================
# DECISION: EKS Pod Identity, not IRSA. Final, not hedged.
#
# Why: Pod Identity is the mechanism AWS now recommends, and every controller
# this cluster runs supports it -- AWS Load Balancer Controller >= v2.7,
# External Secrets Operator (v0.10+), and Karpenter >= v1.0. Concretely it buys:
#   - The trust policy is a static service-principal policy. It does not embed
#     the cluster's OIDC issuer URL, so a cluster rebuild does not invalidate
#     every role.
#   - The role ARN does NOT have to appear as an annotation on the
#     ServiceAccount. That matters here: echo-pong-gitops would otherwise need
#     to template an AWS account ID into its Helm values, coupling the two
#     repositories. With Pod Identity the association lives entirely on the AWS
#     side and the ServiceAccount is plain.
#   - Association is namespace+serviceaccount scoped by an AWS API object that
#     Terraform owns, rather than by a Kubernetes annotation Argo CD owns.
#
# IF a controller version turns out not to support Pod Identity: the fallback
# is IRSA against the cluster OIDC provider, which modules/eks already creates
# (var.enable_irsa_oidc_provider, default true) precisely so this fallback
# needs no cluster change. It is NOT double-instantiated here -- adding it
# would mean two live credential paths per controller and no way to tell from
# CloudTrail which one a request used. The fallback is a documented change, not
# a standing configuration. See docs/architecture.md.
#
# The app's OWN ServiceAccount deliberately has no role here: echo-pong reads
# its secret from a file that External Secrets Operator materialises as a
# native Kubernetes Secret. The app pod holds no AWS identity at all.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name
}

# The single trust policy shared by all three roles.
data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    effect = "Allow"
    actions = [
      "sts:AssumeRole",
      # Pod Identity issues session tags describing the pod; without
      # TagSession the association fails at runtime with an opaque error.
      "sts:TagSession",
    ]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    # Without this condition the role is assumable on behalf of a pod in ANY
    # cluster in the account. This is the load-bearing line of the trust policy.
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.cluster_arn]
    }
  }
}
