# =============================================================================
# EKS cluster
# =============================================================================
# Ownership boundary, stated up front because it governs everything below:
#   Terraform owns the cluster, the system node group, the core add-ons and the
#   IAM that the platform controllers need. Terraform does NOT own any
#   Kubernetes object except the Argo CD install (modules/argocd-bootstrap).
#   In particular Terraform never creates an aws_lb for the app -- the AWS Load
#   Balancer Controller owns that ALB's lifecycle. See docs/architecture.md.
# =============================================================================

data "aws_partition" "current" {}

locals {
  partition = data.aws_partition.current.partition
}

# -----------------------------------------------------------------------------
# Cluster IAM role
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "cluster_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy",
    # Lets the control plane manage the ENIs and security group rules it needs
    # in our VPC. Narrower than the legacy AmazonEKSVPCResourceController.
    "arn:${local.partition}:iam::aws:policy/AmazonEKSVPCResourceController",
  ])

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

# -----------------------------------------------------------------------------
# Control plane logging
# -----------------------------------------------------------------------------
# The log group is created explicitly rather than letting EKS create it, so
# that retention and CMK encryption are set from the first log line. If EKS
# creates it, it is created with Never Expire and no encryption.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.control_plane_log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

# -----------------------------------------------------------------------------
# Cluster security group
# -----------------------------------------------------------------------------
resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster"
  description = "Additional security group attached to the EKS control plane ENIs"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.cluster_name}-cluster" })
}

resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-node"
  description = "Security group for EKS worker nodes"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-node"
    # Karpenter selects the security group for the nodes it launches via this
    # tag. The matching EC2NodeClass selector lives in echo-pong-gitops.
    "karpenter.sh/discovery" = var.cluster_name
  })
}

resource "aws_vpc_security_group_ingress_rule" "node_from_node" {
  security_group_id            = aws_security_group.node.id
  description                  = "Node to node, all protocols (pod to pod across nodes, VPC CNI)"
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "node_from_cluster" {
  security_group_id            = aws_security_group.node.id
  description                  = "Control plane to kubelet and to webhook/extension API ports"
  referenced_security_group_id = aws_security_group.cluster.id
  from_port                    = 1025
  to_port                      = 65535
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "node_extra" {
  for_each = toset(var.node_security_group_extra_ingress_cidrs)

  security_group_id = aws_security_group.node.id
  description       = "Operator-supplied extra ingress"
  cidr_ipv4         = each.value
  from_port         = 1025
  to_port           = 65535
  ip_protocol       = "tcp"
}

# Nodes need unrestricted egress: image pulls, the EKS API, add-on registries
# and any outbound the app makes. It is scoped by the fact that they sit in
# private subnets behind a NAT Gateway with no inbound path.
resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  description       = "All egress -- private subnets, NAT only, no inbound path"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "cluster_from_node" {
  security_group_id            = aws_security_group.cluster.id
  description                  = "Nodes to the Kubernetes API"
  referenced_security_group_id = aws_security_group.node.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "cluster_all" {
  security_group_id = aws_security_group.cluster.id
  description       = "Control plane egress to nodes and AWS APIs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# -----------------------------------------------------------------------------
# Cluster
# -----------------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    # Control plane ENIs go in the PRIVATE subnets. There is no reason for the
    # control plane's cross-account ENIs to sit in a subnet with an IGW route.
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = var.enable_public_access
    public_access_cidrs     = var.enable_public_access ? var.public_access_cidrs : null
  }

  # Envelope encryption for Kubernetes Secrets. Without this, Secrets are only
  # protected by the EKS-managed etcd volume encryption, and a Secret read via
  # a compromised API credential is indistinguishable from a legitimate one in
  # CloudTrail. With a CMK, every decrypt is a KMS event attributable to the
  # cluster.
  encryption_config {
    provider {
      key_arn = var.kms_key_arn
    }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  access_config {
    # API, not API_AND_CONFIG_MAP: the aws-auth ConfigMap is a Kubernetes
    # object, and this repo's whole premise is that Terraform does not manage
    # Kubernetes objects. Access entries are the AWS-API-native equivalent.
    authentication_mode = "API"

    # false: the identity that happens to run the first apply must not get a
    # permanent invisible cluster-admin grant. Admin access is declared
    # explicitly in aws_eks_access_entry below, where it is reviewable.
    bootstrap_cluster_creator_admin_permissions = false
  }

  tags = merge(var.tags, { Name = var.cluster_name })

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# -----------------------------------------------------------------------------
# IRSA OIDC provider (provisioned, but no IRSA roles are created)
# -----------------------------------------------------------------------------
# DECISION: EKS Pod Identity is THE mechanism for this stack. All three
# controllers (AWS Load Balancer Controller >= v2.7, External Secrets Operator,
# Karpenter >= v1) support it, and it removes the per-cluster OIDC trust
# plumbing plus the "role ARN in a ServiceAccount annotation" coupling between
# this repo and echo-pong-gitops.
#
# This OIDC provider is still created because it costs nothing and it is the
# ONLY prerequisite that cannot be added quickly under incident pressure. If a
# controller version turns out to lack Pod Identity support, adding an IRSA
# role is then a self-contained change in modules/iam-pod-identity (a second
# aws_iam_role with a federated trust on this provider) rather than a cluster
# reconfiguration. No IRSA role is instantiated today.
data "tls_certificate" "cluster" {
  count = var.enable_irsa_oidc_provider ? 1 : 0
  url   = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  count = var.enable_irsa_oidc_provider ? 1 : 0

  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster[0].certificates[length(data.tls_certificate.cluster[0].certificates) - 1].sha1_fingerprint]

  tags = merge(var.tags, { Name = "${var.cluster_name}-irsa" })
}

# -----------------------------------------------------------------------------
# Access entries
# -----------------------------------------------------------------------------
resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}
