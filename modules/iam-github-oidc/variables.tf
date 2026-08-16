variable "github_owner" {
  description = "GitHub organisation or user that owns all four echo-pong repositories."
  type        = string
}

variable "app_repository" {
  description = "Name of the application repository."
  type        = string
  default     = "echo-pong"
}

variable "infra_repository" {
  description = "Name of this infrastructure repository."
  type        = string
  default     = "echo-pong-infrastructure"
}

variable "gitops_repository" {
  description = "Name of the GitOps repository."
  type        = string
  default     = "echo-pong-gitops"
}

variable "workflows_repository" {
  description = "Name of the reusable-workflows repository."
  type        = string
  default     = "echo-pong-workflows"
}

variable "create_oidc_provider" {
  description = "Whether to create the GitHub OIDC provider. Set false if the account already has one -- an account may only have a single provider per issuer URL."
  type        = bool
  default     = true
}

variable "apply_environment_name" {
  description = "GitHub Environment name that gates terraform apply. The role's trust policy requires this claim, so an apply cannot run outside a protected environment."
  type        = string
  default     = "production-infra"
}

variable "bootstrap_environment_name" {
  description = "GitHub Environment name that gates the one-time bootstrap role."
  type        = string
  default     = "bootstrap"
}

variable "release_job_workflow_ref" {
  description = "Optional job_workflow_ref claim to pin the ECR release role to one specific reusable workflow file in echo-pong-workflows, e.g. 'nevomenashe15-sketch/echo-pong-workflows/.github/workflows/release.yml@refs/heads/main'. Empty disables the extra condition. Strongly recommended in production: without it, ANY workflow on main of the app repo can assume the release role."
  type        = string
  default     = ""
}

variable "state_bucket_arn" {
  description = "ARN of the Terraform state bucket, so plan/apply roles can be granted access to state and nothing else in S3."
  type        = string
}

variable "state_lock_table_arn" {
  description = "ARN of the DynamoDB lock table."
  type        = string
}

variable "state_kms_key_arn" {
  description = "ARN of the CMK encrypting state."
  type        = string
}

variable "ecr_repository_arns" {
  description = "ARNs of the production and quarantine ECR repositories the release role may act on. Nothing else in ECR is reachable."
  type        = list(string)
}

variable "max_session_duration" {
  description = "Maximum STS session duration in seconds for the GitHub roles."
  type        = number
  default     = 3600
}

variable "tags" {
  description = "Tags applied to every role."
  type        = map(string)
  default     = {}
}
