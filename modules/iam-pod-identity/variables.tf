variable "name_prefix" {
  description = "Resource name prefix, e.g. echo-pong-prod."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name the associations attach to."
  type        = string
}

variable "cluster_arn" {
  description = "EKS cluster ARN. Used as the aws:SourceArn condition so these roles cannot be assumed on behalf of a pod in some other cluster."
  type        = string
}

variable "karpenter_node_role_arn" {
  description = "ARN of the IAM role Karpenter-launched nodes assume. The controller needs iam:PassRole on exactly this role and nothing else."
  type        = string
}

variable "karpenter_interruption_queue_arn" {
  description = "ARN of the SQS queue carrying EC2 spot interruption and rebalance events. Empty disables the interruption-handling grant."
  type        = string
  default     = ""
}

variable "secret_arns" {
  description = "ARNs of the Secrets Manager secrets External Secrets Operator is allowed to read. Read-only, and scoped to these ARNs -- ESO must never be able to list or read the rest of the account's secrets."
  type        = list(string)
}

variable "secret_kms_key_arn" {
  description = "CMK encrypting those secrets. ESO needs kms:Decrypt on it."
  type        = string
}

variable "alb_controller_namespace" {
  description = "Namespace the AWS Load Balancer Controller runs in."
  type        = string
  default     = "kube-system"
}

variable "alb_controller_service_account" {
  description = "ServiceAccount name of the AWS Load Balancer Controller."
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "external_secrets_namespace" {
  description = "Namespace External Secrets Operator runs in."
  type        = string
  default     = "external-secrets"
}

variable "external_secrets_service_account" {
  description = "ServiceAccount name of External Secrets Operator."
  type        = string
  default     = "external-secrets"
}

variable "karpenter_namespace" {
  description = "Namespace the Karpenter controller runs in."
  type        = string
  default     = "karpenter"
}

variable "karpenter_service_account" {
  description = "ServiceAccount name of the Karpenter controller."
  type        = string
  default     = "karpenter"
}

variable "tags" {
  description = "Tags applied to every role."
  type        = map(string)
  default     = {}
}
