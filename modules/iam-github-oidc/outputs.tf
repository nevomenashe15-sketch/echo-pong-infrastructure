output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider."
  value       = local.oidc_provider_arn
}

output "role_arns" {
  description = "Map of role name -> ARN. echo-pong-workflows consumes these as repository variables / workflow inputs."
  value       = { for k, v in aws_iam_role.this : k => v.arn }
}

output "ci_validation_role_arn" {
  description = "ARN of echo-pong-gh-ci-validation."
  value       = aws_iam_role.this["echo-pong-gh-ci-validation"].arn
}

output "ecr_release_role_arn" {
  description = "ARN of echo-pong-gh-ecr-release."
  value       = aws_iam_role.this["echo-pong-gh-ecr-release"].arn
}

output "tf_plan_role_arn" {
  description = "ARN of echo-pong-gh-tf-plan."
  value       = aws_iam_role.this["echo-pong-gh-tf-plan"].arn
}

output "tf_apply_role_arn" {
  description = "ARN of echo-pong-gh-tf-apply."
  value       = aws_iam_role.this["echo-pong-gh-tf-apply"].arn
}

output "bootstrap_role_arn" {
  description = "ARN of echo-pong-gh-bootstrap."
  value       = aws_iam_role.this["echo-pong-gh-bootstrap"].arn
}
