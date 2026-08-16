variable "cluster_name" {
  description = "Name of the EKS cluster, e.g. echo-pong-prod."
  type        = string
}

variable "kubernetes_version" {
  description = <<-EOT
    EKS control plane minor version, e.g. "1.32".

    IMPORTANT: the allowed list in the validation block below is a snapshot.
    EKS support windows move roughly every three months and AWS force-upgrades
    clusters that fall out of extended support. The list MUST be re-checked
    against https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html
    before every apply -- a hardcoded "current" version in a repository is
    wrong within a quarter. The validation exists to stop a typo (1.3, 1.42),
    NOT to assert that these versions are still supported today.
  EOT
  type        = string

  validation {
    condition     = contains(["1.31", "1.32", "1.33"], var.kubernetes_version)
    error_message = "kubernetes_version must be one of 1.31, 1.32, 1.33. If AWS has moved on, update this list AFTER checking the EKS version support docs -- do not widen it blindly."
  }
}

variable "vpc_id" {
  description = "VPC the cluster lives in."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs. Both the control plane ENIs and every node land here."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "EKS requires subnets in at least two availability zones."
  }
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint. Must be a real allow-list -- 0.0.0.0/0 is rejected by the validation below."
  type        = list(string)

  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "public_access_cidrs must not contain 0.0.0.0/0. Restrict to office/VPN egress ranges and the CI runner egress range, or set enable_public_access = false and reach the API over a private path."
  }

  validation {
    condition     = length(var.public_access_cidrs) > 0
    error_message = "public_access_cidrs must not be empty when the public endpoint is enabled."
  }
}

variable "enable_public_access" {
  description = "Whether the Kubernetes API has a public endpoint at all. Private access is always on. Keeping public access on (but CIDR-restricted) avoids needing a bastion for break-glass; turning it off is stricter but means GitHub-hosted runners can no longer reach the API."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "CMK for envelope-encrypting Kubernetes Secrets at rest in etcd, and for the control-plane log group."
  type        = string
}

variable "control_plane_log_retention_days" {
  description = "CloudWatch Logs retention for control plane logs. The audit log is the only record of who did what in the cluster, so do not set this below 30 in prod."
  type        = number
  default     = 90
}

variable "system_node_group" {
  description = <<-EOT
    The single managed node group that provides a stable landing zone for
    system components before Karpenter exists. arm64/Graviton.
  EOT
  type = object({
    instance_types = optional(list(string), ["m7g.large"])
    desired_size   = optional(number, 2)
    min_size       = optional(number, 2)
    max_size       = optional(number, 4)
    disk_size_gb   = optional(number, 50)
    capacity_type  = optional(string, "ON_DEMAND")
  })
  default = {}

  validation {
    condition     = var.system_node_group.min_size >= 2
    error_message = "The system node group must have at least 2 nodes: it hosts CoreDNS and the controllers, and a single node means a node replacement takes DNS down cluster-wide."
  }

  validation {
    condition     = var.system_node_group.capacity_type == "ON_DEMAND"
    error_message = "The system node group must be ON_DEMAND. Spot interruption of the node running the Karpenter controller can leave the cluster unable to provision its own replacement capacity."
  }
}

variable "cluster_admin_principal_arns" {
  description = "IAM principal ARNs granted cluster-admin via EKS access entries. Must include the terraform apply role, otherwise Terraform cannot install Argo CD."
  type        = list(string)
  default     = []
}

variable "enable_irsa_oidc_provider" {
  description = "Create the cluster's IAM OIDC provider. This does NOT create any IRSA roles -- it exists purely so an IRSA fallback role can be added later without a cluster change. See docs/architecture.md 'Pod Identity vs IRSA'."
  type        = bool
  default     = true
}

variable "node_security_group_extra_ingress_cidrs" {
  description = "Extra CIDRs allowed to reach node ports. Normally empty: the ALB reaches pods directly via IP targets, not node ports."
  type        = list(string)
  default     = []
}

variable "addon_versions" {
  description = "Optional pinned add-on versions, keyed by add-on name. Empty string means 'let EKS pick the default for this Kubernetes version', which is the right default until you have a reason to pin."
  type = object({
    vpc_cni                = optional(string, "")
    coredns                = optional(string, "")
    kube_proxy             = optional(string, "")
    eks_pod_identity_agent = optional(string, "")
  })
  default = {}
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
