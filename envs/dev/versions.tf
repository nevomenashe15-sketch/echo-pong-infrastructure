terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.90.0, < 6.0.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Filled in by `terraform init -backend-config=backend.hcl`. The values come
  # from the bootstrap layer's outputs; see README.md "Bootstrap ordering".
  #
  # State keys are explicit paths (`dev/terraform.tfstate`), NOT workspace
  # prefixes (`env:/dev/...`). See docs/architecture.md for why workspaces
  # were rejected.
  backend "s3" {
    key = "dev/terraform.tfstate"
    # bucket, region, dynamodb_table, kms_key_id, encrypt supplied via
    # -backend-config. Committing them here would hardcode an account-specific
    # bucket name into the repository.
  }
}
