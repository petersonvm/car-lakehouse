# IAM Role for Lambda Functions
resource "aws_iam_role" "lambda_execution" {
  name               = "${var.project_name}-lambda-execution-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name = "${var.project_name}-lambda-execution-role-${var.environment}"
  }
}

# Trust policy for Lambda service to assume the role
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

# IAM Policy for Lambda Functions
resource "aws_iam_policy" "lambda_execution" {
  name        = "${var.project_name}-lambda-execution-policy-${var.environment}"
  description = "Policy for Lambda functions to access CloudWatch Logs and S3 buckets"
  policy      = data.aws_iam_policy_document.lambda_execution.json

  tags = {
    Name = "${var.project_name}-lambda-execution-policy-${var.environment}"
  }
}

# Policy document with permissions for Lambda functions
data "aws_iam_policy_document" "lambda_execution" {
  # CloudWatch Logs permissions
  statement {
    sid    = "CloudWatchLogsAccess"
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = [
      "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${var.project_name}-*",
      "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${var.project_name}-*:*"
    ]
  }

  # S3 Read permissions
  statement {
    sid    = "S3ReadAccess"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]

    resources = [
      for bucket in aws_s3_bucket.data_lake : bucket.arn
    ]
  }

  statement {
    sid    = "S3ReadObjectAccess"
    effect = "Allow"

    actions = [
      "s3:GetObject"
    ]

    resources = [
      for bucket in aws_s3_bucket.data_lake : "${bucket.arn}/*"
    ]
  }

  # S3 Write permissions
  statement {
    sid    = "S3WriteAccess"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:DeleteObject"
    ]

    resources = [
      for bucket in aws_s3_bucket.data_lake : "${bucket.arn}/*"
    ]
  }
}

# Attach the policy to the role
resource "aws_iam_role_policy_attachment" "lambda_execution" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = aws_iam_policy.lambda_execution.arn
}
