variable "aws_region" {
  description = "Region the state bucket and lock table live in. This is the region ALL environments' backends point at, regardless of which region their workloads run in."
  type        = string
}

variable "state_bucket_name" {
  description = "Globally unique name for the Terraform state bucket, e.g. echo-pong-tfstate-<account-id>."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a valid S3 bucket name (lowercase, 3-63 chars)."
  }
}

variable "lock_table_name" {
  description = "Name of the DynamoDB table used for Terraform state locking."
  type        = string
  default     = "echo-pong-tf-locks"
}

variable "noncurrent_version_expiration_days" {
  description = "How long superseded state versions are retained. State history is the only recovery path for a corrupted apply, so do not set this aggressively low."
  type        = number
  default     = 365
}

variable "state_reader_principal_arns" {
  description = "IAM principal ARNs allowed read-only access to state (typically the terraform plan role). Left empty on the very first apply, then filled in once envs/shared has created the roles."
  type        = list(string)
  default     = []
}

variable "state_writer_principal_arns" {
  description = "IAM principal ARNs allowed read/write access to state (typically the terraform apply and bootstrap roles)."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Additional tags merged into every resource's tags."
  type        = map(string)
  default     = {}
}
