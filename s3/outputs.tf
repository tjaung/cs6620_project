output "bucket_name" {
  description = "Name of the S3 bucket used for GitHub repo zips and scan results."
  value       = aws_s3_bucket.scan_artifacts.bucket
}

output "bucket_arn" {
  description = "ARN of the S3 bucket used for GitHub repo zips and scan results."
  value       = aws_s3_bucket.scan_artifacts.arn
}
