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
  source = "${path.module}/../glue_jobs/gold_car_current_state_job_refactored.py"  # Versão refatorada CORRIGIDA
  etag   = filemd5("${path.module}/../glue_jobs/gold_car_current_state_job_refactored.py")

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
    "--database_name"   = aws_glue_catalog_database.data_lake_database.name  # Adicionado
    "--silver_database" = aws_glue_catalog_database.data_lake_database.name
    "--silver_table"    = var.silver_table_name
    "--silver_table_name" = var.silver_table_name  # Adicionado para compatibilidade com script refactored
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
# 6. AWS GLUE CATALOG TABLE - GOLD CAR CURRENT STATE (PRE-DEFINED SCHEMA)
# ============================================================================

# Definição explícita da tabela para incluir as novas colunas de KPIs de Seguro
# Nota: O crawler irá atualizar/adicionar colunas automaticamente, mas definimos
# o schema inicial para garantir que as novas colunas sejam reconhecidas
resource "aws_glue_catalog_table" "gold_car_current_state" {
  name          = "gold_car_current_state"
  database_name = aws_glue_catalog_database.data_lake_database.name
  description   = "Gold layer table - Car Current State with Insurance KPIs"

  table_type = "EXTERNAL_TABLE"

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.data_lake["gold"].id}/car_current_state/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    # Schema inicial com todas as colunas Silver + KPIs de Seguro
    columns {
      name    = "carchassis"
      type    = "string"
      comment = "Identificador único do chassi do veículo"
    }
    columns {
      name    = "model"
      type    = "string"
      comment = "Modelo do veículo"
    }
    columns {
      name    = "year"
      type    = "bigint"
      comment = "Ano de fabricação"
    }
    columns {
      name    = "modelyear"
      type    = "bigint"
      comment = "Ano do modelo"
    }
    columns {
      name    = "manufacturer"
      type    = "string"
      comment = "Fabricante do veículo"
    }
    columns {
      name    = "horsepower"
      type    = "bigint"
      comment = "Potência em cavalos"
    }
    columns {
      name    = "gastype"
      type    = "string"
      comment = "Tipo de combustível"
    }
    columns {
      name    = "currentmileage"
      type    = "bigint"
      comment = "Quilometragem atual (mais recente)"
    }
    columns {
      name    = "color"
      type    = "string"
      comment = "Cor do veículo"
    }
    columns {
      name    = "fuelcapacityliters"
      type    = "bigint"
      comment = "Capacidade do tanque em litros"
    }
    columns {
      name    = "metrics_enginetempcelsius"
      type    = "bigint"
      comment = "Temperatura do motor em Celsius"
    }
    columns {
      name    = "metrics_oiltempcelsius"
      type    = "bigint"
      comment = "Temperatura do óleo em Celsius"
    }
    columns {
      name    = "metrics_batterychargeper"
      type    = "bigint"
      comment = "Percentual de carga da bateria"
    }
    columns {
      name    = "metrics_fuelavailableliters"
      type    = "double"
      comment = "Combustível disponível em litros"
    }
    columns {
      name    = "metrics_coolantcelsius"
      type    = "bigint"
      comment = "Temperatura do radiador em Celsius"
    }
    columns {
      name    = "metrics_trip_tripmileage"
      type    = "bigint"
      comment = "Quilometragem da viagem"
    }
    columns {
      name    = "metrics_trip_triptimeminutes"
      type    = "bigint"
      comment = "Duração da viagem em minutos"
    }
    columns {
      name    = "metrics_trip_tripfuelliters"
      type    = "double"
      comment = "Combustível consumido na viagem"
    }
    columns {
      name    = "metrics_trip_tripmaxspeedkm"
      type    = "bigint"
      comment = "Velocidade máxima na viagem"
    }
    columns {
      name    = "metrics_trip_tripaveragespeedkm"
      type    = "bigint"
      comment = "Velocidade média na viagem"
    }
    columns {
      name    = "metrics_trip_tripstarttimestamp"
      type    = "string"
      comment = "Timestamp de início da viagem"
    }
    columns {
      name    = "metrics_metrictimestamp"
      type    = "string"
      comment = "Timestamp da métrica"
    }
    columns {
      name    = "carinsurance_number"
      type    = "string"
      comment = "Número da apólice de seguro"
    }
    columns {
      name    = "carinsurance_provider"
      type    = "string"
      comment = "Empresa seguradora"
    }
    columns {
      name    = "carinsurance_validuntil"
      type    = "string"
      comment = "Data de validade do seguro"
    }
    columns {
      name    = "market_currentprice"
      type    = "bigint"
      comment = "Preço atual de mercado"
    }
    columns {
      name    = "market_currency"
      type    = "string"
      comment = "Moeda do preço"
    }
    columns {
      name    = "market_location"
      type    = "string"
      comment = "Localização do mercado"
    }
    columns {
      name    = "market_dealer"
      type    = "string"
      comment = "Concessionária"
    }
    columns {
      name    = "market_warrantyyears"
      type    = "bigint"
      comment = "Anos de garantia"
    }
    columns {
      name    = "market_evaluator"
      type    = "string"
      comment = "Avaliador de mercado"
    }
    columns {
      name    = "event_year"
      type    = "string"
      comment = "Ano do evento (partição)"
    }
    columns {
      name    = "event_month"
      type    = "string"
      comment = "Mês do evento (partição)"
    }
    columns {
      name    = "event_day"
      type    = "string"
      comment = "Dia do evento (partição)"
    }
    
    # NOVAS COLUNAS: KPIs DE SEGURO
    columns {
      name    = "insurance_status"
      type    = "string"
      comment = "Status do seguro: VENCIDO, VENCENDO_EM_90_DIAS, ATIVO"
    }
    columns {
      name    = "insurance_days_expired"
      type    = "int"
      comment = "Numero de dias desde o vencimento do seguro"
    }
    
    # COLUNAS DE METADADOS GOLD
    columns {
      name    = "gold_processing_timestamp"
      type    = "timestamp"
      comment = "Timestamp de processamento na camada Gold"
    }
    columns {
      name    = "gold_snapshot_date"
      type    = "date"
      comment = "Data do snapshot Gold"
    }
  }

  # tags = {  # aws_glue_catalog_table não suporta tags
  #   Name         = "gold_car_current_state"
  #   Layer        = "Gold"
  #   TableType    = "Current-State"
  #   Schema       = "Pre-defined-with-Insurance-KPIs"
  #   LastModified = timestamp()
  # }
}

# ============================================================================
# 7. AWS GLUE CRAWLER - GOLD CAR CURRENT STATE
# ============================================================================

resource "aws_glue_crawler" "gold_car_current_state" {
  name          = "${var.project_name}-gold-car-current-state-crawler-${var.environment}"
  database_name = aws_glue_catalog_database.data_lake_database.name
  role          = aws_iam_role.gold_crawler_role.arn
  description   = "Crawler for Gold layer - Car Current State table with Insurance KPIs"

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
    aws_glue_catalog_table.gold_car_current_state,
    aws_iam_role_policy.gold_crawler_s3,
    aws_iam_role_policy.gold_crawler_catalog,
    aws_iam_role_policy.gold_crawler_cloudwatch
  ]
}

# ============================================================================
# 8. AWS GLUE WORKFLOW - GOLD LAYER ORCHESTRATION
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
# 9. TRIGGERS MOVIDOS PARA glue_workflow.tf
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
# - Schema pré-definido incluindo KPIs de Seguro
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
