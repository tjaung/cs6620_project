data "aws_caller_identity" "current" {}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/repo-reader.zip"
}

locals {
  lambda_name         = "${var.project_name}-repo-reader"
  github_role_name    = "${var.project_name}-github-actions"
  github_subject_like = var.github_repo == "" ? "repo:${var.github_owner}/*:*" : "repo:${var.github_owner}/${var.github_repo}:*"
  lab_role_arn        = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/LabRole"
  lambda_role_arn     = var.existing_lambda_role_arn != "" ? var.existing_lambda_role_arn : (var.use_lab_role ? local.lab_role_arn : aws_iam_role.lambda_execution[0].arn)
}

resource "aws_iam_role" "lambda_execution" {
  count = var.use_lab_role ? 0 : 1

  name = "${local.lambda_name}-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_execution" {
  count = var.use_lab_role ? 0 : 1

  name = "${local.lambda_name}-policy"
  role = aws_iam_role.lambda_execution[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = "arn:aws:s3:::${var.source_bucket_name}/github/*"
      }
    ]
  })
}

resource "aws_lambda_function" "repo_reader" {
  function_name    = local.lambda_name
  role             = local.lambda_role_arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = var.lambda_timeout_seconds
  memory_size      = var.lambda_memory_mb

  environment {
    variables = {
      RESULT_BUCKET       = var.source_bucket_name
      SAST_SERVICE_URL    = var.sast_service_url
      PENTEST_SERVICE_URL = var.pentest_service_url
      MAX_FILES_TO_SCAN   = "80"
      MAX_FILE_BYTES      = "524288"
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda_execution
  ]
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_role ? 1 : 0

  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]
}

resource "aws_iam_role" "github_actions" {
  count = var.create_github_oidc_role ? 1 : 0

  name = local.github_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github[0].arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = local.github_subject_like
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "github_actions" {
  count = var.create_github_oidc_role ? 1 : 0

  name = "${local.github_role_name}-policy"
  role = aws_iam_role.github_actions[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = "arn:aws:s3:::${var.source_bucket_name}/github/*"
      },
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = aws_lambda_function.repo_reader.arn
      }
    ]
  })
}
