variable "name_prefix" {
  description = "Resource name prefix, e.g. echo-pong-prod."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. dev = 10.20.0.0/16, prod = 10.10.0.0/16."
  type        = string
}

variable "azs" {
  description = "Availability zones to spread subnets across. 3 for prod, 2 acceptable for dev."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "At least 2 AZs are required: EKS refuses to create a control plane in fewer than 2, and a single-AZ data plane has no meaningful availability story."
  }
}

variable "single_nat_gateway" {
  description = "true = one NAT Gateway for the whole VPC (cheap, single point of failure, cross-AZ data charges). false = one NAT Gateway per AZ. Set true in dev, false in prod."
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "Whether to enable VPC flow logs to CloudWatch Logs."
  type        = bool
  default     = true
}

variable "flow_log_traffic_type" {
  description = "ACCEPT, REJECT or ALL. dev uses REJECT (cheap, still catches misconfigured security groups); prod uses ALL (needed for incident forensics)."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.flow_log_traffic_type)
    error_message = "flow_log_traffic_type must be one of ACCEPT, REJECT, ALL."
  }
}

variable "flow_log_retention_days" {
  description = "CloudWatch Logs retention for VPC flow logs."
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_log_retention_days)
    error_message = "flow_log_retention_days must be a retention value CloudWatch Logs accepts."
  }
}

variable "kms_key_arn" {
  description = "CMK used to encrypt the flow log group."
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster the subnets will host, used for the kubernetes.io/cluster/<name> discovery tags."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
