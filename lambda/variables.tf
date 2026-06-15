variable "aws_region" {
  description = "AWS region where Lambda and IAM resources will be created."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name prefix used for AWS resources."
  type        = string
  default     = "security-scan-platform"
}

variable "source_bucket_name" {
  description = "S3 bucket name created by the s3 Terraform stack."
  type        = string
}

variable "sast_service_url" {
  description = "Base URL for the SAST service, for example http://1.2.3.4:3000."
  type        = string
  default     = ""
}

variable "pentest_service_url" {
  description = "Base URL for the pentest service, for example http://1.2.3.4:3000."
  type        = string
  default     = ""
}

variable "use_lab_role" {
  description = "Use the AWS Academy Learner Lab pre-created LabRole instead of creating IAM roles. Set true when iam:CreateRole is blocked."
  type        = bool
  default     = false
}

variable "existing_lambda_role_arn" {
  description = "Existing IAM role ARN for Lambda execution. If empty and use_lab_role is true, arn:aws:iam::<account>:role/LabRole is used."
  type        = string
  default     = ""
}

variable "create_github_oidc_role" {
  description = "Create GitHub OIDC provider and IAM role. Set false in AWS Academy Learner Lab when IAM creation is blocked."
  type        = bool
  default     = true
}

variable "github_owner" {
  description = "GitHub user or organization allowed to assume the workflow role."
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "Optional GitHub repo name allowed to assume the workflow role. Leave empty to allow all repos under github_owner."
  type        = string
  default     = ""
}

variable "lambda_timeout_seconds" {
  description = "Lambda timeout for security scans."
  type        = number
  default     = 180
}

variable "lambda_memory_mb" {
  description = "Lambda memory size."
  type        = number
  default     = 512
}
