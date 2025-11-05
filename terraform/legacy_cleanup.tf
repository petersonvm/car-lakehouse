# ================================================================================
# Limpeza de Recursos Legados - Data Lakehouse
# ================================================================================
# Descrição: Remove componentes órfãos e obsoletos para economizar custos
# Componentes: Crawlers legados, Jobs obsoletos, Tabelas não utilizadas
# Atualizado: 05/11/2025 - Pós-validação QA e refatoração Silver→Gold
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
# NOTA IMPORTANTE: ESTRATÉGIA DE REMOÇÃO
# ================================================================================
# Este arquivo NÃO cria recursos. Ele documenta os recursos a serem removidos.
# 
# Para remover recursos gerenciados pelo Terraform:
# 1. Remova os blocos de recurso dos arquivos .tf originais
# 2. Execute: terraform plan
# 3. Execute: terraform apply (Terraform destruirá os recursos removidos)
#
# Para remover recursos NÃO gerenciados pelo Terraform:
# 1. Use os data sources abaixo para verificar existência
# 2. Execute os comandos AWS CLI comentados em cada seção
# ================================================================================

# ================================================================================
# VARIÁVEIS
# ================================================================================

variable "aws_region" {
  description = "Região AWS"
  type        = string
  default     = "us-east-1"
}

variable "database_name" {
  description = "Nome do database Glue Catalog"
  type        = string
  default     = "datalake-pipeline-catalog-dev"
}

variable "legacy_crawler_performance_alerts_name" {
  description = "Nome do crawler órfão de performance alerts"
  type        = string
  default     = "datalake-pipeline-gold-performance-alerts-crawler-dev"
}

variable "legacy_job_performance_alerts_name" {
  description = "Nome do job legado de performance alerts"
  type        = string
  default     = "datalake-pipeline-gold-performance-alerts-dev"
}

variable "test_job_silver_name" {
  description = "Nome do job de teste Silver"
  type        = string
  default     = "silver-test-job"
}

variable "legacy_table_silver_car_telemetry_new" {
  description = "Nome da tabela Silver legada"
  type        = string
  default     = "silver_car_telemetry_new"
}

# ================================================================================
# 1. REMOÇÃO: Crawler Legado de Performance Alerts (Órfão)
# ================================================================================
# Justificativa: Tabela 'performance_alerts_log' foi deletada em 05/11/2025
# Impacto: Economia de ~$0.44/hora de execução + limpeza do catálogo
# Status: Crawler órfão (target não existe)

data "aws_glue_crawler" "legacy_performance_alerts_crawler" {
  name = var.legacy_crawler_performance_alerts_name
}

# AÇÃO MANUAL: Remover via AWS CLI
# aws glue delete-crawler \
#   --name datalake-pipeline-gold-performance-alerts-crawler-dev \
#   --region us-east-1

# Ou via Console AWS:
# 1. AWS Glue Console → Crawlers
# 2. Selecionar: datalake-pipeline-gold-performance-alerts-crawler-dev
# 3. Actions → Delete

# ================================================================================
# 2. REMOÇÃO: Job Legado Gold Performance Alerts (Substituído)
# ================================================================================
# Justificativa: Substituído por 'gold-performance-alerts-slim-dev' em 05/11/2025
# Impacto: Economia de ~$0.44/DPU-hora + redução de complexidade
# Status: Marcado como "legado" no inventário

data "aws_glue_job" "legacy_performance_alerts_job" {
  name = var.legacy_job_performance_alerts_name
}

# AÇÃO MANUAL: Remover via AWS CLI
# aws glue delete-job \
#   --job-name datalake-pipeline-gold-performance-alerts-dev \
#   --region us-east-1

# Ou via Console AWS:
# 1. AWS Glue Console → ETL Jobs
# 2. Selecionar: datalake-pipeline-gold-performance-alerts-dev
# 3. Actions → Delete

# ================================================================================
# 3. REMOÇÃO: Job de Teste Silver (Desenvolvimento)
# ================================================================================
# Justificativa: Job de teste/desenvolvimento - não utilizado em produção
# Impacto: Economia de custos + limpeza do ambiente
# Status: Marcado como "desenvolvimento" no inventário

data "aws_glue_job" "test_silver_job" {
  name = var.test_job_silver_name
}

# AÇÃO MANUAL: Remover via AWS CLI
# aws glue delete-job \
#   --job-name silver-test-job \
#   --region us-east-1

# ================================================================================
# 4. VERIFICAÇÃO: Tabela Silver Car Telemetry New (Se ainda existir)
# ================================================================================
# Justificativa: Substituída por 'silver_car_telemetry' - marcada como deletada no histórico
# Impacto: Limpeza do catálogo (sem custo direto)
# Status: Deve ter sido removida, mas verificar para garantir

data "aws_glue_catalog_table" "legacy_silver_table" {
  database_name = var.database_name
  name          = var.legacy_table_silver_car_telemetry_new
}

# AÇÃO MANUAL: Remover via AWS CLI (se ainda existir)
# aws glue delete-table \
#   --database-name datalake-pipeline-catalog-dev \
#   --name silver_car_telemetry_new \
#   --region us-east-1

# ================================================================================
# 5. AÇÃO PÓS-REMOÇÃO: Limpeza de Dados Órfãos no S3
# ================================================================================
# Após remover tabelas do Glue Catalog, os arquivos Parquet no S3 permanecem
# e continuam gerando custos de armazenamento (~$0.023/GB/mês)

# DADOS ÓRFÃOS IDENTIFICADOS:
# 1. s3://datalake-pipeline-gold-dev/performance_alerts_log/
#    - Tabela deletada, dados órfãos
#    - Executar crawler retornou 0 tabelas criadas
#
# 2. s3://datalake-pipeline-silver-dev/silver_car_telemetry_new/ (se existir)
#    - Tabela migrada para silver_car_telemetry

# AÇÃO MANUAL: Listar e revisar dados antes de deletar
# aws s3 ls s3://datalake-pipeline-gold-dev/performance_alerts_log/ --recursive --human-readable --summarize

# AÇÃO MANUAL: Backup (opcional, se necessário auditoria)
# aws s3 sync \
#   s3://datalake-pipeline-gold-dev/performance_alerts_log/ \
#   s3://datalake-pipeline-archive-dev/backups/performance_alerts_log_backup_20251105/

# AÇÃO MANUAL: Deletar dados órfãos (CUIDADO: Ação irreversível!)
# aws s3 rm s3://datalake-pipeline-gold-dev/performance_alerts_log/ --recursive

# Verificar espaço liberado
# aws s3 ls s3://datalake-pipeline-gold-dev/ --recursive --summarize

# ================================================================================
# OUTPUTS - Informações sobre recursos a remover
# ================================================================================

output "legacy_resources_summary" {
  description = "Resumo dos recursos legados identificados para remoção"
  value = {
    crawlers_to_remove = [
      var.legacy_crawler_performance_alerts_name
    ]
    jobs_to_remove = [
      var.legacy_job_performance_alerts_name,
      var.test_job_silver_name
    ]
    tables_to_verify = [
      var.legacy_table_silver_car_telemetry_new
    ]
    s3_paths_to_clean = [
      "s3://datalake-pipeline-gold-dev/performance_alerts_log/",
      "s3://datalake-pipeline-silver-dev/silver_car_telemetry_new/ (verificar existência)"
    ]
  }
}

output "estimated_cost_savings" {
  description = "Estimativa de economia mensal (USD) - valores aproximados"
  value = {
    crawler_executions  = "~$2-5/mês (1 crawler órfão removido)"
    unused_jobs         = "~$0 (jobs não executados, mas limpeza de ambiente)"
    s3_storage_cleanup  = "~$0.50-2/mês (dependendo do volume de dados órfãos)"
    total_estimated     = "~$2.50-7/mês + redução de complexidade operacional"
  }
}

output "cleanup_checklist" {
  description = "Checklist de ações manuais para limpeza completa"
  value = {
    step_1 = "✅ Revisar data sources acima para confirmar recursos existem"
    step_2 = "🗑️ Executar comandos AWS CLI para deletar crawlers/jobs legados"
    step_3 = "📊 Listar dados órfãos no S3 (aws s3 ls)"
    step_4 = "💾 (Opcional) Fazer backup de dados para auditoria"
    step_5 = "🗑️ Deletar dados órfãos do S3 (aws s3 rm --recursive)"
    step_6 = "✅ Validar remoção e verificar economia de custos no Cost Explorer"
    step_7 = "📝 Atualizar INVENTARIO_AWS.md removendo recursos deletados"
  }
}

output "manual_commands_reference" {
  description = "Comandos AWS CLI prontos para execução (revisar antes de usar)"
  value = {
    delete_legacy_crawler = "aws glue delete-crawler --name ${var.legacy_crawler_performance_alerts_name} --region ${var.aws_region}"
    delete_legacy_job     = "aws glue delete-job --job-name ${var.legacy_job_performance_alerts_name} --region ${var.aws_region}"
    delete_test_job       = "aws glue delete-job --job-name ${var.test_job_silver_name} --region ${var.aws_region}"
    list_s3_orphan_data   = "aws s3 ls s3://datalake-pipeline-gold-dev/performance_alerts_log/ --recursive --summarize"
    delete_s3_orphan_data = "aws s3 rm s3://datalake-pipeline-gold-dev/performance_alerts_log/ --recursive"
  }
}

# ================================================================================
# NOTAS ADICIONAIS
# ================================================================================
# 
# 1. SEGURANÇA: Sempre faça backup antes de deletar dados do S3
# 2. CUSTOS: Use AWS Cost Explorer para validar economia pós-limpeza
# 3. AUDITORIA: Documente todas as remoções para compliance
# 4. VALIDAÇÃO: Após limpeza, execute o workflow e valide integridade do pipeline
# 5. DOCUMENTAÇÃO: Atualize INVENTARIO_AWS.md após conclusão
#
# ================================================================================
#    - Redução de complexidade operacional
#    - Menor risco de erros por nomenclatura inconsistente
#    - Economia de tempo de desenvolvedores
#
# TOTAL ESTIMADO: $3.60-5.23/mês + economias operacionais indiretas
# ANUAL: ~$43-63/ano + melhor governança de dados
#
# ============================================================================
