# ================================================================================
# AWS Glue Workflow - Terraform Values
# ================================================================================
# Arquivo de configuração para o workflow Silver → Gold
# Edite estas variáveis conforme necessário para seu ambiente
# ================================================================================

# AWS Configuration
aws_region  = "us-east-1"
environment = "dev"

# Workflow Configuration
workflow_name    = "datalake-pipeline-silver-gold-workflow-dev"
workflow_enabled = true

# Schedule: Diariamente às 02:00 UTC (23:00 Brasília horário de verão)
# Ajuste conforme necessário:
# - cron(0 2 * * ? *)  = 02:00 UTC diariamente
# - cron(0 */6 * * ? *) = A cada 6 horas
# - cron(0 8 ? * MON-FRI *) = 08:00 UTC dias úteis
workflow_schedule = "cron(0 2 * * ? *)"

# Timeouts
job_timeout_minutes     = 30  # 30 minutos por job
crawler_timeout_minutes = 15  # 15 minutos por crawler

# ================================================================================
# Job Names (Recursos Existentes)
# ================================================================================
# IMPORTANTE: Estes jobs já devem existir no ambiente AWS antes do deploy

silver_consolidation_job_name         = "datalake-pipeline-silver-consolidation-dev"
gold_car_current_state_job_name       = "datalake-pipeline-gold-car-current-state-dev"
gold_fuel_efficiency_job_name         = "datalake-pipeline-gold-fuel-efficiency-dev"
gold_performance_alerts_slim_job_name = "datalake-pipeline-gold-performance-alerts-slim-dev"

# ================================================================================
# Crawler Names (Recursos Existentes)
# ================================================================================
# IMPORTANTE: Estes crawlers já devem existir no ambiente AWS antes do deploy

silver_crawler_name                        = "datalake-pipeline-silver-crawler-dev"
gold_car_current_state_crawler_name        = "datalake-pipeline-gold-car-current-state-crawler-dev"
gold_fuel_efficiency_crawler_name          = "datalake-pipeline-gold-fuel-efficiency-crawler-dev"
gold_performance_alerts_slim_crawler_name  = "datalake-pipeline-gold-performance-alerts-slim-crawler-dev"

# ================================================================================
# Tags Comuns
# ================================================================================

common_tags = {
  Project     = "datalake-pipeline"
  ManagedBy   = "Terraform"
  Component   = "workflow"
  CostCenter  = "data-engineering"
  Owner       = "data-team"
  Environment = "dev"
}
