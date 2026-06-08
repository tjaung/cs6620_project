output "lambda_function_name" {
  description = "Name of the Lambda function invoked by GitHub Actions."
  value       = aws_lambda_function.repo_reader.function_name
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function invoked by GitHub Actions."
  value       = aws_lambda_function.repo_reader.arn
}

output "github_actions_role_arn" {
  description = "IAM role ARN used by GitHub Actions through OIDC. No static AWS credentials are needed."
  value       = var.create_github_oidc_role ? aws_iam_role.github_actions[0].arn : ""
}

output "github_oidc_subject" {
  description = "GitHub OIDC subject pattern allowed to assume the role."
  value       = var.create_github_oidc_role ? local.github_subject_like : ""
}

output "lambda_execution_role_arn" {
  description = "IAM role ARN used by the Lambda function."
  value       = local.lambda_role_arn
}
