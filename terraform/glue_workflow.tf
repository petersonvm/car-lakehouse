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
# 4. TRIGGER CONDICIONAL - Silver Crawler Succeeded → Start Gold Jobs (PARALLEL)
# ----------------------------------------------------------------------------
resource "aws_glue_trigger" "silver_crawler_succeeded_start_gold_jobs" {
  name          = "${var.project_name}-silver-crawler-succeeded-start-gold-jobs-${var.environment}"
  description   = "Trigger condicional: Quando Silver Crawler SUCCEEDED, inicia TRÊS Gold Jobs em PARALELO (SLIM optimized)"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.silver_etl_workflow.name
  enabled       = true

  # ⚡ AÇÃO 1: Iniciar Gold Job - Car Current State
  actions {
    job_name = aws_glue_job.gold_car_current_state.name
  }

  # ⚡ AÇÃO 2: Iniciar Gold Job - Performance Alerts SLIM (PARALELO) ← SUBSTITUÍDO!
  actions {
    job_name = aws_glue_job.gold_performance_alerts_slim.name
  }

  # ⚡ AÇÃO 3: Iniciar Gold Job - Fuel Efficiency (PARALELO)
  actions {
    job_name = aws_glue_job.gold_fuel_efficiency.name
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
      Name         = "${var.project_name}-silver-crawler-succeeded-start-gold-jobs-${var.environment}"
      TriggerType  = "CONDITIONAL"
      WorkflowName = aws_glue_workflow.silver_etl_workflow.name
      Condition    = "Silver-Crawler-SUCCEEDED"
      TargetLayer  = "Gold"
      Execution    = "PARALLEL" # TRÊS jobs iniciam simultaneamente (alerts SLIM optimized)
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
  description = "Resumo da orquestração do Workflow completo (Silver + Dual Gold Pipelines)"
  value = {
    workflow_name              = aws_glue_workflow.silver_etl_workflow.name
    trigger_schedule           = var.glue_workflow_schedule
    
    # Silver Layer
    silver_job_name            = aws_glue_job.silver_consolidation.name
    silver_crawler             = aws_glue_crawler.silver_crawler.name
    
    # Gold Layer - Pipeline 1: Car Current State
    gold_current_state_job     = aws_glue_job.gold_car_current_state.name
    gold_current_state_crawler = aws_glue_crawler.gold_car_current_state.name
    
    # Gold Layer - Pipeline 2: Performance Alerts (NEW)
    gold_alerts_job            = aws_glue_job.gold_performance_alerts.name
    gold_alerts_crawler        = aws_glue_crawler.gold_performance_alerts.name
    
    # Flow Architecture
    flow                       = "Scheduled → Silver Job → Silver Crawler → [Gold Current State Job + Gold Alerts Job (PARALLEL)] → [Current State Crawler + Alerts Crawler] → Athena"
    total_triggers             = 5  # 1 scheduled + 2 conditional (Silver) + 2 conditional (Gold)
    gold_pipelines             = 2  # Dual Gold pipelines
    execution_mode             = "PARALLEL" # Gold jobs run simultaneously
    automation_level           = "Fully Automated (End-to-End with Dual Gold)"
    latency                    = "Near-zero (automatic execution chain)"
  }
}
