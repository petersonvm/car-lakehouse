# ============================================
# AWS Glue Job - Silver Layer Consolidation
# ============================================
# This replaces the Lambda-based cleansing function with a scheduled Glue ETL Job
# that provides proper data consolidation using Upsert/deduplication logic.

# ============================================
# S3 Bucket for Glue Scripts
# ============================================

resource "aws_s3_bucket" "glue_scripts" {
  bucket = "${var.project_name}-glue-scripts-${var.environment}"

  tags = {
    Name    = "${var.project_name}-glue-scripts-${var.environment}"
    Purpose = "Glue ETL Scripts Storage"
  }
}

# Block public access for glue scripts bucket
resource "aws_s3_bucket_public_access_block" "glue_scripts" {
  bucket = aws_s3_bucket.glue_scripts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable versioning for Glue scripts
resource "aws_s3_bucket_versioning" "glue_scripts" {
  bucket = aws_s3_bucket.glue_scripts.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Upload Silver Consolidation PySpark script to S3
resource "aws_s3_object" "silver_consolidation_script" {
  bucket = aws_s3_bucket.glue_scripts.id
  key    = "glue_jobs/silver_consolidation_job.py"
  source = var.glue_silver_script_path
  etag   = filemd5(var.glue_silver_script_path)

  tags = {
    Name        = "silver-consolidation-script"
    Version     = filemd5(var.glue_silver_script_path)
    Description = "PySpark script for Silver layer consolidation with Upsert logic"
  }
}

# S3 bucket for Glue temporary files
resource "aws_s3_bucket" "glue_temp" {
  bucket = "${var.project_name}-glue-temp-${var.environment}"

  tags = {
    Name    = "${var.project_name}-glue-temp-${var.environment}"
    Purpose = "Glue Temporary Files"
  }
}

# Block public access for glue temp bucket
resource "aws_s3_bucket_public_access_block" "glue_temp" {
  bucket = aws_s3_bucket.glue_temp.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle policy for temp bucket (auto-delete after 7 days)
resource "aws_s3_bucket_lifecycle_configuration" "glue_temp" {
  bucket = aws_s3_bucket.glue_temp.id

  rule {
    id     = "delete-temp-files"
    status = "Enabled"
    
    filter {
      prefix = ""
    }

    expiration {
      days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# ============================================
# IAM Role for Glue Job
# ============================================

# IAM Role for Glue Job execution
resource "aws_iam_role" "glue_job" {
  name               = "${var.project_name}-glue-job-role-${var.environment}"
  description        = "IAM role for AWS Glue ETL Jobs with permissions for S3, Glue Catalog, and CloudWatch"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json

  tags = {
    Name    = "${var.project_name}-glue-job-role-${var.environment}"
    Service = "glue"
  }
}

# Policy for S3 access (Bronze read, Silver read/write/delete)
resource "aws_iam_role_policy" "glue_job_s3_access" {
  name   = "glue-job-s3-access"
  role   = aws_iam_role.glue_job.id
  policy = data.aws_iam_policy_document.glue_job_s3_policy.json
}

data "aws_iam_policy_document" "glue_job_s3_policy" {
  # Read access to Bronze bucket
  statement {
    sid    = "ReadBronzeBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.data_lake["bronze"].arn,
      "${aws_s3_bucket.data_lake["bronze"].arn}/*"
    ]
  }

  # Full access to Silver bucket (read, write, delete for overwrite)
  statement {
    sid    = "FullAccessSilverBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.data_lake["silver"].arn,
      "${aws_s3_bucket.data_lake["silver"].arn}/*"
    ]
  }

  # Access to Glue scripts bucket
  statement {
    sid    = "ReadGlueScripts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.glue_scripts.arn,
      "${aws_s3_bucket.glue_scripts.arn}/*"
    ]
  }

  # Access to Glue temp bucket
  statement {
    sid    = "AccessGlueTemp"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.glue_temp.arn,
      "${aws_s3_bucket.glue_temp.arn}/*"
    ]
  }
}

# Policy for Glue Data Catalog access
resource "aws_iam_role_policy" "glue_job_catalog_access" {
  name   = "glue-job-catalog-access"
  role   = aws_iam_role.glue_job.id
  policy = data.aws_iam_policy_document.glue_job_catalog_policy.json
}

data "aws_iam_policy_document" "glue_job_catalog_policy" {
  statement {
    sid    = "GlueCatalogAccess"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:DeleteTable",
      "glue:BatchCreatePartition",
      "glue:BatchDeletePartition",
      "glue:BatchGetPartition",
      "glue:CreatePartition",
      "glue:DeletePartition",
      "glue:UpdatePartition"
    ]
    resources = [
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.data_lake_database.name}",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.data_lake_database.name}/*"
    ]
  }
}

# Policy for CloudWatch Logs
resource "aws_iam_role_policy" "glue_job_cloudwatch_logs" {
  name   = "glue-job-cloudwatch-logs"
  role   = aws_iam_role.glue_job.id
  policy = data.aws_iam_policy_document.glue_job_logs_policy.json
}

data "aws_iam_policy_document" "glue_job_logs_policy" {
  statement {
    sid    = "CloudWatchLogsAccess"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws-glue/*"
    ]
  }
}

# Note: Using existing data source from glue.tf for aws_caller_identity.current

# ============================================
# AWS Glue Job - Silver Consolidation
# ============================================

resource "aws_glue_job" "silver_consolidation" {
  name        = "${var.project_name}-silver-consolidation-${var.environment}"
  description = "ETL Job for Silver layer consolidation with Upsert/deduplication logic. Replaces Lambda-based cleansing function."
  role_arn    = aws_iam_role.glue_job.arn
  glue_version = var.glue_version

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.id}/${aws_s3_object.silver_consolidation_script.key}"
    python_version  = "3"
  }

  # Job execution configuration
  max_retries      = var.glue_job_max_retries
  timeout          = var.glue_job_timeout_minutes
  worker_type      = var.glue_worker_type
  number_of_workers = var.glue_number_of_workers

  # Default arguments for the Glue Job
  default_arguments = {
    # Enable Job Bookmarks for incremental processing
    "--job-bookmark-option" = "job-bookmark-enable"

    # Enable Glue Data Catalog
    "--enable-glue-datacatalog" = "true"

    # Enable CloudWatch metrics and logs
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"                  = "true"

    # Spark configuration for Dynamic Partition Overwrite
    "--conf" = "spark.sql.sources.partitionOverwriteMode=dynamic"

    # Temporary directory
    "--TempDir" = "s3://${aws_s3_bucket.glue_temp.id}/temp/"

    # Custom parameters for the PySpark script
    "--bronze_database"  = aws_glue_catalog_database.data_lake_database.name
    "--bronze_table"     = var.bronze_table_name
    "--silver_database"  = aws_glue_catalog_database.data_lake_database.name
    "--silver_table"     = var.silver_table_name
    "--silver_bucket"    = aws_s3_bucket.data_lake["silver"].id
    "--silver_path"      = var.silver_path

    # Additional Spark configurations
    "--enable-auto-scaling" = "true"
  }

  execution_property {
    max_concurrent_runs = var.glue_max_concurrent_runs
  }

  tags = {
    Name        = "${var.project_name}-silver-consolidation-${var.environment}"
    Layer       = "silver"
    Type        = "consolidation"
    Replacement = "cleansing-lambda"
  }

  depends_on = [
    aws_s3_object.silver_consolidation_script,
    aws_iam_role_policy.glue_job_s3_access,
    aws_iam_role_policy.glue_job_catalog_access,
    aws_iam_role_policy.glue_job_cloudwatch_logs
  ]
}

# ============================================
# AWS Glue Trigger - Scheduled Execution
# ============================================
# DEPRECATED: This trigger has been replaced by AWS Glue Workflow orchestration
# See glue_workflow.tf for the new orchestration approach (Job → Crawler sequence)
# Keeping this resource commented out as backup. To use old approach, uncomment and disable workflow.
# Migration Date: 2025-10-30
# Reason: Eliminate manual Crawler execution, reduce Athena catalog update latency

/*
resource "aws_glue_trigger" "silver_consolidation_schedule" {
  name        = "${var.project_name}-silver-consolidation-trigger-${var.environment}"
  description = "Scheduled trigger for Silver layer consolidation job"
  type        = "SCHEDULED"
  schedule    = var.glue_trigger_schedule
  enabled     = var.glue_trigger_enabled

  actions {
    job_name = aws_glue_job.silver_consolidation.name

    # Optional: Override job arguments for this trigger
    # arguments = {
    #   "--additional_parameter" = "value"
    # }
  }

  tags = {
    Name    = "${var.project_name}-silver-consolidation-trigger-${var.environment}"
    Type    = "scheduled"
    JobName = aws_glue_job.silver_consolidation.name
  }

  depends_on = [aws_glue_job.silver_consolidation]
}
*/

# ============================================
# CloudWatch Log Group for Glue Job
# ============================================

resource "aws_cloudwatch_log_group" "glue_job_logs" {
  name              = "/aws-glue/jobs/${aws_glue_job.silver_consolidation.name}"
  retention_in_days = var.cloudwatch_log_retention_days

  tags = {
    Name   = "${var.project_name}-glue-job-logs-${var.environment}"
    JobName = aws_glue_job.silver_consolidation.name
  }
}

# ============================================
# Outputs
# ============================================

output "glue_job_name" {
  description = "Name of the Glue Job for Silver consolidation"
  value       = aws_glue_job.silver_consolidation.name
}

output "glue_job_arn" {
  description = "ARN of the Glue Job for Silver consolidation"
  value       = aws_glue_job.silver_consolidation.arn
}

# DEPRECATED OUTPUT: Old scheduled trigger replaced by Workflow (see glue_workflow.tf)
# Uncomment if reverting to standalone trigger approach
/*
output "glue_trigger_name" {
  description = "Name of the Glue Trigger"
  value       = aws_glue_trigger.silver_consolidation_schedule.name
}
*/

output "glue_scripts_bucket" {
  description = "S3 bucket for Glue scripts"
  value       = aws_s3_bucket.glue_scripts.id
}

output "glue_job_role_arn" {
  description = "IAM Role ARN for Glue Job"
  value       = aws_iam_role.glue_job.arn
}
