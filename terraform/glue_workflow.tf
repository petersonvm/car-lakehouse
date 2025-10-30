# ============================================================================
# AWS Glue Workflow - Orquestração do Pipeline Silver
# ============================================================================
# Objetivo: Automatizar a sequência Job ETL → Crawler para eliminar latência
# Fluxo:
#   1. Trigger agendado (hourly) inicia o Workflow
#   2. Workflow executa o silver_consolidation_job
#   3. Se Job SUCCEEDED → Workflow aciona silver_data_crawler automaticamente
#   4. Dados ficam imediatamente disponíveis no Athena
# ============================================================================

# ----------------------------------------------------------------------------
# 1. WORKFLOW - Container da Orquestração
# ----------------------------------------------------------------------------
resource "aws_glue_workflow" "silver_etl_workflow" {
  name        = "${var.project_name}-silver-etl-workflow-${var.environment}"
  description = "Workflow orquestrado: Silver Job ETL → Crawler (elimina latência de dados no Athena)"

  tags = merge(
    var.common_tags,
    {
      Name      = "${var.project_name}-silver-etl-workflow-${var.environment}"
      Component = "Orchestration"
      Layer     = "Silver"
      Purpose   = "Automated-ETL-Catalog-Pipeline"
    }
  )
}

# ----------------------------------------------------------------------------
# 2. TRIGGER DE INÍCIO - Agendamento do Workflow (Hourly)
# ----------------------------------------------------------------------------
resource "aws_glue_trigger" "workflow_hourly_start" {
  name          = "${var.project_name}-workflow-hourly-start-${var.environment}"
  description   = "Trigger agendado (hourly) que inicia o Workflow Silver ETL"
  type          = "SCHEDULED"
  schedule      = var.glue_workflow_schedule # "cron(0 */1 * * ? *)" - A cada hora
  workflow_name = aws_glue_workflow.silver_etl_workflow.name
  enabled       = true

  actions {
    job_name = aws_glue_job.silver_consolidation.name
  }

  tags = merge(
    var.common_tags,
    {
      Name         = "${var.project_name}-workflow-hourly-start-${var.environment}"
      TriggerType  = "SCHEDULED"
      WorkflowName = aws_glue_workflow.silver_etl_workflow.name
    }
  )
}

# ----------------------------------------------------------------------------
# 3. TRIGGER CONDICIONAL - Job Succeeded → Start Crawler
# ----------------------------------------------------------------------------
resource "aws_glue_trigger" "job_succeeded_start_crawler" {
  name          = "${var.project_name}-job-succeeded-start-crawler-${var.environment}"
  description   = "Trigger condicional: Quando Job ETL SUCCEEDED, inicia o Crawler automaticamente"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.silver_etl_workflow.name
  enabled       = true

  # Ação: Iniciar o Crawler Silver
  actions {
    crawler_name = aws_glue_crawler.silver_crawler.name
  }

  # Predicado: Observar o Job e aguardar estado SUCCEEDED
  predicate {
    conditions {
      job_name = aws_glue_job.silver_consolidation.name
      state    = "SUCCEEDED"
    }
  }

  tags = merge(
    var.common_tags,
    {
      Name         = "${var.project_name}-job-succeeded-start-crawler-${var.environment}"
      TriggerType  = "CONDITIONAL"
      WorkflowName = aws_glue_workflow.silver_etl_workflow.name
      Condition    = "Job-SUCCEEDED"
    }
  )

  # Garantir que o Workflow existe antes de criar este trigger
  depends_on = [aws_glue_workflow.silver_etl_workflow]
}

# ----------------------------------------------------------------------------
# 4. TRIGGER CONDICIONAL - Silver Crawler Succeeded → Start Gold Job
# ----------------------------------------------------------------------------
resource "aws_glue_trigger" "silver_crawler_succeeded_start_gold_job" {
  name          = "${var.project_name}-silver-crawler-succeeded-start-gold-job-${var.environment}"
  description   = "Trigger condicional: Quando Silver Crawler SUCCEEDED, inicia Gold Job automaticamente"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.silver_etl_workflow.name
  enabled       = true

  # Ação: Iniciar o Gold Job
  actions {
    job_name = aws_glue_job.gold_car_current_state.name
  }

  # Predicado: Observar o Silver Crawler e aguardar estado SUCCEEDED
  predicate {
    logical = "AND"
    
    conditions {
      crawler_name     = aws_glue_crawler.silver_crawler.name
      crawl_state      = "SUCCEEDED"
      logical_operator = "EQUALS"
    }
  }

  tags = merge(
    var.common_tags,
    {
      Name         = "${var.project_name}-silver-crawler-succeeded-start-gold-job-${var.environment}"
      TriggerType  = "CONDITIONAL"
      WorkflowName = aws_glue_workflow.silver_etl_workflow.name
      Condition    = "Silver-Crawler-SUCCEEDED"
      TargetLayer  = "Gold"
    }
  )

  depends_on = [aws_glue_workflow.silver_etl_workflow]
}

# ----------------------------------------------------------------------------
# 5. TRIGGER CONDICIONAL - Gold Job Succeeded → Start Gold Crawler
# ----------------------------------------------------------------------------
resource "aws_glue_trigger" "gold_job_succeeded_start_gold_crawler" {
  name          = "${var.project_name}-gold-job-succeeded-start-gold-crawler-${var.environment}"
  description   = "Trigger condicional: Quando Gold Job SUCCEEDED, inicia Gold Crawler automaticamente"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.silver_etl_workflow.name
  enabled       = true

  # Ação: Iniciar o Gold Crawler
  actions {
    crawler_name = aws_glue_crawler.gold_car_current_state.name
  }

  # Predicado: Observar o Gold Job e aguardar estado SUCCEEDED
  predicate {
    logical = "AND"
    
    conditions {
      job_name         = aws_glue_job.gold_car_current_state.name
      state            = "SUCCEEDED"
      logical_operator = "EQUALS"
    }
  }

  tags = merge(
    var.common_tags,
    {
      Name         = "${var.project_name}-gold-job-succeeded-start-gold-crawler-${var.environment}"
      TriggerType  = "CONDITIONAL"
      WorkflowName = aws_glue_workflow.silver_etl_workflow.name
      Condition    = "Gold-Job-SUCCEEDED"
      TargetLayer  = "Gold"
    }
  )

  depends_on = [aws_glue_workflow.silver_etl_workflow]
}

# ----------------------------------------------------------------------------
# LIMPEZA: Remover Triggers Standalone (Movidos para o Workflow)
# ----------------------------------------------------------------------------
# NOTA: Os triggers standalone criados em glue_gold.tf serão removidos
# pois agora todo o pipeline (Silver + Gold) roda em um único Workflow.
# ============================================================================

# ----------------------------------------------------------------------------
# OUTPUTS - Informações do Workflow
# ----------------------------------------------------------------------------
output "glue_workflow_name" {
  description = "Nome do Workflow de orquestração Silver ETL"
  value       = aws_glue_workflow.silver_etl_workflow.name
}

output "glue_workflow_arn" {
  description = "ARN do Workflow de orquestração Silver ETL"
  value       = aws_glue_workflow.silver_etl_workflow.arn
}

output "workflow_trigger_schedule" {
  description = "Agendamento do Workflow (cron expression)"
  value       = var.glue_workflow_schedule
}

output "workflow_summary" {
  description = "Resumo da orquestração do Workflow completo (Silver + Gold)"
  value = {
    workflow_name     = aws_glue_workflow.silver_etl_workflow.name
    trigger_schedule  = var.glue_workflow_schedule
    silver_job_name   = aws_glue_job.silver_consolidation.name
    silver_crawler    = aws_glue_crawler.silver_crawler.name
    gold_job_name     = aws_glue_job.gold_car_current_state.name
    gold_crawler      = aws_glue_crawler.gold_car_current_state.name
    flow              = "Scheduled → Silver Job → Silver Crawler → Gold Job → Gold Crawler → Athena"
    total_triggers    = 4
    automation_level  = "Fully Automated (End-to-End)"
    latency           = "Near-zero (automatic execution chain)"
  }
}
