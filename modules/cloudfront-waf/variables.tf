variable "name_prefix" {
  description = "Resource name prefix, e.g. echo-pong-prod."
  type        = string
}

variable "domain_name" {
  description = "Public FQDN served by the distribution."
  type        = string
}

variable "aliases" {
  description = "All aliases on the distribution. Defaults to [domain_name] when empty."
  type        = list(string)
  default     = []
}

variable "origin_fqdn" {
  description = "DNS name CloudFront connects to for the origin, e.g. origin.echo-pong.example.com. Resolved to the app's ALB by external-dns; this module never creates that record or that ALB."
  type        = string
}

variable "viewer_certificate_arn" {
  description = "us-east-1 ACM certificate ARN for the viewer connection."
  type        = string
}

variable "web_acl_arn_override" {
  description = "Optionally attach an externally managed CLOUDFRONT Web ACL instead of the one this module builds. Empty uses the module's own."
  type        = string
  default     = ""
}

variable "price_class" {
  description = "CloudFront price class. PriceClass_100 (NA+EU) is the sane default for a single-region origin; edges in Asia would add latency to the origin fetch without a cache to absorb it, and every response here is uncacheable."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

variable "rate_limit_per_5min" {
  description = "WAF rate-based rule threshold: requests from one IP per 5-minute window before the rule fires. AWS enforces a floor of 100."
  type        = number
  default     = 2000

  validation {
    condition     = var.rate_limit_per_5min >= 100
    error_message = "AWS WAF requires a rate limit of at least 100."
  }
}

variable "rate_limit_action" {
  description = "block or count for the rate-based rule. Unlike the managed groups this defaults to block: a rate rule has effectively no false-positive surface for an API with a fixed, small client population."
  type        = string
  default     = "block"

  validation {
    condition     = contains(["block", "count"], var.rate_limit_action)
    error_message = "rate_limit_action must be block or count."
  }
}

variable "waf_rule_action_override" {
  description = <<-EOT
    Per-managed-rule-group action: "count" or "block". Keys must be the AWS
    managed rule group names.

    Every group DEFAULTS TO "count". This is intentional. A managed rule group
    switched straight to block on day one will reject some proportion of
    legitimate traffic, and you will discover which proportion during an
    incident. The promotion workflow is documented in docs/architecture.md:
    run in count, read the CloudWatch sampled requests and the
    <group>CountedRequests metric for a full traffic cycle, tune with
    rule_action_override exclusions, then flip to block one group at a time.
  EOT
  type        = map(string)
  default = {
    AWSManagedRulesCommonRuleSet          = "count"
    AWSManagedRulesKnownBadInputsRuleSet  = "count"
    AWSManagedRulesAmazonIpReputationList = "count"
  }

  validation {
    condition     = alltrue([for v in values(var.waf_rule_action_override) : contains(["count", "block"], v)])
    error_message = "Every value in waf_rule_action_override must be \"count\" or \"block\"."
  }
}

variable "log_bucket_name" {
  description = "Name for the CloudFront access log bucket. Must be globally unique."
  type        = string
}

variable "log_retention_days" {
  description = "Days CloudFront access logs are retained before expiry."
  type        = number
  default     = 90
}

variable "waf_log_retention_days" {
  description = "CloudWatch Logs retention for WAF logs. These drive the count-to-block promotion workflow, so the window needs to cover at least one full traffic cycle plus review time."
  type        = number
  default     = 30
}

variable "secret_kms_key_arn" {
  description = "CMK used to encrypt the Secrets Manager copy of the origin verification value."
  type        = string
}

variable "origin_secret_name" {
  description = "Secrets Manager name for the origin verification header value, e.g. echo-pong/prod/cloudfront-origin-verify."
  type        = string
}

variable "default_root_object_cache_seconds" {
  description = "TTL for the default (/) HTML docs behaviour. 0 disables caching, which is the default -- see the comment in main.tf on why even the static page starts uncached."
  type        = number
  default     = 0
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
