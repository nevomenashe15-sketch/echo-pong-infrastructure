variable "production_repository_name" {
  description = "Name of the production repository. Fixed at 'echo-pong' by convention -- echo-pong-gitops pins image digests against this exact path."
  type        = string
  default     = "echo-pong"
}

variable "quarantine_repository_name" {
  description = "Name of the quarantine repository CI pushes to before scanning. Fixed at 'echo-pong-quarantine'."
  type        = string
  default     = "echo-pong-quarantine"
}

variable "kms_key_arn" {
  description = "CMK used to encrypt image layers at rest in both repositories."
  type        = string
}

variable "push_principal_arns" {
  description = "IAM role ARNs allowed to push to quarantine and to promote into production. In practice the echo-pong-gh-ecr-release role only."
  type        = list(string)
}

variable "pull_principal_arns" {
  description = "IAM role ARNs allowed to pull from the PRODUCTION repository. The EKS node roles of every environment, since dev and prod pull the same promoted digest."
  type        = list(string)
  default     = []
}

variable "read_only_principal_arns" {
  description = "IAM role ARNs allowed to describe/list images without pulling layers, e.g. echo-pong-gh-ci-validation."
  type        = list(string)
  default     = []
}

variable "production_untagged_expiry_days" {
  description = "How long an untagged manifest survives in the production repository. Untagged manifests in production are almost always orphaned multi-arch children or overwritten promotions."
  type        = number
  default     = 14
}

variable "production_release_image_count" {
  description = "How many v* SemVer release images to retain in production. This is the rollback horizon: you can only roll back to a digest that still exists."
  type        = number
  default     = 30
}

variable "quarantine_expiry_days" {
  description = "Blanket expiry for EVERYTHING in the quarantine repository. Quarantine is a scanning holding area, not storage; an image that has not been promoted within this window is not going to be."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Tags applied to both repositories."
  type        = map(string)
  default     = {}
}
