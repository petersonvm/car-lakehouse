# ============================================================================
# AWS Glue Configuration - Data Catalog and Crawler
# ============================================================================

# Glue Database for the Data Catalog
resource "aws_glue_catalog_database" "data_lake_database" {
  name        = "${var.project_name}-catalog-${var.environment}"
  description = "Glue Data Catalog database for ${var.project_name} lakehouse architecture"

  tags = merge(
    local.common_tags,
    {
      Name        = "${var.project_name}-catalog-${var.environment}"
      Component   = "data-catalog"
      ManagedBy   = "terraform"
    }
  )
}

# IAM Role for Glue Crawler
resource "aws_iam_role" "glue_crawler_role" {
  name               = "${var.project_name}-glue-crawler-role-${var.environment}"
  description        = "IAM role for Glue Crawler to access S3 and Glue Catalog"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.project_name}-glue-crawler-role-${var.environment}"
      Component = "glue-crawler"
    }
  )
}

# Assume Role Policy for Glue Service
data "aws_iam_policy_document" "glue_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

# IAM Policy for Glue Crawler - S3 Access
data "aws_iam_policy_document" "glue_s3_access" {
  # Read access to bronze bucket (Parquet data)
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

  # Read access to silver bucket
  statement {
    sid    = "ReadSilverBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.data_lake["silver"].arn,
      "${aws_s3_bucket.data_lake["silver"].arn}/*"
    ]
  }

  # Read access to gold bucket
  statement {
    sid    = "ReadGoldBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.data_lake["gold"].arn,
      "${aws_s3_bucket.data_lake["gold"].arn}/*"
    ]
  }
}

# IAM Policy for Glue Crawler - Glue Catalog Access
data "aws_iam_policy_document" "glue_catalog_access" {
  statement {
    sid    = "GlueCatalogAccess"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetTable",
      "glue:GetTables",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:DeleteTable",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:BatchGetPartition",
      "glue:CreatePartition",
      "glue:UpdatePartition",
      "glue:DeletePartition",
      "glue:BatchCreatePartition",
      "glue:BatchDeletePartition",
      "glue:BatchUpdatePartition"
    ]
    resources = [
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.data_lake_database.name}",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.data_lake_database.name}/*"
    ]
  }
}

# CloudWatch Logs access for Glue
data "aws_iam_policy_document" "glue_cloudwatch_logs" {
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

# Attach S3 Access Policy
resource "aws_iam_role_policy" "glue_s3_policy" {
  name   = "${var.project_name}-glue-s3-access-${var.environment}"
  role   = aws_iam_role.glue_crawler_role.id
  policy = data.aws_iam_policy_document.glue_s3_access.json
}

# Attach Glue Catalog Policy
resource "aws_iam_role_policy" "glue_catalog_policy" {
  name   = "${var.project_name}-glue-catalog-access-${var.environment}"
  role   = aws_iam_role.glue_crawler_role.id
  policy = data.aws_iam_policy_document.glue_catalog_access.json
}

# Attach CloudWatch Logs Policy
resource "aws_iam_role_policy" "glue_cloudwatch_policy" {
  name   = "${var.project_name}-glue-cloudwatch-access-${var.environment}"
  role   = aws_iam_role.glue_crawler_role.id
  policy = data.aws_iam_policy_document.glue_cloudwatch_logs.json
}

# ============================================================================
# Glue Crawler for Bronze Layer - car_data
# ============================================================================
# This crawler discovers partitioned Parquet files with nested structures (structs)
# from the ingestion Lambda. It preserves the original JSON structure as 
# Parquet struct columns, making Bronze the "Source of Truth" (Fonte da Verdade).

resource "aws_glue_crawler" "bronze_car_data_crawler" {
  name          = "${var.project_name}-bronze-car-data-crawler-${var.environment}"
  description   = "Crawler for Bronze layer car_data with nested structures (structs). Discovers partitioned Parquet files with preserved JSON schemas. Uses existing table 'car_bronze'."
  role          = aws_iam_role.glue_crawler_role.arn
  database_name = aws_glue_catalog_database.data_lake_database.name
  table_prefix  = "bronze_"  # Prefix to create 'bronze_car_data' table (prevents 'car_data' duplication)
  
  # IMPORTANT: Crawler behavior with table_prefix = ""
  # - Crawler infers table name from S3 path: s3://.../bronze/car_data/ → "car_data"
  # - If table "car_bronze" already exists in catalog, crawler will UPDATE it (not create new)
  # - To prevent duplicate table creation:
  #   1. Ensure 'car_bronze' table exists before crawler runs
  #   2. Manually delete any 'car_data' table created by previous crawler runs
  #   3. Crawler will then update only 'car_bronze'
  #
  # The table 'car_bronze' must exist before the first crawler run.
  # It's created manually or via separate Terraform resource with:
  # - Name: car_bronze
  # - Schema: Parquet schema with nested structs (vehicle_static_info, vehicle_dynamic_state, etc.)
  # - Partition keys: ingest_year, ingest_month, ingest_day
  # - Location: s3://<bronze-bucket>/bronze/car_data/

  # Schedule - runs daily at midnight UTC to discover new partitions
  schedule = var.bronze_crawler_schedule

  # Target S3 path - Bronze bucket car_data with HIVE-style partitioning
  # Path: s3://bucket/bronze/car_data/ingest_year=YYYY/ingest_month=MM/ingest_day=DD/
  s3_target {
    path = "s3://${aws_s3_bucket.data_lake["bronze"].id}/bronze/car_data/"
    
    # Exclusions - ignore temporary files and metadata
    exclusions = [
      "**/_temporary/**",
      "**/_SUCCESS",
      "**/.spark*"
    ]
  }

  # Schema change policy - handle struct columns and schema evolution
  schema_change_policy {
    # LOG: Log deletions but don't remove tables from catalog
    delete_behavior = "LOG"
    
    # UPDATE_IN_DATABASE: Update schema when structs or columns change
    # Critical for nested structures - allows adding new fields to structs
    update_behavior = "UPDATE_IN_DATABASE"
  }

  # Recrawl policy - always crawl everything to detect schema changes
  recrawl_policy {
    recrawl_behavior = "CRAWL_EVERYTHING"
  }

  # CONFIGURATION REMOVED: Crawler will use default behavior
  # Default behavior should create/update car_bronze table only (not partition-level tables)
  # The explicit table_prefix = "" above ensures no prefix is added

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.project_name}-bronze-car-data-crawler-${var.environment}"
      Component = "glue-crawler"
      Layer     = "bronze"
      DataType  = "car-data"
    }
  )
}

# Glue Crawler for Silver Layer
resource "aws_glue_crawler" "silver_crawler" {
  name          = "${var.project_name}-silver-crawler-${var.environment}"
  description   = "Crawler for Silver layer flattened Parquet files - Partitioned by event date (event_year/event_month/event_day)"
  role          = aws_iam_role.glue_crawler_role.arn
  database_name = aws_glue_catalog_database.data_lake_database.name
  table_prefix  = "silver_"

  # Schedule - runs daily at 01:00 UTC
  schedule = var.silver_crawler_schedule

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake["silver"].id}/car_telemetry/"
    
    # Exclude temporary Spark files and metadata
    exclusions = [
      "**/_temporary/**",
      "**/_SUCCESS",
      "**/.spark*"
    ]
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  recrawl_policy {
    recrawl_behavior = "CRAWL_EVERYTHING"
  }

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = {
        AddOrUpdateBehavior = "InheritFromTable"
      }
      Tables = {
        AddOrUpdateBehavior = "MergeNewColumns"
      }
    }
    Grouping = {
      TableGroupingPolicy = "CombineCompatibleSchemas"
    }
  })

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.project_name}-silver-crawler-${var.environment}"
      Component = "glue-crawler"
      Layer     = "silver"
      Purpose   = "Catalog flattened car telemetry data with event-based partitions"
    }
  )
}

# Glue Crawler for Gold Layer (analytics-ready data)
resource "aws_glue_crawler" "gold_crawler" {
  name          = "${var.project_name}-gold-crawler-${var.environment}"
  description   = "Crawler for Gold layer analytics-ready data"
  role          = aws_iam_role.glue_crawler_role.arn
  database_name = aws_glue_catalog_database.data_lake_database.name

  # Schedule (optional) - runs daily at midnight UTC if configured
  schedule = var.glue_crawler_schedule != "" ? var.glue_crawler_schedule : null

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake["gold"].id}/gold/"
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "LOG"
  }

  recrawl_policy {
    recrawl_behavior = "CRAWL_NEW_FOLDERS_ONLY"
  }

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = {
        AddOrUpdateBehavior = "InheritFromTable"
      }
      Tables = {
        AddOrUpdateBehavior = "MergeNewColumns"
      }
    }
    Grouping = {
      TableGroupingPolicy = "CombineCompatibleSchemas"
    }
  })

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.project_name}-gold-crawler-${var.environment}"
      Component = "glue-crawler"
      Layer     = "gold"
    }
  )
}

# Get current AWS account ID
data "aws_caller_identity" "current" {}
