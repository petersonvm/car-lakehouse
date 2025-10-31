# ============================================================
# GOLD FUEL EFFICIENCY PIPELINE - MONTHLY AGGREGATIONS (KPI 1)
# ============================================================
# PURPOSE:
#   Infrastructure for third parallel Gold pipeline that calculates
#   monthly fuel efficiency aggregations from Silver telemetry data.
#
# PIPELINE FLOW:
#   Silver Crawler SUCCEEDED → [3 Gold Jobs in PARALLEL]
#   ├─→ Gold Current State Job → Current State Crawler
#   ├─→ Gold Performance Alerts Job → Alerts Crawler
#   └─→ Gold Fuel Efficiency Job (NEW!) → Fuel Efficiency Crawler (NEW!)
#
# RESOURCES CREATED:
#   - 2 IAM Roles (Job + Crawler)
#   - 8 IAM Policies (granular permissions)
#   - 1 Glue Job (aggregation logic)
#   - 1 Glue Crawler (catalog results)
#   - 1 CloudWatch Log Group
#   - 1 S3 Script Upload
#   - 1 Conditional Trigger (Job → Crawler)
#
# INCREMENTAL PATTERN:
#   Job uses bookmarks to read only NEW Silver data, merges with
#   existing Gold aggregations, and overwrites with updated totals.
# ============================================================

# ============================================================
# 1. IAM ROLE - GOLD FUEL EFFICIENCY JOB
# ============================================================

resource "aws_iam_role" "gold_fuel_job_role" {
  name               = "${var.project_name}-gold-fuel-efficiency-job-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json

  tags = {
    Name  = "${var.project_name}-gold-fuel-efficiency-job-role"
    Layer = "Gold"
    Type  = "Aggregation-KPI"
  }
}

# ============================================================
# 2. IAM POLICIES - GOLD FUEL EFFICIENCY JOB
# ============================================================

# Policy 1: Glue Catalog Access
resource "aws_iam_role_policy" "gold_fuel_job_catalog" {
  name = "gold-fuel-job-catalog-access"
  role = aws_iam_role.gold_fuel_job_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartitions",
          "glue:GetPartition",
          "glue:BatchGetPartition",
          "glue:CreateTable",
          "glue:UpdateTable",
          "glue:BatchCreatePartition"
        ]
        Resource = [
          "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/default",
          "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.data_lake_database.name}",
          "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.data_lake_database.name}/*"
        ]
      }
    ]
  })
}

# Policy 2: S3 Read Access (Silver Layer)
resource "aws_iam_role_policy" "gold_fuel_job_read_silver" {
  name = "gold-fuel-job-read-silver"
  role = aws_iam_role.gold_fuel_job_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "${aws_s3_bucket.data_lake["silver"].arn}",
          "${aws_s3_bucket.data_lake["silver"].arn}/*"
        ]
      }
    ]
  })
}

# Policy 3: S3 Read/Write Access (Gold Layer - fuel_efficiency_monthly)
resource "aws_iam_role_policy" "gold_fuel_job_rw_gold" {
  name = "gold-fuel-job-readwrite-gold"
  role = aws_iam_role.gold_fuel_job_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "${aws_s3_bucket.data_lake["gold"].arn}",
          "${aws_s3_bucket.data_lake["gold"].arn}/fuel_efficiency_monthly/*"
        ]
      }
    ]
  })
}

# Policy 4: CloudWatch Logs
resource "aws_iam_role_policy" "gold_fuel_job_cloudwatch" {
  name = "gold-fuel-job-cloudwatch-logs"
  role = aws_iam_role.gold_fuel_job_role.id

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
        Resource = [
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws-glue/jobs/*"
        ]
      }
    ]
  })
}

# Policy 5: S3 Scripts Access
resource "aws_iam_role_policy" "gold_fuel_job_scripts" {
  name = "gold-fuel-job-scripts-access"
  role = aws_iam_role.gold_fuel_job_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "${aws_s3_bucket.glue_scripts.arn}",
          "${aws_s3_bucket.glue_scripts.arn}/*"
        ]
      }
    ]
  })
}

# ============================================================
# 3. CLOUDWATCH LOG GROUP
# ============================================================

resource "aws_cloudwatch_log_group" "gold_fuel_job_logs" {
  name              = "/aws-glue/jobs/${var.project_name}-gold-fuel-efficiency-${var.environment}"
  retention_in_days = 14

  tags = {
    Name  = "${var.project_name}-gold-fuel-efficiency-job-logs"
    Layer = "Gold"
  }
}

# ============================================================
# 4. S3 SCRIPT UPLOAD
# ============================================================

resource "aws_s3_object" "gold_fuel_script" {
  bucket = aws_s3_bucket.glue_scripts.id
  key    = "glue_jobs/gold_fuel_efficiency_job.py"
  source = "${path.module}/../glue_jobs/gold_fuel_efficiency_job.py"
  etag   = filemd5("${path.module}/../glue_jobs/gold_fuel_efficiency_job.py")

  tags = {
    Name  = "gold-fuel-efficiency-script"
    Layer = "Gold"
  }
}

# ============================================================
# 5. AWS GLUE JOB - FUEL EFFICIENCY AGGREGATION
# ============================================================

resource "aws_glue_job" "gold_fuel_efficiency" {
  name              = "${var.project_name}-gold-fuel-efficiency-${var.environment}"
  role_arn          = aws_iam_role.gold_fuel_job_role.arn
  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = 60

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.id}/${aws_s3_object.gold_fuel_script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--job-bookmark-option"              = "job-bookmark-enable"
    "--enable-metrics"                   = "true"
    "--enable-spark-ui"                  = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-continuous-log-filter"     = "true"
    "--enable-glue-datacatalog"          = "true"
    "--TempDir"                          = "s3://${aws_s3_bucket.glue_temp.id}/temp/"
    "--gold_bucket"                      = aws_s3_bucket.data_lake["gold"].id
    "--glue_database"                    = aws_glue_catalog_database.data_lake_database.name
  }

  execution_property {
    max_concurrent_runs = 1
  }

  tags = {
    Name  = "${var.project_name}-gold-fuel-efficiency-job"
    Layer = "Gold"
    Type  = "Aggregation-KPI"
  }

  depends_on = [
    aws_s3_object.gold_fuel_script,
    aws_cloudwatch_log_group.gold_fuel_job_logs
  ]
}

# ============================================================
# 6. IAM ROLE - GOLD FUEL EFFICIENCY CRAWLER
# ============================================================

resource "aws_iam_role" "gold_fuel_crawler_role" {
  name               = "${var.project_name}-gold-fuel-crawler-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json

  tags = {
    Name  = "${var.project_name}-gold-fuel-crawler-role"
    Layer = "Gold"
    Type  = "Aggregation-KPI"
  }
}

# ============================================================
# 7. IAM POLICIES - GOLD FUEL EFFICIENCY CRAWLER
# ============================================================

# Policy 1: S3 Read Access (fuel_efficiency_monthly)
resource "aws_iam_role_policy" "gold_fuel_crawler_s3" {
  name = "gold-fuel-crawler-s3-access"
  role = aws_iam_role.gold_fuel_crawler_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "${aws_s3_bucket.data_lake["gold"].arn}",
          "${aws_s3_bucket.data_lake["gold"].arn}/fuel_efficiency_monthly/*"
        ]
      }
    ]
  })
}

# Policy 2: Glue Catalog Write Access
resource "aws_iam_role_policy" "gold_fuel_crawler_catalog" {
  name = "gold-fuel-crawler-catalog-access"
  role = aws_iam_role.gold_fuel_crawler_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:CreateTable",
          "glue:UpdateTable",
          "glue:GetTable",
          "glue:GetPartitions",
          "glue:GetPartition",
          "glue:BatchGetPartition",
          "glue:CreatePartition",
          "glue:UpdatePartition",
          "glue:BatchCreatePartition"
        ]
        Resource = [
          "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.data_lake_database.name}",
          "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.data_lake_database.name}/*"
        ]
      }
    ]
  })
}

# Policy 3: CloudWatch Logs
resource "aws_iam_role_policy" "gold_fuel_crawler_cloudwatch" {
  name = "gold-fuel-crawler-cloudwatch-logs"
  role = aws_iam_role.gold_fuel_crawler_role.id

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
        Resource = [
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws-glue/crawlers:*"
        ]
      }
    ]
  })
}

# ============================================================
# 8. AWS GLUE CRAWLER - FUEL EFFICIENCY MONTHLY
# ============================================================

resource "aws_glue_crawler" "gold_fuel_efficiency" {
  database_name = aws_glue_catalog_database.data_lake_database.name
  name          = "${var.project_name}-gold-fuel-efficiency-crawler-${var.environment}"
  role          = aws_iam_role.gold_fuel_crawler_role.arn

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake["gold"].id}/fuel_efficiency_monthly/"
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
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
  })

  tags = {
    Name  = "${var.project_name}-gold-fuel-efficiency-crawler"
    Layer = "Gold"
    Type  = "Aggregation-KPI"
  }
}

# ============================================================
# 9. CONDITIONAL TRIGGER - FUEL JOB → FUEL CRAWLER
# ============================================================

resource "aws_glue_trigger" "gold_fuel_job_succeeded_start_crawler" {
  name          = "${var.project_name}-gold-fuel-job-succeeded-start-crawler-${var.environment}"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.silver_etl_workflow.name
  description   = "Trigger condicional: Quando Gold Fuel Efficiency Job SUCCEEDED, inicia Gold Fuel Efficiency Crawler automaticamente"

  actions {
    crawler_name = aws_glue_crawler.gold_fuel_efficiency.name
  }

  predicate {
    logical = "AND"

    conditions {
      job_name         = aws_glue_job.gold_fuel_efficiency.name
      state            = "SUCCEEDED"
      logical_operator = "EQUALS"
    }
  }

  tags = {
    Name     = "${var.project_name}-gold-fuel-job-succeeded-trigger"
    Workflow = aws_glue_workflow.silver_etl_workflow.name
  }
}

# ============================================================
# 10. OUTPUTS - FUEL EFFICIENCY PIPELINE
# ============================================================

output "gold_fuel_efficiency_job_name" {
  description = "Nome do Glue Job de Eficiência de Combustível"
  value       = aws_glue_job.gold_fuel_efficiency.name
}

output "gold_fuel_efficiency_crawler_name" {
  description = "Nome do Crawler de Eficiência de Combustível"
  value       = aws_glue_crawler.gold_fuel_efficiency.name
}

output "gold_fuel_efficiency_s3_path" {
  description = "Caminho S3 das agregações de eficiência"
  value       = "s3://${aws_s3_bucket.data_lake["gold"].id}/fuel_efficiency_monthly/"
}

output "gold_fuel_efficiency_table_name" {
  description = "Nome da tabela Gold de eficiência mensal"
  value       = "gold_fuel_efficiency_monthly"
}
