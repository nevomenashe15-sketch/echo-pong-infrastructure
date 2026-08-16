output "production_repository_url" {
  description = "Registry URL of the production repository. echo-pong-gitops pins <this>@sha256:... in its Helm values."
  value       = aws_ecr_repository.this["production"].repository_url
}

output "production_repository_arn" {
  description = "ARN of the production repository."
  value       = aws_ecr_repository.this["production"].arn
}

output "production_repository_name" {
  description = "Name of the production repository."
  value       = aws_ecr_repository.this["production"].name
}

output "quarantine_repository_url" {
  description = "Registry URL of the quarantine repository. echo-pong-workflows pushes here first."
  value       = aws_ecr_repository.this["quarantine"].repository_url
}

output "quarantine_repository_arn" {
  description = "ARN of the quarantine repository."
  value       = aws_ecr_repository.this["quarantine"].arn
}

output "quarantine_repository_name" {
  description = "Name of the quarantine repository."
  value       = aws_ecr_repository.this["quarantine"].name
}

output "registry_id" {
  description = "AWS account ID that owns the registry."
  value       = aws_ecr_repository.this["production"].registry_id
}
