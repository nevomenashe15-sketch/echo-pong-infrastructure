output "state_bucket_name" {
  description = "Name of the Terraform state bucket. Use as `bucket` in every other root module's backend block."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the Terraform state bucket."
  value       = aws_s3_bucket.state.arn
}

output "lock_table_name" {
  description = "DynamoDB lock table name. Use as `dynamodb_table` in every other root module's backend block."
  value       = aws_dynamodb_table.locks.name
}

output "lock_table_arn" {
  description = "ARN of the DynamoDB lock table."
  value       = aws_dynamodb_table.locks.arn
}

output "state_kms_key_arn" {
  description = "ARN of the CMK encrypting state. Use as `kms_key_id` in every other root module's backend block."
  value       = aws_kms_key.state.arn
}

output "backend_config_snippet" {
  description = "Copy-paste backend block for the environment root modules."
  value       = <<-EOT
    backend "s3" {
      bucket         = "${aws_s3_bucket.state.id}"
      key            = "<shared|dev|prod>/terraform.tfstate"
      region         = "${var.aws_region}"
      dynamodb_table = "${aws_dynamodb_table.locks.name}"
      kms_key_id     = "${aws_kms_key.state.arn}"
      encrypt        = true
    }
  EOT
}
