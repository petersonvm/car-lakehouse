# ============================================================================
# AWS GLUE - GOLD LAYER INFRASTRUCTURE
# ============================================================================
# Propósito: Provisionar recursos para a Camada Gold (agregações/snapshots)
# Inclui: IAM Roles, Glue Jobs, Crawlers e Orquestração (Workflow)
# 
# Pipeline Gold:
#   Silver Crawler (SUCCEEDED) → Gold Job → Gold Crawler → Athena
# 
# Autor: Sistema de Data Lakehouse
# Data: 2025-10-30
# ============================================================================

# ============================================================================
# 1. IAM ROLE - GOLD JOB EXECUTION
# ============================================================================

# IAM Role para execução do Glue Job Gold
resource "aws_iam_role" "gold_job_role" {
  name               = "${var.project_name}-gold-job-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json

  tags = {
    Name    = "${var.project_name}-gold-job-role-${var.environment}"
    Layer   = "Gold"
    Purpose = "Glue-Job-Execution"
  }
}

# Policy: Acesso ao Silver Bucket (leitura)
resource "aws_iam_role_policy" "gold_job_read_silver" {
  name = "gold-job-read-silver"
  role = aws_iam_role.gold_job_role.id

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
          aws_s3_bucket.data_lake["silver"].arn,
          "${aws_s3_bucket.data_lake["silver"].arn}/*"
        ]
      }
    ]
  })
}

# Policy: Acesso ao Gold Bucket (leitura, escrita e delete para overwrite)
resource "aws_iam_role_policy" "gold_job_write_gold" {
  name = "gold-job-write-gold"
  role = aws_iam_role.gold_job_role.id

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
          aws_s3_bucket.data_lake["gold"].arn,
          "${aws_s3_bucket.data_lake["gold"].arn}/*"
        ]
      }
    ]
  })
}

# Policy: Acesso ao Glue Data Catalog
resource "aws_iam_role_policy" "gold_job_catalog_access" {
  name = "gold-job-catalog-access"
  role = aws_iam_role.gold_job_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:CreateTable",
          "glue:UpdateTable",
          "glue:BatchCreatePartition",
          "glue:BatchUpdatePartition"
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

# Policy: CloudWatch Logs
resource "aws_iam_role_policy" "gold_job_cloudwatch" {
  name = "gold-job-cloudwatch-logs"
  role = aws_iam_role.gold_job_role.id

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

# Policy: Read Glue Scripts from S3
resource "aws_iam_role_policy" "gold_job_scripts" {
  name = "gold-job-scripts-access"
  role = aws_iam_role.gold_job_role.id

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
# 2. S3 OBJECT - UPLOAD DO SCRIPT PYSPARK GOLD
# ============================================================================

resource "aws_s3_object" "gold_car_current_state_script" {
  bucket = aws_s3_bucket.glue_scripts.id
  key    = "glue_jobs/gold_car_current_state_job.py"
  source = "${path.module}/../glue_jobs/gold_car_current_state_job.py"
  etag   = filemd5("${path.module}/../glue_jobs/gold_car_current_state_job.py")

  tags = {
    Name        = "gold-car-current-state-script"
    Layer       = "Gold"
    Description = "PySpark script for Gold layer - Car Current State snapshot"
  }
}

# ============================================================================
# 3. CLOUDWATCH LOG GROUP - GOLD JOB
# ============================================================================

resource "aws_cloudwatch_log_group" "gold_job_logs" {
  name              = "/aws-glue/jobs/${var.project_name}-gold-car-current-state-${var.environment}"
  retention_in_days = 14 # 14 days retention

  tags = {
    Name  = "${var.project_name}-gold-job-logs-${var.environment}"
    Layer = "Gold"
  }
}

# ============================================================================
# 4. AWS GLUE JOB - GOLD CAR CURRENT STATE
# ============================================================================

resource "aws_glue_job" "gold_car_current_state" {
  name              = "${var.project_name}-gold-car-current-state-${var.environment}"
  role_arn          = aws_iam_role.gold_job_role.arn
  glue_version      = var.glue_version
  worker_type       = var.glue_worker_type
  number_of_workers = var.glue_number_of_workers
  timeout           = var.glue_job_timeout_minutes

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.id}/${aws_s3_object.gold_car_current_state_script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--job-bookmark-option"              = "job-bookmark-disable" # Snapshot sempre processa tudo
    "--enable-metrics"                   = "true"
    "--enable-spark-ui"                  = "true"
    "--enable-glue-datacatalog"          = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--TempDir"                          = "s3://${aws_s3_bucket.glue_temp.id}/temp/"
    
    # Parâmetros customizados do job
    "--silver_database" = aws_glue_catalog_database.data_lake_database.name
    "--silver_table"    = var.silver_table_name
    "--gold_database"   = aws_glue_catalog_database.data_lake_database.name
    "--gold_bucket"     = aws_s3_bucket.data_lake["gold"].id
    "--gold_path"       = "car_current_state"
    
    # Configurações Spark para otimização
    "--conf" = "spark.sql.sources.partitionOverwriteMode=static"
  }

  execution_property {
    max_concurrent_runs = 1 # Snapshot: apenas 1 execução por vez
  }

  tags = {
    Name        = "${var.project_name}-gold-car-current-state-${var.environment}"
    Layer       = "Gold"
    JobType     = "Snapshot"
  }

  depends_on = [
    aws_s3_object.gold_car_current_state_script,
    aws_iam_role_policy.gold_job_read_silver,
    aws_iam_role_policy.gold_job_write_gold,
    aws_iam_role_policy.gold_job_catalog_access,
    aws_iam_role_policy.gold_job_cloudwatch
  ]
}

# ============================================================================
# 5. IAM ROLE - GOLD CRAWLER
# ============================================================================

resource "aws_iam_role" "gold_crawler_role" {
  name               = "${var.project_name}-gold-crawler-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json

  tags = {
    Name    = "${var.project_name}-gold-crawler-role-${var.environment}"
    Layer   = "Gold"
    Purpose = "Glue-Crawler-Execution"
  }
}

# Policy: Acesso ao Gold Bucket (leitura)
resource "aws_iam_role_policy" "gold_crawler_s3" {
  name = "gold-crawler-s3-access"
  role = aws_iam_role.gold_crawler_role.id

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
          aws_s3_bucket.data_lake["gold"].arn,
          "${aws_s3_bucket.data_lake["gold"].arn}/*"
        ]
      }
    ]
  })
}

# Policy: Acesso ao Glue Data Catalog
resource "aws_iam_role_policy" "gold_crawler_catalog" {
  name = "gold-crawler-catalog-access"
  role = aws_iam_role.gold_crawler_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:CreateTable",
          "glue:UpdateTable",
          "glue:CreatePartition",
          "glue:UpdatePartition"
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

# Policy: CloudWatch Logs
resource "aws_iam_role_policy" "gold_crawler_cloudwatch" {
  name = "gold-crawler-cloudwatch-logs"
  role = aws_iam_role.gold_crawler_role.id

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
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws-glue/crawlers",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws-glue/crawlers:*"
        ]
      }
    ]
  })
}

# ============================================================================
# 6. AWS GLUE CRAWLER - GOLD CAR CURRENT STATE
# ============================================================================

resource "aws_glue_crawler" "gold_car_current_state" {
  name          = "${var.project_name}-gold-car-current-state-crawler-${var.environment}"
  database_name = aws_glue_catalog_database.data_lake_database.name
  role          = aws_iam_role.gold_crawler_role.arn
  description   = "Crawler for Gold layer - Car Current State table"

  # Não definir schedule - será acionado pelo workflow
  # schedule = ""

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake["gold"].id}/car_current_state/"
  }

  schema_change_policy {
    delete_behavior = "LOG"        # Não deletar dados se schema mudar
    update_behavior = "UPDATE_IN_DATABASE" # Atualizar schema no catálogo
  }

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
      Tables     = { AddOrUpdateBehavior = "MergeNewColumns" }
    }
  })

  table_prefix = "gold_"

  tags = {
    Name      = "${var.project_name}-gold-car-current-state-crawler-${var.environment}"
    Layer     = "Gold"
    TableName = "gold_car_current_state"
  }

  depends_on = [
    aws_iam_role_policy.gold_crawler_s3,
    aws_iam_role_policy.gold_crawler_catalog,
    aws_iam_role_policy.gold_crawler_cloudwatch
  ]
}

# ============================================================================
# 7. AWS GLUE WORKFLOW - GOLD LAYER ORCHESTRATION
# ============================================================================

resource "aws_glue_workflow" "gold_etl_workflow" {
  name        = "${var.project_name}-gold-etl-workflow-${var.environment}"
  description = "Workflow orquestrado: Silver Crawler (SUCCESS) → Gold Job → Gold Crawler"

  tags = {
    Name        = "${var.project_name}-gold-etl-workflow-${var.environment}"
    Layer       = "Gold"
    Component   = "Orchestration"
    Purpose     = "Automated-Gold-Aggregation-Pipeline"
    Trigger     = "Silver-Crawler-Success"
  }
}

# ============================================================================
# 8. TRIGGERS MOVIDOS PARA glue_workflow.tf
# ============================================================================
# NOTA: Os triggers abaixo foram movidos para glue_workflow.tf para consolidar
# toda a orquestração (Silver + Gold) em um único Workflow.
# 
# Triggers agora no Workflow:
# - silver_crawler_succeeded_start_gold_job (Trigger 4)
# - gold_job_succeeded_start_gold_crawler (Trigger 5)
# 
# Benefícios:
# - Visualização unificada no console AWS Glue
# - Monitoramento centralizado de toda a pipeline
# - Triggers condicionais mais confiáveis dentro do workflow
# ============================================================================

/*
# REMOVIDO - Agora está em glue_workflow.tf como Trigger 4
resource "aws_glue_trigger" "silver_succeeded_start_gold_job" {
  name        = "${var.project_name}-silver-succeeded-start-gold-job-${var.environment}"
  description = "Trigger condicional STANDALONE: Quando Silver Crawler SUCCEEDED, inicia Gold Job automaticamente"
  type        = "CONDITIONAL"
  enabled     = true

  predicate {
    logical = "AND"

    conditions {
      crawler_name     = aws_glue_crawler.silver_crawler.name
      crawl_state      = "SUCCEEDED"
      logical_operator = "EQUALS"
    }
  }

  actions {
    job_name = aws_glue_job.gold_car_current_state.name
  }

  tags = {
    Name        = "${var.project_name}-silver-succeeded-start-gold-job-${var.environment}"
    TriggerType = "CONDITIONAL-STANDALONE"
    Condition   = "Silver-Crawler-SUCCEEDED"
    Target      = "Gold-Job"
    Pattern     = "Cross-Workflow-Orchestration"
  }

  depends_on = [
    aws_glue_crawler.silver_crawler,
    aws_glue_job.gold_car_current_state
  ]
}
*/

/*
# REMOVIDO - Agora está em glue_workflow.tf como Trigger 5
resource "aws_glue_trigger" "gold_job_succeeded_start_crawler" {
  name        = "${var.project_name}-gold-job-succeeded-start-crawler-${var.environment}"
  description = "Trigger condicional STANDALONE: Quando Gold Job SUCCEEDED, inicia Gold Crawler automaticamente"
  type        = "CONDITIONAL"
  enabled     = true

  predicate {
    logical = "AND"

    conditions {
      job_name         = aws_glue_job.gold_car_current_state.name
      state            = "SUCCEEDED"
      logical_operator = "EQUALS"
    }
  }

  actions {
    crawler_name = aws_glue_crawler.gold_car_current_state.name
  }

  tags = {
    Name        = "${var.project_name}-gold-job-succeeded-start-crawler-${var.environment}"
    TriggerType = "CONDITIONAL-STANDALONE"
    Condition   = "Gold-Job-SUCCEEDED"
    Target      = "Gold-Crawler"
    Pattern     = "Job-to-Crawler-Orchestration"
  }

  depends_on = [
    logical = "AND"

    conditions {
      job_name         = aws_glue_job.gold_car_current_state.name
      state            = "SUCCEEDED"
      logical_operator = "EQUALS"
    }
  }

  actions {
    crawler_name = aws_glue_crawler.gold_car_current_state.name
  }

  tags = {
    Name        = "${var.project_name}-gold-job-succeeded-start-crawler-${var.environment}"
    TriggerType = "CONDITIONAL-STANDALONE"
    Condition   = "Gold-Job-SUCCEEDED"
    Target      = "Gold-Crawler"
    Pattern     = "Job-to-Crawler-Orchestration"
  }

  depends_on = [
    aws_glue_job.gold_car_current_state,
    aws_glue_crawler.gold_car_current_state
  ]
}
*/

# ============================================================================
# 9. OUTPUTS - GOLD LAYER
# ============================================================================

output "gold_job_name" {
  description = "Nome do Glue Job Gold - Car Current State"
  value       = aws_glue_job.gold_car_current_state.name
}

output "gold_job_arn" {
  description = "ARN do Glue Job Gold"
  value       = aws_glue_job.gold_car_current_state.arn
}

output "gold_crawler_name" {
  description = "Nome do Glue Crawler Gold"
  value       = aws_glue_crawler.gold_car_current_state.name
}

output "gold_workflow_name" {
  description = "Nome do Workflow Gold"
  value       = aws_glue_workflow.gold_etl_workflow.name
}

output "gold_workflow_arn" {
  description = "ARN do Workflow Gold"
  value       = aws_glue_workflow.gold_etl_workflow.arn
}

output "gold_workflow_summary" {
  description = "Resumo do Workflow Gold"
  value = {
    workflow_name        = aws_glue_workflow.gold_etl_workflow.name
    trigger_source       = "Silver Crawler (SUCCEEDED)"
    job_name             = aws_glue_job.gold_car_current_state.name
    crawler_name         = aws_glue_crawler.gold_car_current_state.name
    output_table         = "gold_car_current_state"
    flow                 = "Silver Crawler (SUCCESS) → Gold Job → Gold Crawler → Athena Updated"
    orchestration_type   = "Event-Driven (Conditional Triggers)"
    snapshot_mode        = "Full Overwrite (Static)"
    business_logic       = "1 row per carChassis (max currentMileage)"
  }
}

# ============================================================================
# DOCUMENTAÇÃO DO WORKFLOW GOLD
# ============================================================================

/*
FLUXO DE ORQUESTRAÇÃO - CAMADA GOLD
====================================

Pipeline Completo (Silver → Gold):
-----------------------------------

1. Silver Workflow executa:
   - Silver Job (ETL) → SUCCEEDED
   - Silver Crawler → SUCCEEDED ✅

2. Gold Workflow é acionado automaticamente:
   - Trigger Condicional detecta: Silver Crawler = SUCCEEDED
   - Gold Job inicia automaticamente
   
3. Gold Job processa:
   - Lê tabela silver_car_telemetry completa
   - Aplica Window Function (row_number por carChassis)
   - Filtra apenas currentMileage máximo (estado atual)
   - Escreve snapshot no Gold Bucket (overwrite)
   - Status: SUCCEEDED ✅

4. Gold Crawler é acionado automaticamente:
   - Trigger Condicional detecta: Gold Job = SUCCEEDED
   - Crawler escaneia car_current_state/
   - Atualiza tabela gold_car_current_state no catálogo
   - Status: SUCCEEDED ✅

5. Athena atualizado:
   - Tabela gold_car_current_state disponível
   - Queries podem acessar estado atual dos veículos
   - Latência total: ~3-4 minutos

Características:
----------------
- Acionamento: Event-Driven (Silver Crawler Success)
- Frequência: A cada execução bem-sucedida do pipeline Silver
- Tipo: Snapshot (overwrite completo, não-incremental)
- Particionamento: Nenhum (tabela pequena - 1 linha/carro)
- Bookmark: Desabilitado (sempre processa tudo)

Variáveis Terraform Necessárias:
---------------------------------
- var.project_name
- var.environment
- var.glue_database_name
- var.silver_table_name
- var.glue_version
- var.glue_worker_type
- var.glue_number_of_workers
- var.glue_job_timeout
- var.log_retention_days
- var.aws_region

Dependências:
-------------
- aws_glue_crawler.silver_crawler (trigger source)
- aws_s3_bucket.data_lake["silver"] (input)
- aws_s3_bucket.data_lake["gold"] (output)
- aws_s3_bucket.glue_scripts (script storage)
- aws_s3_bucket.glue_temp (temp directory)

Console Links:
--------------
- Workflow: https://console.aws.amazon.com/glue/home?region=us-east-1#/v2/etl-configuration/workflows
- Job: https://console.aws.amazon.com/glue/home?region=us-east-1#/v2/etl-configuration/jobs
- Crawler: https://console.aws.amazon.com/glue/home?region=us-east-1#/v2/data-catalog/crawlers
- Table: https://console.aws.amazon.com/glue/home?region=us-east-1#/v2/data-catalog/tables

Monitoramento:
--------------
aws glue get-workflow-run --name [workflow-name] --run-id [run-id]
aws glue get-job-run --job-name [job-name] --run-id [run-id]
aws glue get-crawler --name [crawler-name]

Query de Teste (Athena):
------------------------
SELECT 
    carChassis,
    Manufacturer,
    Model,
    currentMileage,
    metrics_metricTimestamp AS last_event,
    gold_snapshot_date
FROM gold_car_current_state
ORDER BY currentMileage DESC
LIMIT 10;
*/
