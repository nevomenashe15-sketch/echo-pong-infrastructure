# =============================================================================
# Core EKS add-ons
# =============================================================================
# Managed as aws_eks_addon rather than as Helm charts in echo-pong-gitops,
# because these four are cluster infrastructure rather than platform software:
# the cluster is not functional without them, so they cannot depend on Argo CD,
# which itself needs a functioning cluster (CoreDNS in particular) to start.
#
# DELIBERATELY ABSENT: aws-ebs-csi-driver. echo-pong is stateless -- it reads
# one secret from a projected file and serves HTTP. There are no PVCs, so the
# driver would be a controller, a DaemonSet and an IAM role that exist to
# support zero volumes. Listed in docs/future-extensions.md as the thing to add
# the day a persistent workload arrives.
# =============================================================================

locals {
  addons = {
    "vpc-cni" = {
      version = var.addon_versions.vpc_cni
      # The CNI runs before Pod Identity is available (it IS the thing that
      # gives pods network), so it uses the node role rather than its own.
      service_account_role_arn = null
      configuration_values = jsonencode({
        env = {
          # Prefix delegation: without it a m7g.large tops out at ~29 pods and
          # you burn ENIs. With it, a /28 prefix is assigned per ENI.
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
          # Enforce that pods cannot reach the node's IMDS.
          AWS_VPC_K8S_CNI_EXTERNALSNAT = "false"
        }
      })
    }

    "kube-proxy" = {
      version                  = var.addon_versions.kube_proxy
      service_account_role_arn = null
      configuration_values     = null
    }

    "coredns" = {
      version                  = var.addon_versions.coredns
      service_account_role_arn = null
      configuration_values = jsonencode({
        # CoreDNS must tolerate the system taint, otherwise it cannot schedule
        # anywhere before Karpenter exists and the cluster has no DNS.
        tolerations = [{
          key      = "echo-pong.io/system"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }]
        replicaCount = 2
      })
    }

    # The agent that makes EKS Pod Identity work at all. Without it, every
    # aws_eks_pod_identity_association in modules/iam-pod-identity is inert and
    # the controllers fall back to the node role -- which would silently give
    # them MORE permission than intended, not less. This add-on is load-bearing.
    "eks-pod-identity-agent" = {
      version                  = var.addon_versions.eks_pod_identity_agent
      service_account_role_arn = null
      configuration_values     = null
    }
  }
}

resource "aws_eks_addon" "this" {
  for_each = local.addons

  cluster_name = aws_eks_cluster.this.name
  addon_name   = each.key

  # An empty string means "no explicit version": EKS resolves the default for
  # the cluster's Kubernetes version. Pinning is available via
  # var.addon_versions once you have a reason to pin.
  addon_version = each.value.version != "" ? each.value.version : null

  service_account_role_arn = each.value.service_account_role_arn
  configuration_values     = each.value.configuration_values

  # OVERWRITE: if a previous self-managed install left objects behind, adopt
  # them rather than failing the apply. PRESERVE on delete so that removing the
  # add-on from Terraform does not rip DNS out of a running cluster.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags

  depends_on = [aws_eks_node_group.system]
}
