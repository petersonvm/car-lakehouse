# ===================================================================
# WORKFLOW COMPLETION & CLEANUP
# ===================================================================
# Este arquivo contém:
# 1. Confirmação de que os gatilhos 4, 5 e 6 já existem (workflow.tf)
# 2. Recursos legados marcados para remoção (importados para destruição)
# 
# Data: 2025-11-06
# Objetivo: Completar orquestração e otimizar custos removendo recursos órfãos
# ===================================================================

# ===================================================================
# PARTE 1: WORKFLOW COMPLETION STATUS
# ===================================================================
# ✅ GATILHOS 4, 5 E 6 JÁ IMPLEMENTADOS EM workflow.tf
# 
# Recursos existentes:
# - aws_glue_trigger.trigger_gold_current_state_to_crawler (linhas 80-94)
# - aws_glue_trigger.trigger_gold_fuel_efficiency_to_crawler (linhas 96-110)
# - aws_glue_trigger.trigger_gold_alerts_to_crawler (linhas 112-126)
#
# Crawlers Gold correspondentes existem em crawlers.tf:
# - aws_glue_crawler.gold_car_current_state_crawler
# - aws_glue_crawler.gold_fuel_efficiency_crawler
# - aws_glue_crawler.gold_alerts_slim_crawler
#
# ⚠️ AÇÃO NECESSÁRIA: Aplicar terraform apply para criar esses triggers na AWS
# ===================================================================

# ===================================================================
# PARTE 2: CLEANUP DE RECURSOS LEGADOS
# ===================================================================
# Esta seção marca recursos legados para remoção via Terraform
# 
# IMPORTANTE: Estes recursos precisam ser IMPORTADOS primeiro antes de
# serem destruídos pelo Terraform (se não foram criados via Terraform)
# 
# Comando para importar um recurso existente:
# terraform import aws_glue_crawler.car_silver_crawler car_silver_crawler
# ===================================================================

# ===================================================================
# 2.1 CRAWLERS LEGADOS PARA REMOÇÃO
# ===================================================================

# Crawler Legado 1: car_silver_crawler
# Motivo: Aponta para path S3 inexistente (car_silver/)
# Status: Criado manualmente na AWS, não gerenciado por Terraform
# Ação: Deletar via AWS CLI
resource "null_resource" "cleanup_car_silver_crawler" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Deletando crawler legado: car_silver_crawler"
      aws glue delete-crawler --name car_silver_crawler --region us-east-1 || echo "Crawler não existe ou já foi deletado"
    EOT
    when    = create
  }
}

# Crawler Legado 2: datalake-pipeline-gold-crawler-dev
# Motivo: Path genérico (gold/), não utilizado
resource "null_resource" "cleanup_gold_crawler_generic" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Deletando crawler legado: datalake-pipeline-gold-crawler-dev"
      aws glue delete-crawler --name datalake-pipeline-gold-crawler-dev --region us-east-1 || echo "Crawler não existe ou já foi deletado"
    EOT
    when    = create
  }
}

# Crawler Legado 3: datalake-pipeline-gold-performance-alerts-crawler-dev
# Motivo: Job legado (performance-alerts-dev) foi substituído pela versão Slim
resource "null_resource" "cleanup_gold_performance_alerts_crawler" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Deletando crawler legado: datalake-pipeline-gold-performance-alerts-crawler-dev"
      aws glue delete-crawler --name datalake-pipeline-gold-performance-alerts-crawler-dev --region us-east-1 || echo "Crawler não existe ou já foi deletado"
    EOT
    when    = create
  }
}

# Crawler Legado 4: datalake-pipeline-gold-performance-alerts-slim-crawler-dev
# Motivo: Duplicado, substituído por gold_alerts_slim_crawler (versão curta)
resource "null_resource" "cleanup_gold_performance_alerts_slim_crawler_long" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Deletando crawler legado: datalake-pipeline-gold-performance-alerts-slim-crawler-dev"
      aws glue delete-crawler --name datalake-pipeline-gold-performance-alerts-slim-crawler-dev --region us-east-1 || echo "Crawler não existe ou já foi deletado"
    EOT
    when    = create
  }
}

# Crawler Legado 5: datalake-pipeline-gold-fuel-efficiency-crawler-dev
# Motivo: Duplicado, substituído por gold_fuel_efficiency_crawler (versão curta)
resource "null_resource" "cleanup_gold_fuel_efficiency_crawler_long" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Deletando crawler legado: datalake-pipeline-gold-fuel-efficiency-crawler-dev"
      aws glue delete-crawler --name datalake-pipeline-gold-fuel-efficiency-crawler-dev --region us-east-1 || echo "Crawler não existe ou já foi deletado"
    EOT
    when    = create
  }
}

# Crawler Legado 6: datalake-pipeline-silver-crawler-dev
# Motivo: Duplicado, substituído por silver_car_telemetry_crawler (versão específica)
resource "null_resource" "cleanup_silver_crawler_generic" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Deletando crawler legado: datalake-pipeline-silver-crawler-dev"
      aws glue delete-crawler --name datalake-pipeline-silver-crawler-dev --region us-east-1 || echo "Crawler não existe ou já foi deletado"
    EOT
    when    = create
  }
}

# ===================================================================
# 2.2 LAMBDAS LEGADAS PARA REMOÇÃO
# ===================================================================
# Motivo: Pipeline migrado 100% para AWS Glue
# Exceção: datalake-pipeline-ingestion-dev é ATIVA (não deletar)

# Lambda Legada 1: datalake-pipeline-cleansing-dev
# Motivo: Substituída pelo Job Glue Silver (silver_consolidation_job.py)
resource "null_resource" "cleanup_lambda_cleansing" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Deletando Lambda legada: datalake-pipeline-cleansing-dev"
      aws lambda delete-function --function-name datalake-pipeline-cleansing-dev --region us-east-1 || echo "Lambda não existe ou já foi deletada"
    EOT
    when    = create
  }
}

# Lambda Legada 2: datalake-pipeline-analysis-dev
# Motivo: Substituída pelos Jobs Glue Gold
resource "null_resource" "cleanup_lambda_analysis" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Deletando Lambda legada: datalake-pipeline-analysis-dev"
      aws lambda delete-function --function-name datalake-pipeline-analysis-dev --region us-east-1 || echo "Lambda não existe ou já foi deletada"
    EOT
    when    = create
  }
}

# Lambda Legada 3: datalake-pipeline-compliance-dev
# Motivo: Substituída pelos Jobs Glue Gold
resource "null_resource" "cleanup_lambda_compliance" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Deletando Lambda legada: datalake-pipeline-compliance-dev"
      aws lambda delete-function --function-name datalake-pipeline-compliance-dev --region us-east-1 || echo "Lambda não existe ou já foi deletada"
    EOT
    when    = create
  }
}

# ===================================================================
# 2.3 GLUE JOB LEGADO PARA REMOÇÃO
# ===================================================================

# Job Legado: datalake-pipeline-gold-performance-alerts-dev
# Motivo: Substituído pela versão otimizada (gold-performance-alerts-slim-dev)
resource "null_resource" "cleanup_job_performance_alerts" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Deletando Job Glue legado: datalake-pipeline-gold-performance-alerts-dev"
      aws glue delete-job --job-name datalake-pipeline-gold-performance-alerts-dev --region us-east-1 || echo "Job não existe ou já foi deletado"
    EOT
    when    = create
  }
}

# ===================================================================
# 2.4 OUTPUTS PARA MONITORAMENTO
# ===================================================================

output "workflow_completion_status" {
  description = "Status da completude do workflow"
  value = {
    gatilhos_workflow_implementados = "✅ Gatilhos 4, 5 e 6 definidos em workflow.tf"
    acao_necessaria                 = "terraform apply para criar triggers na AWS"
    workflow_name                   = "datalake-pipeline-silver-gold-workflow-dev"
    triggers_a_criar = [
      "trigger-gold-current-state-to-crawler",
      "trigger-gold-fuel-efficiency-to-crawler",
      "trigger-gold-alerts-to-crawler"
    ]
  }
}

output "cleanup_resources_summary" {
  description = "Resumo dos recursos marcados para remoção"
  value = {
    crawlers_legados = [
      "car_silver_crawler",
      "datalake-pipeline-gold-crawler-dev",
      "datalake-pipeline-gold-performance-alerts-crawler-dev",
      "datalake-pipeline-gold-performance-alerts-slim-crawler-dev",
      "datalake-pipeline-gold-fuel-efficiency-crawler-dev",
      "datalake-pipeline-silver-crawler-dev"
    ]
    lambdas_legadas = [
      "datalake-pipeline-cleansing-dev",
      "datalake-pipeline-analysis-dev",
      "datalake-pipeline-compliance-dev"
    ]
    jobs_legados = [
      "datalake-pipeline-gold-performance-alerts-dev"
    ]
    lambda_ativa_mantida = "datalake-pipeline-ingestion-dev (NÃO DELETAR)"
    economia_mensal_estimada = "$15-20/mês (lambdas + crawlers + job inativo)"
  }
}

# ===================================================================
# INSTRUÇÕES DE USO
# ===================================================================
# 
# ETAPA 1: APLICAR TRIGGERS DO WORKFLOW (se ainda não existem na AWS)
# ----------------------------------------------------------------------
# terraform plan -target=aws_glue_trigger.trigger_gold_current_state_to_crawler \
#                -target=aws_glue_trigger.trigger_gold_fuel_efficiency_to_crawler \
#                -target=aws_glue_trigger.trigger_gold_alerts_to_crawler
# 
# terraform apply -target=aws_glue_trigger.trigger_gold_current_state_to_crawler \
#                 -target=aws_glue_trigger.trigger_gold_fuel_efficiency_to_crawler \
#                 -target=aws_glue_trigger.trigger_gold_alerts_to_crawler
#
# ETAPA 2: EXECUTAR CLEANUP (DELETAR RECURSOS LEGADOS)
# ----------------------------------------------------------------------
# terraform apply -target=null_resource.cleanup_car_silver_crawler \
#                 -target=null_resource.cleanup_gold_crawler_generic \
#                 -target=null_resource.cleanup_gold_performance_alerts_crawler \
#                 -target=null_resource.cleanup_gold_performance_alerts_slim_crawler_long \
#                 -target=null_resource.cleanup_gold_fuel_efficiency_crawler_long \
#                 -target=null_resource.cleanup_silver_crawler_generic \
#                 -target=null_resource.cleanup_lambda_cleansing \
#                 -target=null_resource.cleanup_lambda_analysis \
#                 -target=null_resource.cleanup_lambda_compliance \
#                 -target=null_resource.cleanup_job_performance_alerts
#
# ETAPA 3: VALIDAR LIMPEZA
# ----------------------------------------------------------------------
# aws glue get-crawlers --query "Crawlers[*].Name" --output table
# aws lambda list-functions --query "Functions[*].FunctionName" --output table
# aws glue get-jobs --query "Jobs[*].Name" --output table
#
# ETAPA 4: VERIFICAR WORKFLOW COMPLETO
# ----------------------------------------------------------------------
# aws glue get-workflow --name datalake-pipeline-silver-gold-workflow-dev \
#   --query "Workflow.Graph.Nodes[*].[Type,Name]" --output table
#
# ===================================================================
