resource "random_id" "bucket_suffix" {
  byte_length = 4
}

locals {
  bucket_name = var.bucket_name != "" ? var.bucket_name : "${var.project_name}-artifacts-${random_id.bucket_suffix.hex}"
}

resource "aws_s3_bucket" "scan_artifacts" {
  bucket = local.bucket_name

  tags = {
    Project = var.project_name
  }
}

resource "aws_s3_bucket_public_access_block" "scan_artifacts" {
  bucket = aws_s3_bucket.scan_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "scan_artifacts" {
  bucket = aws_s3_bucket.scan_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "scan_artifacts" {
  bucket = aws_s3_bucket.scan_artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "scan_artifacts" {
  bucket = aws_s3_bucket.scan_artifacts.id

  rule {
    id     = "expire-scan-artifacts"
    status = "Enabled"

    filter {
      prefix = "github/"
    }

    expiration {
      days = var.artifact_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.artifact_retention_days
    }
  }
}
