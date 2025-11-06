# ================================================================================
# AWS Glue Workflow - Orquestração Automatizada Silver → Gold
# ================================================================================
# Descrição: Workflow para automação completa do pipeline de dados
# Pipeline: Silver Consolidation → Silver Crawler → Gold Jobs (Fan-Out) → Gold Crawlers
# Padrão: DAG com execução condicional e paralelização
# ================================================================================

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ================================================================================
# 1. AWS GLUE WORKFLOW
# ================================================================================

resource "aws_glue_workflow" "silver_gold_pipeline" {
  name        = var.workflow_name
  description = "Workflow automatizado para processamento Silver → Gold com fan-out paralelo"
  
  default_run_properties = {
    environment = var.environment
    project     = "datalake-pipeline"
    layer       = "silver-gold"
  }

  tags = {
    Name        = var.workflow_name
    Environment = var.environment
    Project     = "datalake-pipeline"
    ManagedBy   = "Terraform"
    Layer       = "orchestration"
    UpdatedAt   = timestamp()
  }
}

# ================================================================================
# 2. TRIGGER 1: SCHEDULED (Início do Pipeline)
# ================================================================================
# Gatilho agendado que inicia o workflow diariamente às 02:00 UTC
# Este é o ponto de entrada do pipeline automatizado

resource "aws_glue_trigger" "scheduled_start" {
  name          = "${var.workflow_name}-trigger-scheduled-start"
  description   = "Trigger agendado - Inicia pipeline Silver→Gold diariamente às 02:00 UTC"
  type          = "SCHEDULED"
  workflow_name = aws_glue_workflow.silver_gold_pipeline.name
  schedule      = var.workflow_schedule # cron(0 2 * * ? *)
  enabled       = var.workflow_enabled

  actions {
    job_name = var.silver_consolidation_job_name
    timeout  = var.job_timeout_minutes
    
    notification_property {
      notify_delay_after = 5 # minutos
    }
  }

  tags = {
    Name        = "${var.workflow_name}-trigger-scheduled"
    TriggerType = "SCHEDULED"
    Stage       = "pipeline-start"
    Environment = var.environment
  }
}

# ================================================================================
# 3. TRIGGER 2: CONDITIONAL (Silver Consolidation → Silver Crawler)
# ================================================================================
# Aguarda sucesso do job Silver para acionar crawler de descoberta de schema

resource "aws_glue_trigger" "silver_job_to_crawler" {
  name          = "${var.workflow_name}-trigger-silver-crawler"
  description   = "Trigger condicional - Inicia Silver Crawler após sucesso do Silver Job"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.silver_gold_pipeline.name
  enabled       = var.workflow_enabled

  predicate {
    logical = "ANY" # Sucesso em qualquer uma das condições

    conditions {
      job_name = var.silver_consolidation_job_name
      state    = "SUCCEEDED"
    }
  }

  actions {
    crawler_name = var.silver_crawler_name
    timeout      = var.crawler_timeout_minutes
  }

  tags = {
    Name        = "${var.workflow_name}-trigger-silver-crawler"
    TriggerType = "CONDITIONAL"
    Stage       = "silver-crawler"
    Environment = var.environment
  }

  depends_on = [aws_glue_trigger.scheduled_start]
}

# ================================================================================
# 4. TRIGGER 3: CONDITIONAL FAN-OUT (Silver Crawler → 3 Gold Jobs Paralelos)
# ================================================================================
# Após atualização do catálogo Silver, dispara os 3 jobs Gold simultaneamente
# Padrão Fan-Out: Uma única trigger com múltiplas actions

resource "aws_glue_trigger" "silver_crawler_to_gold_fanout" {
  name          = "${var.workflow_name}-trigger-gold-fanout"
  description   = "Trigger Fan-Out - Inicia 3 jobs Gold em paralelo após Silver Crawler"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.silver_gold_pipeline.name
  enabled       = var.workflow_enabled

  predicate {
    logical = "ANY"

    conditions {
      crawler_name = var.silver_crawler_name
      crawl_state  = "SUCCEEDED"
    }
  }

  # Action 1: Gold Car Current State
  actions {
    job_name = var.gold_car_current_state_job_name
    timeout  = var.job_timeout_minutes
    
    notification_property {
      notify_delay_after = 5
    }
  }

  # Action 2: Gold Fuel Efficiency
  actions {
    job_name = var.gold_fuel_efficiency_job_name
    timeout  = var.job_timeout_minutes
    
    notification_property {
      notify_delay_after = 5
    }
  }

  # Action 3: Gold Performance Alerts Slim
  actions {
    job_name = var.gold_performance_alerts_slim_job_name
    timeout  = var.job_timeout_minutes
    
    notification_property {
      notify_delay_after = 5
    }
  }

  tags = {
    Name        = "${var.workflow_name}-trigger-gold-fanout"
    TriggerType = "CONDITIONAL"
    Stage       = "gold-fanout"
    Pattern     = "fan-out"
    JobCount    = "3"
    Environment = var.environment
  }

  depends_on = [aws_glue_trigger.silver_job_to_crawler]
}

# ================================================================================
# 5. TRIGGER 4: CONDITIONAL (Gold Car Current State → Seu Crawler)
# ================================================================================

resource "aws_glue_trigger" "gold_car_state_to_crawler" {
  name          = "${var.workflow_name}-trigger-gold-car-state-crawler"
  description   = "Trigger condicional - Atualiza schema de gold_car_current_state"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.silver_gold_pipeline.name
  enabled       = var.workflow_enabled

  predicate {
    logical = "ANY"

    conditions {
      job_name = var.gold_car_current_state_job_name
      state    = "SUCCEEDED"
    }
  }

  actions {
    crawler_name = var.gold_car_current_state_crawler_name
    timeout      = var.crawler_timeout_minutes
  }

  tags = {
    Name        = "${var.workflow_name}-trigger-gold-car-state-crawler"
    TriggerType = "CONDITIONAL"
    Stage       = "gold-car-state-crawler"
    Environment = var.environment
  }

  depends_on = [aws_glue_trigger.silver_crawler_to_gold_fanout]
}

# ================================================================================
# 6. TRIGGER 5: CONDITIONAL (Gold Fuel Efficiency → Seu Crawler)
# ================================================================================

resource "aws_glue_trigger" "gold_fuel_efficiency_to_crawler" {
  name          = "${var.workflow_name}-trigger-gold-fuel-efficiency-crawler"
  description   = "Trigger condicional - Atualiza schema de fuel_efficiency_monthly"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.silver_gold_pipeline.name
  enabled       = var.workflow_enabled

  predicate {
    logical = "ANY"

    conditions {
      job_name = var.gold_fuel_efficiency_job_name
      state    = "SUCCEEDED"
    }
  }

  actions {
    crawler_name = var.gold_fuel_efficiency_crawler_name
    timeout      = var.crawler_timeout_minutes
  }

  tags = {
    Name        = "${var.workflow_name}-trigger-gold-fuel-efficiency-crawler"
    TriggerType = "CONDITIONAL"
    Stage       = "gold-fuel-efficiency-crawler"
    Environment = var.environment
  }

  depends_on = [aws_glue_trigger.silver_crawler_to_gold_fanout]
}

# ================================================================================
# 7. TRIGGER 6: CONDITIONAL (Gold Performance Alerts Slim → Seu Crawler)
# ================================================================================

resource "aws_glue_trigger" "gold_performance_alerts_to_crawler" {
  name          = "${var.workflow_name}-trigger-gold-alerts-slim-crawler"
  description   = "Trigger condicional - Atualiza schema de performance_alerts_log_slim"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.silver_gold_pipeline.name
  enabled       = var.workflow_enabled

  predicate {
    logical = "ANY"

    conditions {
      job_name = var.gold_performance_alerts_slim_job_name
      state    = "SUCCEEDED"
    }
  }

  actions {
    crawler_name = var.gold_performance_alerts_slim_crawler_name
    timeout      = var.crawler_timeout_minutes
  }

  tags = {
    Name        = "${var.workflow_name}-trigger-gold-alerts-slim-crawler"
    TriggerType = "CONDITIONAL"
    Stage       = "gold-alerts-crawler"
    Environment = var.environment
  }

  depends_on = [aws_glue_trigger.silver_crawler_to_gold_fanout]
}

# ================================================================================
# OUTPUTS
# ================================================================================

output "workflow_name" {
  description = "Nome do Glue Workflow criado"
  value       = aws_glue_workflow.silver_gold_pipeline.name
}

output "workflow_arn" {
  description = "ARN do Glue Workflow"
  value       = aws_glue_workflow.silver_gold_pipeline.arn
}

output "scheduled_trigger_name" {
  description = "Nome do trigger agendado (ponto de entrada)"
  value       = aws_glue_trigger.scheduled_start.name
}

output "workflow_schedule" {
  description = "Expressão cron do agendamento"
  value       = var.workflow_schedule
}

output "workflow_enabled" {
  description = "Status do workflow (habilitado/desabilitado)"
  value       = var.workflow_enabled
}

output "trigger_count" {
  description = "Total de triggers criados no workflow"
  value       = 6
}

output "parallel_gold_jobs" {
  description = "Jobs Gold executados em paralelo (Fan-Out)"
  value = [
    var.gold_car_current_state_job_name,
    var.gold_fuel_efficiency_job_name,
    var.gold_performance_alerts_slim_job_name
  ]
}
