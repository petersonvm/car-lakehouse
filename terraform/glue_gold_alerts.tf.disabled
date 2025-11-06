# ============================================================
# GOLD LAYER - PERFORMANCE ALERTS PIPELINE
# ============================================================
# 
# Novo pipeline para detectar e catalogar alertas de performance
# baseado em KPIs críticos da camada Silver.
#
# Pipeline: Silver → Gold Alerts Job → Gold Alerts Crawler
# 
# Execução: Paralela com gold_car_current_state (ambos triggerados
#           após silver_crawler SUCCEEDED)
# ============================================================

# ============================================================
# 1. IAM ROLE - GOLD ALERTS JOB
# ============================================================

resource "aws_iam_role" "gold_alerts_job_role" {
  name               = "${var.project_name}-gold-alerts-job-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json

  tags = {
    Name = "${var.project_name}-gold-alerts-job-role-${var.environment}"
    Layer = "Gold"
    Type = "Alerts"
  }
}

# ============================================================
# 2. IAM POLICIES - GOLD ALERTS JOB
# ============================================================

# Policy 1: Acesso ao Glue Catalog
resource "aws_iam_role_policy" "gold_alerts_job_catalog_access" {
  name = "gold-alerts-job-catalog-access"
  role = aws_iam_role.gold_alerts_job_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetPartitions",
          "glue:GetPartition",
          "glue:CreateTable",
          "glue:UpdateTable",
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

# Policy 2: Leitura do Silver S3
resource "aws_iam_role_policy" "gold_alerts_job_read_silver" {
  name = "gold-alerts-job-read-silver"
  role = aws_iam_role.gold_alerts_job_role.id

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

# Policy 3: Escrita no Gold S3 (performance_alerts_log)
resource "aws_iam_role_policy" "gold_alerts_job_write_gold" {
  name = "gold-alerts-job-write-gold"
  role = aws_iam_role.gold_alerts_job_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "${aws_s3_bucket.data_lake["gold"].arn}",
          "${aws_s3_bucket.data_lake["gold"].arn}/performance_alerts_log/*"
        ]
      }
    ]
  })
}

# Policy 4: CloudWatch Logs
resource "aws_iam_role_policy" "gold_alerts_job_cloudwatch" {
  name = "gold-alerts-job-cloudwatch-logs"
  role = aws_iam_role.gold_alerts_job_role.id

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

# Policy 5: Acesso aos Scripts S3
resource "aws_iam_role_policy" "gold_alerts_job_scripts" {
  name = "gold-alerts-job-scripts-access"
  role = aws_iam_role.gold_alerts_job_role.id

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
# 3. UPLOAD DO SCRIPT PYSPARK PARA S3
# ============================================================

resource "aws_s3_object" "gold_alerts_script" {
  bucket = aws_s3_bucket.glue_scripts.id
  key    = "glue_jobs/gold_performance_alerts_job.py"
  source = "${path.module}/../glue_jobs/gold_performance_alerts_job.py"
  etag   = filemd5("${path.module}/../glue_jobs/gold_performance_alerts_job.py")

  tags = {
    Name = "gold-performance-alerts-script"
    Layer = "Gold"
  }
}

# ============================================================
# 4. CLOUDWATCH LOG GROUP - GOLD ALERTS JOB
# ============================================================

resource "aws_cloudwatch_log_group" "gold_alerts_job_logs" {
  name              = "/aws-glue/jobs/${var.project_name}-gold-performance-alerts-${var.environment}"
  retention_in_days = 14

  tags = {
    Name = "${var.project_name}-gold-alerts-job-logs"
    Layer = "Gold"
  }
}

# ============================================================
# 5. AWS GLUE JOB - GOLD PERFORMANCE ALERTS
# ============================================================

resource "aws_glue_job" "gold_performance_alerts" {
  name              = "${var.project_name}-gold-performance-alerts-${var.environment}"
  role_arn          = aws_iam_role.gold_alerts_job_role.arn
  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = var.glue_job_timeout_minutes

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.id}/${aws_s3_object.gold_alerts_script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--job-bookmark-option"              = "job-bookmark-enable"
    "--enable-metrics"                   = "true"
    "--enable-spark-ui"                  = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-continuous-log-filter"     = "true"
    "--TempDir"                          = "s3://${aws_s3_bucket.glue_temp.id}/temp/"
    
    # Parâmetros customizados do Job
    "--gold_bucket"                      = aws_s3_bucket.data_lake["gold"].id
    "--glue_database"                    = aws_glue_catalog_database.data_lake_database.name
  }

  execution_property {
    max_concurrent_runs = 1
  }

  tags = {
    Name = "${var.project_name}-gold-performance-alerts-job"
    Layer = "Gold"
    Type = "Alerts"
  }

  depends_on = [
    aws_s3_object.gold_alerts_script,
    aws_cloudwatch_log_group.gold_alerts_job_logs
  ]
}

# ============================================================
# 6. IAM ROLE - GOLD ALERTS CRAWLER
# ============================================================

resource "aws_iam_role" "gold_alerts_crawler_role" {
  name               = "${var.project_name}-gold-alerts-crawler-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json

  tags = {
    Name = "${var.project_name}-gold-alerts-crawler-role"
    Layer = "Gold"
    Type = "Alerts"
  }
}

# ============================================================
# 7. IAM POLICIES - GOLD ALERTS CRAWLER
# ============================================================

# Policy 1: S3 Read Access (performance_alerts_log)
resource "aws_iam_role_policy" "gold_alerts_crawler_s3" {
  name = "gold-alerts-crawler-s3-access"
  role = aws_iam_role.gold_alerts_crawler_role.id

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
          "${aws_s3_bucket.data_lake["gold"].arn}/performance_alerts_log/*"
        ]
      }
    ]
  })
}

# Policy 2: Glue Catalog Write Access
resource "aws_iam_role_policy" "gold_alerts_crawler_catalog" {
  name = "gold-alerts-crawler-catalog-access"
  role = aws_iam_role.gold_alerts_crawler_role.id

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

# Policy 3: CloudWatch Logs (com wildcard para log streams)
resource "aws_iam_role_policy" "gold_alerts_crawler_cloudwatch" {
  name = "gold-alerts-crawler-cloudwatch-logs"
  role = aws_iam_role.gold_alerts_crawler_role.id

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
# 8. AWS GLUE CRAWLER - GOLD PERFORMANCE ALERTS
# ============================================================

resource "aws_glue_crawler" "gold_performance_alerts" {
  name          = "${var.project_name}-gold-performance-alerts-crawler-${var.environment}"
  role          = aws_iam_role.gold_alerts_crawler_role.arn
  database_name = aws_glue_catalog_database.data_lake_database.name
  
  # Tabela de destino no Catalog
  table_prefix = ""

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake["gold"].id}/performance_alerts_log/"
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
    Name = "${var.project_name}-gold-alerts-crawler"
    Layer = "Gold"
    Type = "Alerts"
  }
}

# ============================================================
# 9. TRIGGER - GOLD ALERTS JOB SUCCEEDED → START CRAWLER
# ============================================================

resource "aws_glue_trigger" "gold_alerts_job_succeeded_start_crawler" {
  name          = "${var.project_name}-gold-alerts-job-succeeded-start-crawler-${var.environment}"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.silver_gold_pipeline.name
  description   = "Trigger condicional: Quando Gold Alerts Job SUCCEEDED, inicia Gold Alerts Crawler automaticamente"

  predicate {
    logical = "AND"
    
    conditions {
      job_name         = aws_glue_job.gold_performance_alerts.name
      state            = "SUCCEEDED"
      logical_operator = "EQUALS"
    }
  }

  actions {
    crawler_name = aws_glue_crawler.gold_performance_alerts.name
  }

  tags = {
    Name = "${var.project_name}-gold-alerts-job-succeeded-trigger"
    Workflow = aws_glue_workflow.silver_gold_pipeline.name
  }
}

# ============================================================
# 10. OUTPUTS - GOLD ALERTS PIPELINE
# ============================================================

output "gold_alerts_job_name" {
  description = "Nome do Glue Job de alertas Gold"
  value       = aws_glue_job.gold_performance_alerts.name
}

output "gold_alerts_crawler_name" {
  description = "Nome do Crawler Gold de alertas"
  value       = aws_glue_crawler.gold_performance_alerts.name
}

output "gold_alerts_s3_path" {
  description = "Caminho S3 dos alertas Gold"
  value       = "s3://${aws_s3_bucket.data_lake["gold"].id}/performance_alerts_log/"
}

output "gold_alerts_table_name" {
  description = "Nome da tabela Athena de alertas"
  value       = "gold_performance_alerts_log"
}
