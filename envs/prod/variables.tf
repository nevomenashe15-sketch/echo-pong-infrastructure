# =============================================================================
# Inputs -- envs/prod
# =============================================================================
# Defaults here encode the prod posture. Values with no default are
# account-specific and must be supplied via terraform.tfvars.
# =============================================================================

variable "aws_region" {
  description = "Region the whole stack runs in. NOT hardcoded anywhere -- the only region this repo hardcodes is us-east-1, and only for the CloudFront certificate and the CLOUDFRONT-scoped Web ACL, which AWS requires to live there."
  type        = string
}

variable "environment" {
  description = "Environment name. Used in the echo-pong-<env> name prefix and the Environment tag."
  type        = string
  default     = "prod"

  validation {
    condition     = var.environment == "prod"
    error_message = "This root module is envs/prod; environment must be \"prod\". Applying it with another value would produce resource names that collide with the other environment in the same account."
  }
}

variable "azs" {
  description = "Availability zones. Three in prod, so losing one AZ leaves a quorum of node capacity and NAT egress."
  type        = list(string)
}

variable "vpc_cidr" {
  description = "VPC CIDR. dev and prod are deliberately non-overlapping so the two can be peered later without renumbering."
  type        = string
  default     = "10.10.0.0/16"
}

variable "kubernetes_version" {
  description = "EKS control plane minor version. See the extended note in modules/eks/variables.tf -- the allowed list is a snapshot and MUST be re-checked against the AWS EKS version support docs before every apply."
  type        = string
  default     = "1.32"
}

variable "cluster_public_access_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint. Office/VPN egress and the CI runner egress range. 0.0.0.0/0 is rejected by the module's validation."
  type        = list(string)
}

variable "extra_cluster_admin_principal_arns" {
  description = <<-EOT
    IAM principal ARNs granted cluster-admin on this cluster via EKS access
    entries, IN ADDITION to the terraform-apply role.

    Required for the documented bootstrap sequence. envs/prod owns the account
    globals, so echo-pong-gh-tf-apply IS in the admin list -- but the first two
    applies are run from a HUMAN's credentials, not from CI, and that principal
    gets nothing otherwise (`bootstrap_cluster_creator_admin_permissions` is
    false in modules/eks). The symptom is the Argo CD helm_release failing with
    a Forbidden error on the second apply.

    Put the ARN of the role or user that runs the bootstrap applies here, plus
    any break-glass operator role.
  EOT
  type        = list(string)
  default     = []
}

variable "route53_zone_id" {
  description = "ID of the EXISTING Route 53 hosted zone. Never created by this stack."
  type        = string
}

variable "domain_name" {
  description = "Public FQDN this environment serves, e.g. echo-pong.example.com."
  type        = string
}

variable "github_owner" {
  description = "GitHub org/user owning the four echo-pong repositories."
  type        = string
  default     = "nevomenashe15-sketch"
}

variable "gitops_repo_url" {
  description = "HTTPS clone URL of echo-pong-gitops, which the Argo CD root Application tracks."
  type        = string
  default     = "https://github.com/nevomenashe15-sketch/echo-pong-gitops.git"
}

variable "gitops_root_path" {
  description = "Path inside echo-pong-gitops holding this environment's app-of-apps root."
  type        = string
  default     = "bootstrap/prod"
}

variable "manage_account_globals" {
  description = <<-EOT
    Whether THIS root module owns the account-global singletons: the GitHub
    Actions OIDC provider, the five echo-pong-gh-* roles, and the two ECR
    repositories.

    These have literal, environment-agnostic names and a single AWS account
    hosts both environments, so exactly one root module may create them or the
    second apply fails on EntityAlreadyExists. It is true here.

    Consequence: apply order is bootstrap -> envs/prod -> envs/dev.
    See docs/architecture.md "Account-global singletons".
  EOT
  type        = bool
  default     = true
}

variable "state_bucket_arn" {
  description = "ARN of the Terraform state bucket from the bootstrap layer. Used to scope the tf-plan/tf-apply role policies. Only read when manage_account_globals is true."
  type        = string
  default     = ""
}

variable "state_lock_table_arn" {
  description = "ARN of the DynamoDB lock table from the bootstrap layer."
  type        = string
  default     = ""
}

variable "state_kms_key_arn" {
  description = "ARN of the CMK encrypting Terraform state."
  type        = string
  default     = ""
}

variable "release_job_workflow_ref" {
  description = "Optional job_workflow_ref claim pinning the ECR release role to one reusable workflow in echo-pong-workflows. Strongly recommended -- see modules/iam-github-oidc/main.tf."
  type        = string
  default     = ""
}

variable "ecr_pull_principal_arns" {
  description = "Extra IAM role ARNs granted pull on the production ECR repository, beyond this environment's own node roles. In prod, add the dev cluster's node role ARNs here after envs/dev has been applied once."
  type        = list(string)
  default     = []
}

variable "cloudfront_log_bucket_name" {
  description = "Globally unique S3 bucket name for CloudFront access logs."
  type        = string
}

variable "waf_rule_action_override" {
  description = "Per-managed-rule-group action, \"count\" or \"block\". Every group still defaults to count -- promote to block one group at a time after reading a full traffic cycle of sampled requests. See docs/architecture.md 'WAF tuning workflow'."
  type        = map(string)
  default = {
    AWSManagedRulesCommonRuleSet          = "count"
    AWSManagedRulesKnownBadInputsRuleSet  = "count"
    AWSManagedRulesAmazonIpReputationList = "count"
  }
}

variable "waf_rate_limit_per_5min" {
  description = "WAF rate-based rule threshold per source IP per 5 minutes."
  type        = number
  default     = 2000
}

variable "enable_argocd" {
  description = <<-EOT
    Whether Terraform installs Argo CD. Must be FALSE on the very first apply
    of a new cluster: the helm provider authenticates against a cluster
    endpoint that does not exist yet, so a plan fails before it can create it.

    First apply:  enable_argocd = false, terraform apply
    Second apply: enable_argocd = true,  terraform apply
    Thereafter it stays true. See README.md "First apply".
  EOT
  type        = bool
  default     = true
}

variable "argocd_chart_version" {
  description = "Pinned argo-cd Helm chart version."
  type        = string
  default     = "7.7.11"
}

variable "tags" {
  description = "Extra tags merged into common_tags on every resource."
  type        = map(string)
  default     = {}
}
