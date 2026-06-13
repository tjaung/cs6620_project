variable "aws_region" {
  description = "AWS region where the scan artifact bucket will be created."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name prefix used for AWS resources."
  type        = string
  default     = "security-scan-platform"
}

variable "bucket_name" {
  description = "Optional globally unique S3 bucket name. Leave empty to let Terraform generate one."
  type        = string
  default     = ""
}

variable "artifact_retention_days" {
  description = "Number of days to keep uploaded repo zips and Lambda result artifacts."
  type        = number
  default     = 14
}
