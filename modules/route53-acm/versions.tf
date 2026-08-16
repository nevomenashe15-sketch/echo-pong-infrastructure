terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.90.0, < 6.0.0"
      # This module needs BOTH providers. The caller must pass:
      #   providers = { aws = aws, aws.useast1 = aws.useast1 }
      configuration_aliases = [aws.useast1]
    }
  }
}
