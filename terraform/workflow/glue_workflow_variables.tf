# ================================================================================
# Variáveis Terraform - AWS Glue Workflow
# ================================================================================

variable "aws_region" {
  description = "Região AWS para deployment"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Ambiente de deployment (dev, staging, prod)"
  type        = string
  default     = "dev"
}

# ================================================================================
# WORKFLOW CONFIGURATION
# ================================================================================

variable "workflow_name" {
  description = "Nome do Glue Workflow"
  type        = string
  default     = "datalake-pipeline-silver-gold-workflow-dev"
}

variable "workflow_schedule" {
  description = "Expressão cron para agendamento do workflow (UTC). Default: diariamente às 02:00 UTC"
  type        = string
  default     = "cron(0 2 * * ? *)"
  
  validation {
    condition     = can(regex("^cron\\(", var.workflow_schedule))
    error_message = "O schedule deve ser uma expressão cron válida (ex: cron(0 2 * * ? *))"
  }
}

variable "workflow_enabled" {
  description = "Habilita ou desabilita a execução automática do workflow"
  type        = bool
  default     = true
}

# ================================================================================
# TIMEOUTS CONFIGURATION
# ================================================================================

variable "job_timeout_minutes" {
  description = "Timeout padrão para jobs Glue (em minutos)"
  type        = number
  default     = 30
  
  validation {
    condition     = var.job_timeout_minutes > 0 && var.job_timeout_minutes <= 2880
    error_message = "Timeout deve ser entre 1 e 2880 minutos (48 horas)"
  }
}

variable "crawler_timeout_minutes" {
  description = "Timeout padrão para crawlers Glue (em minutos)"
  type        = number
  default     = 15
  
  validation {
    condition     = var.crawler_timeout_minutes > 0 && var.crawler_timeout_minutes <= 2880
    error_message = "Timeout deve ser entre 1 e 2880 minutos (48 horas)"
  }
}

# ================================================================================
# JOB NAMES (Existing Resources)
# ================================================================================

variable "silver_consolidation_job_name" {
  description = "Nome do job Glue Silver Consolidation"
  type        = string
  default     = "datalake-pipeline-silver-consolidation-dev"
}

variable "gold_car_current_state_job_name" {
  description = "Nome do job Glue Gold Car Current State"
  type        = string
  default     = "datalake-pipeline-gold-car-current-state-dev"
}

variable "gold_fuel_efficiency_job_name" {
  description = "Nome do job Glue Gold Fuel Efficiency"
  type        = string
  default     = "datalake-pipeline-gold-fuel-efficiency-dev"
}

variable "gold_performance_alerts_slim_job_name" {
  description = "Nome do job Glue Gold Performance Alerts Slim"
  type        = string
  default     = "datalake-pipeline-gold-performance-alerts-slim-dev"
}

# ================================================================================
# CRAWLER NAMES (Existing Resources)
# ================================================================================

variable "silver_crawler_name" {
  description = "Nome do crawler Silver silver_car_telemetry"
  type        = string
  default     = "datalake-pipeline-silver-car-crawler-dev"
}

variable "gold_car_current_state_crawler_name" {
  description = "Nome do crawler Gold car_current_state"
  type        = string
  default     = "datalake-pipeline-gold-car-current-state-crawler-dev"
}

variable "gold_fuel_efficiency_crawler_name" {
  description = "Nome do crawler Gold fuel_efficiency_monthly"
  type        = string
  default     = "datalake-pipeline-gold-fuel-efficiency-crawler-dev"
}

variable "gold_performance_alerts_slim_crawler_name" {
  description = "Nome do crawler Gold performance_alerts_log_slim"
  type        = string
  default     = "datalake-pipeline-gold-performance-alerts-slim-crawler-dev"
}

# ================================================================================
# TAGS CONFIGURATION
# ================================================================================

variable "common_tags" {
  description = "Tags comuns para todos os recursos"
  type        = map(string)
  default = {
    Project     = "datalake-pipeline"
    ManagedBy   = "Terraform"
    Component   = "workflow"
    CostCenter  = "data-engineering"
  }
}
