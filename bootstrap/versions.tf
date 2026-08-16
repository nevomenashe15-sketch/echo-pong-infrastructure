terraform {
  # 1.9.x is the floor because the rest of the stack relies on `optional()`
  # object attributes and cross-object `validation` blocks.
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.90.0, < 6.0.0"
    }
  }

  # NOTE: bootstrap/ deliberately has NO backend block. It creates the S3
  # bucket + DynamoDB table that every other root module uses as its backend,
  # so it cannot itself live in that backend on first apply (chicken-and-egg).
  # Its state file is committed nowhere -- see bootstrap/README.md for the
  # documented handling of this state.
}
