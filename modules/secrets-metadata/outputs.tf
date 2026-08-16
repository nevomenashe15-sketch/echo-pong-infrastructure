output "secret_arn" {
  description = "ARN of the secret. echo-pong-gitops references this in its ExternalSecret's remoteRef."
  value       = aws_secretsmanager_secret.this.arn
}

output "secret_name" {
  description = "Name of the secret."
  value       = aws_secretsmanager_secret.this.name
}

# There is no output for the secret VALUE, and there never will be. Terraform
# does not read it.
