variable "route53_zone_id" {
  description = "ID of an EXISTING Route 53 hosted zone supplied by the caller. This module never creates a zone -- creating a duplicate zone for a domain that already has one produces a second set of nameservers that the registrar is not pointing at, and every record in it is silently dead."
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]+$", var.route53_zone_id))
    error_message = "route53_zone_id must look like a Route 53 zone ID (Z...)."
  }
}

variable "domain_name" {
  description = "Public FQDN clients hit, e.g. echo-pong.example.com. Served by CloudFront."
  type        = string
}

variable "origin_hostname" {
  description = "Label prepended to domain_name for the ALB origin, giving e.g. origin.echo-pong.example.com. CloudFront connects to this over HTTPS."
  type        = string
  default     = "origin"
}

variable "subject_alternative_names" {
  description = "Extra SANs on the CloudFront certificate, e.g. [\"www.echo-pong.example.com\"]."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to the certificates."
  type        = map(string)
  default     = {}
}
