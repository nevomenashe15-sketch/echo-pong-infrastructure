variable "name_prefix" {
  description = "Resource name prefix, e.g. echo-pong-prod."
  type        = string
}

variable "argocd_namespace" {
  description = "Namespace Argo CD is installed into."
  type        = string
  default     = "argocd"
}

variable "argocd_chart_version" {
  description = <<-EOT
    Version of the argo-cd Helm chart (argoproj/argo-helm). PINNED, not
    "latest": an unpinned chart means the thing that reconciles everything else
    can change underneath you on an unrelated apply. Bump deliberately.

    Check https://github.com/argoproj/argo-helm/releases before changing.
  EOT
  type        = string
  default     = "7.7.11"
}

variable "high_availability" {
  description = "Run Argo CD in HA mode (redundant repo-server, application-controller shards, Redis HA). prod true, dev false -- HA roughly triples the resource footprint for a control plane that a dev environment can tolerate losing."
  type        = bool
  default     = false
}

variable "system_node_taint_key" {
  description = "Taint key on the system node group that Argo CD must tolerate to schedule before Karpenter exists."
  type        = string
  default     = "echo-pong.io/system"
}

variable "gitops_repo_url" {
  description = "HTTPS URL of the echo-pong-gitops repository the root Application points at."
  type        = string
}

variable "gitops_target_revision" {
  description = "Git ref the root Application tracks. A branch (main) auto-follows; a tag or SHA pins. prod should consider a tag once the estate is stable."
  type        = string
  default     = "main"
}

variable "gitops_root_path" {
  description = "Path inside echo-pong-gitops holding the app-of-apps root, e.g. bootstrap/dev."
  type        = string
}

variable "create_bootstrap_application" {
  description = "Whether Terraform creates the single root Application. See the ownership discussion in main.tf before turning this off."
  type        = bool
  default     = true
}

variable "helm_timeout_seconds" {
  description = "Timeout for the Argo CD Helm release. The default 300s is often not enough on a cold cluster where CRDs and the Redis StatefulSet both have to settle."
  type        = number
  default     = 900
}
