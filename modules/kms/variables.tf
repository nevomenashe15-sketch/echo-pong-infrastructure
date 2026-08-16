variable "alias" {
  description = "Alias for the key WITHOUT the leading 'alias/', e.g. echo-pong-prod-eks."
  type        = string
}

variable "description" {
  description = "Human-readable description of what the key protects."
  type        = string
}

variable "deletion_window_in_days" {
  description = "Waiting period before a scheduled key deletion completes. 30 days is the maximum and the right default for a key that encrypts data you cannot re-derive."
  type        = number
  default     = 30

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "deletion_window_in_days must be between 7 and 30."
  }
}

variable "service_principals" {
  description = "AWS service principals granted use of the key via the key policy, e.g. [\"logs.<region>.amazonaws.com\"]. Required for CloudWatch Logs group encryption, which cannot use IAM-only grants."
  type        = list(string)
  default     = []
}

variable "key_administrator_arns" {
  description = "IAM principal ARNs allowed to administer (not use) the key. Empty means account root only."
  type        = list(string)
  default     = []
}

variable "key_user_arns" {
  description = "IAM principal ARNs granted cryptographic use of the key."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to the key."
  type        = map(string)
  default     = {}
}
