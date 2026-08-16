terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.90.0, < 6.0.0"
      # aws.useast1 is required for: the CloudFront-scoped WAFv2 Web ACL, and
      # the CloudFront standard-logging-v2 delivery resources. Both are
      # us-east-1-only, the same way the viewer certificate is.
      configuration_aliases = [aws.useast1]
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
