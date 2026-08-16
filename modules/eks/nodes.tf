# =============================================================================
# System node group (arm64 / Graviton)
# =============================================================================
# This group exists for one reason: something has to run CoreDNS, the AWS Load
# Balancer Controller, External Secrets Operator and the Karpenter controller
# ITSELF before Karpenter is able to provision anything. Karpenter cannot
# schedule the pod that runs Karpenter.
#
# It is deliberately small and deliberately NOT where the app runs. Application
# capacity comes from Karpenter, whose NodePool and EC2NodeClass live in
# echo-pong-gitops -- not here. See docs/architecture.md "Karpenter boundary".
#
# Graviton: the echo-pong image is multi-arch (linux/amd64 + linux/arm64) and
# every controller above publishes arm64 images, so there is no compatibility
# reason to pay the x86 premium.
# =============================================================================

data "aws_iam_policy_document" "node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-system-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    # SSM Session Manager instead of SSH. No key pair, no port 22, no bastion.
    "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# -----------------------------------------------------------------------------
# Launch template
# -----------------------------------------------------------------------------
# An explicit launch template rather than the managed node group defaults,
# because two of the settings below are not reachable any other way:
# IMDSv2-required (http_tokens) and encrypted root volumes.
resource "aws_launch_template" "system" {
  name_prefix = "${var.cluster_name}-system-"

  vpc_security_group_ids = [aws_security_group.node.id]

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = var.system_node_group.disk_size_gb
      volume_type = "gp3"
      encrypted   = true
      # Deliberately the AWS-managed EBS key, not our CMK. Using a CMK here
      # requires the EC2 Auto Scaling service-linked role to hold a grant on
      # it, which in turn requires either a kms:CreateGrant statement scoped
      # with kms:GrantIsForAWSResource, or a key_user list that includes a role
      # this module creates -- a dependency cycle between the kms and eks
      # modules. The data at risk is a stateless node's root volume: the app
      # holds its secret in a projected Kubernetes Secret, not on disk. The
      # complexity is not worth it here; the volume is still encrypted.
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    # IMDSv2 required. IMDSv1 lets any SSRF in a pod read the node role's
    # credentials with a single unauthenticated GET.
    http_tokens = "required"
    # hop limit 1 means a container on the host bridge network cannot reach
    # IMDS at all -- the node role becomes unreachable from pods, which is
    # exactly what we want now that pods get credentials via Pod Identity.
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.cluster_name}-system" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.cluster_name}-system" })
  }

  tag_specifications {
    resource_type = "network-interface"
    tags          = merge(var.tags, { Name = "${var.cluster_name}-system" })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-system"
  node_role_arn   = aws_iam_role.node.arn

  # PRIVATE subnets only. Combined with map_public_ip_on_launch = false on
  # those subnets, no node ever receives a public IP.
  subnet_ids = var.private_subnet_ids

  # AL2023_ARM_64_STANDARD -- AL2 is end-of-support and AL2023 is the current
  # default AMI family for new EKS node groups.
  ami_type       = "AL2023_ARM_64_STANDARD"
  capacity_type  = var.system_node_group.capacity_type
  instance_types = var.system_node_group.instance_types

  scaling_config {
    desired_size = var.system_node_group.desired_size
    min_size     = var.system_node_group.min_size
    max_size     = var.system_node_group.max_size
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.system.id
    version = aws_launch_template.system.latest_version
  }

  labels = {
    "echo-pong.io/role" = "system"
  }

  # Taint so that only workloads that explicitly tolerate it land here. Without
  # this, the app's pods would schedule onto the system group and the group
  # would silently become the app's capacity, defeating the point of Karpenter.
  # echo-pong-gitops adds the matching toleration to the controller charts.
  taint {
    key    = "echo-pong.io/system"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-system" })

  lifecycle {
    # desired_size drifts as the cluster autoscaler / manual scaling acts on it.
    # Terraform re-asserting it on every apply causes pointless node churn.
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

# -----------------------------------------------------------------------------
# Karpenter node IAM role + instance profile
# -----------------------------------------------------------------------------
# IAM PREREQUISITES ONLY. The NodePool and EC2NodeClass Kubernetes objects that
# actually reference this profile live in echo-pong-gitops and are applied by
# Argo CD. Terraform provides the AWS-side identity; Argo CD provides the
# Kubernetes-side intent. Neither repo can complete the loop alone, which is
# the intended single-owner split.
resource "aws_iam_role" "karpenter_node" {
  name               = "${var.cluster_name}-karpenter-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "karpenter_node" {
  for_each = toset([
    "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.karpenter_node.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node"
  role = aws_iam_role.karpenter_node.name
  tags = var.tags
}

# Karpenter-launched nodes must be able to join the cluster. With
# authentication_mode = "API" that is an access entry, not an aws-auth edit.
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"
  tags          = var.tags
}
