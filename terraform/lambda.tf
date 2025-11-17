# ============================================
# Generic Lambda Functions (Dummy Implementation)
# ============================================

resource "aws_lambda_function" "etl" {
  for_each = var.lambda_functions

  function_name = "${var.project_name}-${each.value.name_suffix}-${var.environment}"
  description   = each.value.description
  role          = aws_iam_role.lambda_execution.arn

  # Deployment package
  filename         = var.lambda_package_path
  source_code_hash = filebase64sha256(var.lambda_package_path)

  # Runtime configuration
  handler     = each.value.handler
  runtime     = each.value.runtime
  timeout     = each.value.timeout
  memory_size = each.value.memory_size

  # Environment variables
  environment {
    variables = merge(
      each.value.environment_vars,
      {
        PROJECT_NAME = var.project_name
        ENVIRONMENT  = var.environment
        REGION       = var.aws_region
        # S3 Bucket names as environment variables
        LANDING_BUCKET = aws_s3_bucket.data_lake["landing"].id
        BRONZE_BUCKET  = aws_s3_bucket.data_lake["bronze"].id
        SILVER_BUCKET  = aws_s3_bucket.data_lake["silver"].id
        GOLD_BUCKET    = aws_s3_bucket.data_lake["gold"].id
      }
    )
  }

  tags = {
    Name     = "${var.project_name}-${each.value.name_suffix}-${var.environment}"
    Function = each.key
  }

  # Wait for IAM role to be fully created
  depends_on = [
    aws_iam_role_policy_attachment.lambda_execution
  ]
}

# ============================================
# Lambda Layer for Pandas and PyArrow
# ============================================

# S3 bucket for Lambda Layer storage (required for large layers > 50MB)
resource "aws_s3_bucket" "lambda_layers" {
  bucket = "${var.project_name}-lambda-layers-${var.environment}"

  tags = {
    Name    = "${var.project_name}-lambda-layers-${var.environment}"
    Purpose = "Lambda Layer Storage"
  }
}

# Block public access for lambda layers bucket
resource "aws_s3_bucket_public_access_block" "lambda_layers" {
  bucket = aws_s3_bucket.lambda_layers.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Upload layer zip to S3
resource "aws_s3_object" "pandas_layer" {
  bucket = aws_s3_bucket.lambda_layers.id
  key    = "layers/pandas_pyarrow_layer.zip"
  source = var.pandas_layer_path
  etag   = filemd5(var.pandas_layer_path)

  tags = {
    Name    = "pandas-pyarrow-layer"
    Version = filemd5(var.pandas_layer_path)
  }
}

# Lambda Layer using S3 as source
resource "aws_lambda_layer_version" "pandas_pyarrow" {
  layer_name          = "${var.project_name}-pandas-pyarrow-layer"
  description         = "Lambda Layer with Pandas and PyArrow for data processing"
  s3_bucket           = aws_s3_bucket.lambda_layers.id
  s3_key              = aws_s3_object.pandas_layer.key
  source_code_hash    = filebase64sha256(var.pandas_layer_path)
  compatible_runtimes = ["python3.9", "python3.10", "python3.11"]

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_s3_object.pandas_layer]
}

# ============================================
# Ingestion Lambda Function (Real Implementation)
# ============================================

resource "aws_lambda_function" "ingestion" {
  function_name = "${var.project_name}-${var.ingestion_lambda_config.function_name}-${var.environment}"
  description   = var.ingestion_lambda_config.description
  role          = aws_iam_role.lambda_execution.arn

  # Deployment package with real implementation
  filename         = var.ingestion_package_path
  source_code_hash = filebase64sha256(var.ingestion_package_path)

  # Runtime configuration
  handler     = var.ingestion_lambda_config.handler
  runtime     = var.ingestion_lambda_config.runtime
  timeout     = var.ingestion_lambda_config.timeout
  memory_size = var.ingestion_lambda_config.memory_size

  # Attach Lambda Layer with Pandas and PyArrow
  layers = [aws_lambda_layer_version.pandas_pyarrow.arn]

  # Environment variables
  environment {
    variables = merge(
      var.ingestion_lambda_config.environment_vars,
      {
        PROJECT_NAME = var.project_name
        ENVIRONMENT  = var.environment
        REGION       = var.aws_region
        # S3 Bucket names as environment variables
        LANDING_BUCKET = aws_s3_bucket.data_lake["landing"].id
        BRONZE_BUCKET  = aws_s3_bucket.data_lake["bronze"].id
        SILVER_BUCKET  = aws_s3_bucket.data_lake["silver"].id
        GOLD_BUCKET    = aws_s3_bucket.data_lake["gold"].id
        # Event-driven pipeline configuration
        BRONZE_CRAWLER_NAME = "${var.project_name}-bronze-car-data-crawler-${var.environment}"
        WORKFLOW_NAME       = "${var.workflow_name}-eventdriven"
      }
    )
  }

  tags = {
    Name     = "${var.project_name}-ingestion-${var.environment}"
    Function = "ingestion"
    Type     = "real-implementation"
  }

  # Wait for IAM role to be fully created
  depends_on = [
    aws_iam_role_policy_attachment.lambda_execution,
    aws_lambda_layer_version.pandas_pyarrow
  ]
}

# Note: CloudWatch Log Groups are automatically created by Lambda when the function is first invoked
# If you need to manage log retention, ensure your IAM user has logs:CreateLogGroup permission
# or create the log groups manually in AWS Console before running Terraform

# ============================================
# Cleansing Lambda Function (Silver Layer - Real Implementation)
# ============================================

resource "aws_lambda_function" "cleansing" {
  function_name = "${var.project_name}-${var.cleansing_lambda_config.function_name}-${var.environment}"
  description   = var.cleansing_lambda_config.description
  role          = aws_iam_role.lambda_execution.arn

  # Deployment package with real implementation
  filename         = var.cleansing_package_path
  source_code_hash = filebase64sha256(var.cleansing_package_path)

  # Runtime configuration
  handler     = var.cleansing_lambda_config.handler
  runtime     = var.cleansing_lambda_config.runtime
  timeout     = var.cleansing_lambda_config.timeout
  memory_size = var.cleansing_lambda_config.memory_size

  # Attach Lambda Layer with Pandas and PyArrow
  layers = [aws_lambda_layer_version.pandas_pyarrow.arn]

  # Environment variables
  environment {
    variables = merge(
      var.cleansing_lambda_config.environment_vars,
      {
        PROJECT_NAME = var.project_name
        ENVIRONMENT  = var.environment
        REGION       = var.aws_region
        # S3 Bucket names as environment variables
        LANDING_BUCKET = aws_s3_bucket.data_lake["landing"].id
        BRONZE_BUCKET  = aws_s3_bucket.data_lake["bronze"].id
        SILVER_BUCKET  = aws_s3_bucket.data_lake["silver"].id
        GOLD_BUCKET    = aws_s3_bucket.data_lake["gold"].id
      }
    )
  }

  tags = {
    Name     = "${var.project_name}-cleansing-${var.environment}"
    Function = "cleansing"
    Type     = "real-implementation"
    Layer    = "silver"
  }

  # Wait for IAM role to be fully created
  depends_on = [
    aws_iam_role_policy_attachment.lambda_execution,
    aws_lambda_layer_version.pandas_pyarrow
  ]
}

# ============================================
# S3 Trigger for Ingestion Lambda
# ============================================

# Lambda Permission for S3 to invoke the ingestion function
resource "aws_lambda_permission" "allow_s3_invoke_ingestion" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingestion.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.data_lake["landing"].arn
}

# S3 Bucket Notification to trigger ingestion Lambda
resource "aws_s3_bucket_notification" "landing_bucket_notification" {
  bucket = aws_s3_bucket.data_lake["landing"].id

  # Trigger for CSV files
  lambda_function {
    id                  = "csv-trigger"
    lambda_function_arn = aws_lambda_function.ingestion.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".csv"
  }

  # Trigger for JSON files
  lambda_function {
    id                  = "json-trigger"
    lambda_function_arn = aws_lambda_function.ingestion.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".json"
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke_ingestion]
}

# ============================================
# S3 Trigger for Cleansing Lambda - REMOVED
# ============================================
# 
# The cleansing Lambda function is no longer triggered by S3 events.
# This functionality has been replaced by the AWS Glue Job for Silver
# layer consolidation with proper Upsert/deduplication logic.
#
# See: terraform/glue_jobs.tf for the new implementation
#
# Previous implementation:
# - aws_lambda_permission.allow_s3_invoke_cleansing (REMOVED)
# - aws_s3_bucket_notification.bronze_bucket_notification (REMOVED)
#
# Migration Notes:
# - The cleansing Lambda function is kept for reference but not triggered
# - To fully remove, comment out aws_lambda_function.cleansing resource
# - Glue Job runs on schedule instead of event-based triggers
# - Glue Job provides better consolidation with Window function deduplication
