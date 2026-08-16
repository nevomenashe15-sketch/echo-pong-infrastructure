variable "secret_name" {
  description = "Full Secrets Manager secret name, e.g. echo-pong/prod/api-token."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK encrypting the secret. A CMK rather than the aws/secretsmanager managed key so that reading the secret requires a grant on a key we control and every decrypt is attributable in CloudTrail."
  type        = string
}

variable "recovery_window_in_days" {
  description = "Days a deleted secret is recoverable. 0 means immediate irreversible deletion -- never use 0 for the token that gates the whole API."
  type        = number
  default     = 30

  validation {
    condition     = var.recovery_window_in_days >= 7
    error_message = "recovery_window_in_days must be at least 7. Immediate deletion of the app's auth token is not a recoverable mistake."
  }
}

variable "reader_role_arns" {
  description = "IAM role ARNs granted read access via the secret's RESOURCE policy, in addition to their identity policy. Normally just the External Secrets Operator role."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to the secret."
  type        = map(string)
  default     = {}
}
