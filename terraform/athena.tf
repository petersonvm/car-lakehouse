# ============================================================================
# Amazon Athena Configuration - Query Engine
# ============================================================================

# S3 Bucket for Athena Query Results
resource "aws_s3_bucket" "athena_results" {
  bucket = "${var.project_name}-athena-results-${var.environment}"

  tags = merge(
    local.common_tags,
    {
      Name        = "${var.project_name}-athena-results-${var.environment}"
      Component   = "athena-results"
      Purpose     = "Store Athena query results and metadata"
    }
  )
}

# Enable versioning for Athena results bucket
resource "aws_s3_bucket_versioning" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Server-side encryption for Athena results
resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block public access for Athena results bucket
resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle policy for Athena results (cleanup old queries)
resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    id     = "cleanup-old-query-results"
    status = "Enabled"

    filter {
      prefix = "query-results/"
    }

    # Delete query results older than 30 days
    expiration {
      days = 30
    }

    # Clean up incomplete multipart uploads
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Athena Workgroup for Data Lake queries
resource "aws_athena_workgroup" "data_lake" {
  name        = "${var.project_name}-workgroup-${var.environment}"
  description = "Athena workgroup for ${var.project_name} lakehouse queries"
  state       = "ENABLED"

  configuration {
    # Output location for query results
    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.id}/query-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }

    # Enforce workgroup configuration
    enforce_workgroup_configuration = true

    # Publish CloudWatch metrics
    publish_cloudwatch_metrics_enabled = true

    # Query execution settings
    bytes_scanned_cutoff_per_query = var.athena_bytes_scanned_cutoff
    
    engine_version {
      selected_engine_version = "AUTO"
    }
  }

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.project_name}-workgroup-${var.environment}"
      Component = "athena-workgroup"
    }
  )
}

# IAM Role for Athena query execution (optional - for service integration)
resource "aws_iam_role" "athena_execution_role" {
  name               = "${var.project_name}-athena-execution-role-${var.environment}"
  description        = "IAM role for Athena query execution with Data Lake access"
  assume_role_policy = data.aws_iam_policy_document.athena_assume_role.json

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.project_name}-athena-execution-role-${var.environment}"
      Component = "athena"
    }
  )
}

# Assume Role Policy for Athena
data "aws_iam_policy_document" "athena_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type = "Service"
      identifiers = [
        "athena.amazonaws.com"
      ]
    }
    actions = ["sts:AssumeRole"]
  }

  # Allow users to assume this role
  statement {
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions = ["sts:AssumeRole"]
  }
}

# IAM Policy for Athena - S3 Data Lake Access
data "aws_iam_policy_document" "athena_s3_access" {
  # Read access to Data Lake buckets
  statement {
    sid    = "ReadDataLakeBuckets"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]
    resources = [
      aws_s3_bucket.data_lake["bronze"].arn,
      "${aws_s3_bucket.data_lake["bronze"].arn}/*",
      aws_s3_bucket.data_lake["silver"].arn,
      "${aws_s3_bucket.data_lake["silver"].arn}/*",
      aws_s3_bucket.data_lake["gold"].arn,
      "${aws_s3_bucket.data_lake["gold"].arn}/*"
    ]
  }

  # Write access to Athena results bucket
  statement {
    sid    = "WriteAthenaResults"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:DeleteObject",
      "s3:GetBucketLocation"
    ]
    resources = [
      aws_s3_bucket.athena_results.arn,
      "${aws_s3_bucket.athena_results.arn}/*"
    ]
  }
}

# IAM Policy for Athena - Glue Catalog Access
data "aws_iam_policy_document" "athena_glue_access" {
  statement {
    sid    = "GlueCatalogReadAccess"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:BatchGetPartition"
    ]
    resources = [
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.data_lake_database.name}",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.data_lake_database.name}/*"
    ]
  }
}

# IAM Policy for Athena - Athena Service Access
data "aws_iam_policy_document" "athena_service_access" {
  statement {
    sid    = "AthenaQueryExecution"
    effect = "Allow"
    actions = [
      "athena:StartQueryExecution",
      "athena:StopQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:GetWorkGroup",
      "athena:ListWorkGroups",
      "athena:ListQueryExecutions"
    ]
    resources = [
      aws_athena_workgroup.data_lake.arn
    ]
  }
}

# Attach S3 Access Policy to Athena Role
resource "aws_iam_role_policy" "athena_s3_policy" {
  name   = "${var.project_name}-athena-s3-access-${var.environment}"
  role   = aws_iam_role.athena_execution_role.id
  policy = data.aws_iam_policy_document.athena_s3_access.json
}

# Attach Glue Catalog Policy to Athena Role
resource "aws_iam_role_policy" "athena_glue_policy" {
  name   = "${var.project_name}-athena-glue-access-${var.environment}"
  role   = aws_iam_role.athena_execution_role.id
  policy = data.aws_iam_policy_document.athena_glue_access.json
}

# Attach Athena Service Policy to Athena Role
resource "aws_iam_role_policy" "athena_service_policy" {
  name   = "${var.project_name}-athena-service-access-${var.environment}"
  role   = aws_iam_role.athena_execution_role.id
  policy = data.aws_iam_policy_document.athena_service_access.json
}
