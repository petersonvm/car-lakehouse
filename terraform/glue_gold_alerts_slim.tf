/**
 * ═══════════════════════════════════════════════════════════════════════════
 * TERRAFORM: Gold Performance Alerts - SLIM Pipeline (Optimized)
 * ═══════════════════════════════════════════════════════════════════════════
 * 
 * 📋 DESCRIÇÃO:
 *    Infraestrutura completa para o pipeline OTIMIZADO de alertas de performance.
 *    
 *    **ESTRATÉGIA DE SUBSTITUIÇÃO:**
 *    1. Criar novos recursos (Job, Crawler, Trigger) para pipeline "slim"
 *    2. Atualizar workflow trigger para usar novo job
 *    3. Deprecar recursos antigos (comentados para posterior remoção)
 * 
 * 🎯 OTIMIZAÇÕES:
 *    - ✅ Tabela com apenas 7 colunas (vs 36 do antigo)
 *    - ✅ Redução de ~80% no armazenamento
 *    - ✅ Queries mais rápidas (menos colunas)
 *    - ✅ Custos de S3 e Athena reduzidos
 * 
 * 📦 RECURSOS CRIADOS:
 *    - IAM Role (Job)
 *    - IAM Role (Crawler)
 *    - IAM Policies (5x para Job, 3x para Crawler)
 *    - Glue Job (slim)
 *    - Glue Crawler (slim)
 *    - Glue Trigger (conditional)
 *    - S3 Script Upload
 *    - CloudWatch Log Group
 * 
 * ═══════════════════════════════════════════════════════════════════════════
 */

# ============================================================================
# 1. IAM ROLE - GLUE JOB (Performance Alerts Slim)
# ============================================================================

resource "aws_iam_role" "gold_alerts_slim_job_role" {
  name = "${var.project_name}-gold-alerts-slim-job-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name  = "${var.project_name}-gold-alerts-slim-job-role"
    Layer = "Gold"
    Type  = "Slim-Optimized"
  }
}

# Policy 1: Glue Catalog Access
resource "aws_iam_role_policy" "gold_alerts_slim_job_catalog" {
  name = "gold-alerts-slim-job-catalog-access"
  role = aws_iam_role.gold_alerts_slim_job_role.id

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
resource "aws_iam_role_policy" "gold_alerts_slim_job_read_silver" {
  name = "gold-alerts-slim-job-read-silver"
  role = aws_iam_role.gold_alerts_slim_job_role.id

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

# Policy 3: S3 Write Access (Gold Alerts Slim Path)
resource "aws_iam_role_policy" "gold_alerts_slim_job_write_gold" {
  name = "gold-alerts-slim-job-write-gold"
  role = aws_iam_role.gold_alerts_slim_job_role.id

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
          "${aws_s3_bucket.data_lake["gold"].arn}/performance_alerts_log_slim/*"
        ]
      }
    ]
  })
}

# Policy 4: CloudWatch Logs
resource "aws_iam_role_policy" "gold_alerts_slim_job_cloudwatch" {
  name = "gold-alerts-slim-job-cloudwatch-logs"
  role = aws_iam_role.gold_alerts_slim_job_role.id

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

# Policy 5: Scripts Bucket Access
resource "aws_iam_role_policy" "gold_alerts_slim_job_scripts" {
  name = "gold-alerts-slim-job-scripts-access"
  role = aws_iam_role.gold_alerts_slim_job_role.id

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

# ============================================================================
# 2. CLOUDWATCH LOG GROUP
# ============================================================================

resource "aws_cloudwatch_log_group" "gold_alerts_slim_job_logs" {
  name              = "/aws-glue/jobs/${var.project_name}-gold-performance-alerts-slim-${var.environment}"
  retention_in_days = 14

  tags = {
    Name  = "${var.project_name}-gold-alerts-slim-job-logs"
    Layer = "Gold"
  }
}

# ============================================================================
# 3. S3 SCRIPT UPLOAD
# ============================================================================

resource "aws_s3_object" "gold_alerts_slim_script" {
  bucket = aws_s3_bucket.glue_scripts.id
  key    = "glue_jobs/gold_performance_alerts_slim_job.py"
  source = "${path.module}/../glue_jobs/gold_performance_alerts_slim_job.py"
  etag   = filemd5("${path.module}/../glue_jobs/gold_performance_alerts_slim_job.py")

  tags = {
    Name  = "gold-performance-alerts-slim-script"
    Layer = "Gold"
  }
}

# ============================================================================
# 4. GLUE JOB (Performance Alerts Slim)
# ============================================================================

resource "aws_glue_job" "gold_performance_alerts_slim" {
  name              = "${var.project_name}-gold-performance-alerts-slim-${var.environment}"
  role_arn          = aws_iam_role.gold_alerts_slim_job_role.arn
  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = 60

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.id}/${aws_s3_object.gold_alerts_slim_script.key}"
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
    "--glue_database"                    = aws_glue_catalog_database.data_lake_database.name
    "--gold_bucket"                      = aws_s3_bucket.data_lake["gold"].id
    "--database_name"                    = aws_glue_catalog_database.data_lake_database.name  # Novo argumento
    "--silver_table_name"                = var.silver_table_name  # Novo argumento
    "--gold_path"                        = "s3://${aws_s3_bucket.data_lake["gold"].id}/performance_alerts_log_slim/"  # Novo argumento
  }

  execution_property {
    max_concurrent_runs = 1
  }

  tags = {
    Name  = "${var.project_name}-gold-performance-alerts-slim-job"
    Layer = "Gold"
    Type  = "Slim-Optimized"
  }
}

# ============================================================================
# 5. IAM ROLE - GLUE CRAWLER (Performance Alerts Slim)
# ============================================================================

resource "aws_iam_role" "gold_alerts_slim_crawler_role" {
  name = "${var.project_name}-gold-alerts-slim-crawler-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name  = "${var.project_name}-gold-alerts-slim-crawler-role"
    Layer = "Gold"
    Type  = "Slim-Optimized"
  }
}

# Crawler Policy 1: S3 Read Access
resource "aws_iam_role_policy" "gold_alerts_slim_crawler_s3" {
  name = "gold-alerts-slim-crawler-s3-access"
  role = aws_iam_role.gold_alerts_slim_crawler_role.id

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
          "${aws_s3_bucket.data_lake["gold"].arn}/performance_alerts_log_slim/*"
        ]
      }
    ]
  })
}

# Crawler Policy 2: Glue Catalog Access
resource "aws_iam_role_policy" "gold_alerts_slim_crawler_catalog" {
  name = "gold-alerts-slim-crawler-catalog-access"
  role = aws_iam_role.gold_alerts_slim_crawler_role.id

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

# Crawler Policy 3: CloudWatch Logs
resource "aws_iam_role_policy" "gold_alerts_slim_crawler_cloudwatch" {
  name = "gold-alerts-slim-crawler-cloudwatch-logs"
  role = aws_iam_role.gold_alerts_slim_crawler_role.id

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

# ============================================================================
# 6. GLUE CRAWLER (Performance Alerts Slim)
# ============================================================================

resource "aws_glue_crawler" "gold_performance_alerts_slim" {
  name          = "${var.project_name}-gold-performance-alerts-slim-crawler-${var.environment}"
  role          = aws_iam_role.gold_alerts_slim_crawler_role.arn
  database_name = aws_glue_catalog_database.data_lake_database.name

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake["gold"].id}/performance_alerts_log_slim/"
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
    Name  = "${var.project_name}-gold-performance-alerts-slim-crawler"
    Layer = "Gold"
    Type  = "Slim-Optimized"
  }
}

# ============================================================================
# 7. GLUE TRIGGER - Conditional (Job Succeeded → Start Crawler)
# ============================================================================

resource "aws_glue_trigger" "gold_alerts_slim_job_succeeded_start_crawler" {
  name          = "${var.project_name}-gold-alerts-slim-job-succeeded-start-crawler-${var.environment}"
  description   = "Trigger condicional: Quando Gold Alerts Slim Job SUCCEEDED, inicia Crawler automaticamente"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.silver_gold_pipeline.name
  enabled       = true

  actions {
    crawler_name = aws_glue_crawler.gold_performance_alerts_slim.name
  }

  predicate {
    logical = "AND"

    conditions {
      job_name         = aws_glue_job.gold_performance_alerts_slim.name
      state            = "SUCCEEDED"
      logical_operator = "EQUALS"
    }
  }

  tags = {
    Name     = "${var.project_name}-gold-alerts-slim-job-succeeded-trigger"
    Workflow = aws_glue_workflow.silver_gold_pipeline.name
  }
}

# ============================================================================
# 8. OUTPUTS
# ============================================================================

output "gold_alerts_slim_job_name" {
  description = "Nome do Glue Job (Performance Alerts Slim)"
  value       = aws_glue_job.gold_performance_alerts_slim.name
}

output "gold_alerts_slim_crawler_name" {
  description = "Nome do Glue Crawler (Performance Alerts Slim)"
  value       = aws_glue_crawler.gold_performance_alerts_slim.name
}

output "gold_alerts_slim_s3_path" {
  description = "Caminho S3 da tabela slim"
  value       = "s3://${aws_s3_bucket.data_lake["gold"].id}/performance_alerts_log_slim/"
}

output "gold_alerts_slim_table_name" {
  description = "Nome da tabela no Glue Catalog"
  value       = "performance_alerts_log_slim"
}

# ============================================================================
# 9. DEPRECAÇÃO - Recursos Antigos (Comentados para Posterior Remoção)
# ============================================================================

/**
 * ⚠️  ATENÇÃO: Recursos abaixo devem ser removidos APÓS validação do pipeline slim
 * 
 * Para remover os recursos antigos:
 * 1. Descomentar o bloco null_resource abaixo
 * 2. Executar: terraform apply
 * 3. Os recursos antigos serão destruídos
 * 
 * Recursos a serem removidos:
 * - aws_glue_job.gold_performance_alerts (Job antigo bloated)
 * - aws_glue_crawler.gold_performance_alerts (Crawler antigo)
 * - aws_glue_trigger.gold_alerts_job_succeeded_start_crawler (Trigger antigo)
 * - aws_iam_role.gold_alerts_job_role (Role antigo)
 * - aws_iam_role.gold_alerts_crawler_role (Role antigo)
 */

# resource "null_resource" "cleanup_old_alerts_pipeline" {
#   # Este recurso será executado apenas uma vez para limpar os recursos antigos
#   
#   triggers = {
#     cleanup_timestamp = timestamp()
#   }
#   
#   provisioner "local-exec" {
#     command = <<-EOT
#       echo "🧹 Limpeza dos recursos antigos do pipeline bloated..."
#       echo "   - Job: gold-performance-alerts"
#       echo "   - Crawler: gold-performance-alerts-crawler"
#       echo "   - Trigger: gold-alerts-job-succeeded-start-crawler"
#       echo "   ✅ Use 'terraform state rm' para remover do state"
#     EOT
#   }
# }
