# ============================================================================
# LIMPEZA DE RECURSOS LEGADOS - Economia de Custos
# ============================================================================
#
# Este arquivo contém as definições de recursos legados que devem ser
# removidos do Data Catalog para economizar custos e evitar confusão.
#
# INSTRUÇÕES DE USO:
# 1. Para remover os recursos legados, descomente os blocos abaixo
# 2. Execute: terraform import <resource_type>.<resource_name> <resource_id>
# 3. Execute: terraform destroy -target=<resource_type>.<resource_name>
# 4. Após a remoção, exclua manualmente os dados órfãos do S3
#
# ============================================================================

# ============================================================================
# RECURSO LEGADO 1: Tabela Silver Antiga (silver_car_telemetry_new)
# ============================================================================
# 
# MOTIVO DA REMOÇÃO:
# - Substituída pela nova tabela "car_silver" com schema otimizado
# - Causa confusão com nomenclatura inconsistente
# - Gera custos no Glue Data Catalog sem utilidade
#
# DADOS ÓRFÃOS NO S3:
# - s3://datalake-pipeline-silver-dev/car_telemetry_new/
#
# AÇÃO MANUAL APÓS TERRAFORM DESTROY:
# - aws s3 rm s3://datalake-pipeline-silver-dev/car_telemetry_new/ --recursive
# - Ou via Console S3: Navegue até o bucket e exclua a pasta "car_telemetry_new/"
#
# DESCOMENTE PARA REMOVER:
/*
resource "aws_glue_catalog_table" "silver_car_telemetry_new_legacy" {
  name          = "silver_car_telemetry_new"
  database_name = aws_glue_catalog_database.data_lake_database.name
  
  lifecycle {
    prevent_destroy = false
  }

  # Este é apenas um placeholder para permitir o import e posterior destroy
  # O schema real não importa pois será destruído
  table_type = "EXTERNAL_TABLE"
  
  storage_descriptor {
    location = "s3://${aws_s3_bucket.data_lake["silver"].bucket}/car_telemetry_new/"
    
    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }
  }
}
*/

# ============================================================================
# RECURSO LEGADO 2: Tabela Gold Alerts Não-Slim (performance_alerts_log)
# ============================================================================
#
# MOTIVO DA REMOÇÃO:
# - Substituída pela versão otimizada "gold_performance_alerts_slim"
# - Schema "inchado" com colunas desnecessárias
# - Gera custos elevados de armazenamento e processamento
# - Versão Slim reduziu tamanho em ~60% mantendo KPIs críticos
#
# DADOS ÓRFÃOS NO S3:
# - s3://datalake-pipeline-gold-dev/performance_alerts_log/
#
# AÇÃO MANUAL APÓS TERRAFORM DESTROY:
# - aws s3 rm s3://datalake-pipeline-gold-dev/performance_alerts_log/ --recursive
# - Economia estimada: ~40-60% do armazenamento S3 da camada Gold de Alerts
#
# DESCOMENTE PARA REMOVER:
/*
resource "aws_glue_catalog_table" "performance_alerts_log_legacy" {
  name          = "performance_alerts_log"
  database_name = aws_glue_catalog_database.data_lake_database.name
  
  lifecycle {
    prevent_destroy = false
  }

  table_type = "EXTERNAL_TABLE"
  
  storage_descriptor {
    location = "s3://${aws_s3_bucket.data_lake["gold"].bucket}/performance_alerts_log/"
    
    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }
  }
}
*/

# ============================================================================
# RECURSO LEGADO 3: Tabela Gold Current State Antiga (gold_car_current_state)
# ============================================================================
#
# MOTIVO DA REMOÇÃO:
# - Substituída pela versão "_new" com KPIs de seguro adicionados
# - Nome sem sufixo "_new" causa confusão com nova nomenclatura
# - Pode estar retornando dados desatualizados em queries
#
# DADOS ÓRFÃOS NO S3:
# - s3://datalake-pipeline-gold-dev/car_current_state/
#   (Se diferente do path da tabela "_new")
#
# AÇÃO MANUAL APÓS TERRAFORM DESTROY:
# - Verificar se o path S3 é diferente da tabela "_new"
# - Se diferente: aws s3 rm s3://datalake-pipeline-gold-dev/car_current_state/ --recursive
# - Se igual: NÃO EXECUTAR (dados ainda em uso pela tabela "_new")
#
# NOTA IMPORTANTE:
# Verifique o storage_descriptor.location da tabela "gold_car_current_state_new"
# antes de executar a limpeza S3. Se ambas apontam para o mesmo path, 
# APENAS remova a tabela do Catalog (não exclua dados S3).
#
# DESCOMENTE PARA REMOVER (APENAS SE CONFIRMADO PATH DIFERENTE):
/*
resource "aws_glue_catalog_table" "gold_car_current_state_legacy" {
  name          = "gold_car_current_state"
  database_name = aws_glue_catalog_database.data_lake_database.name
  
  lifecycle {
    prevent_destroy = false
  }

  table_type = "EXTERNAL_TABLE"
  
  storage_descriptor {
    location = "s3://${aws_s3_bucket.data_lake["gold"].bucket}/car_current_state/"
    
    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }
  }
}
*/

# ============================================================================
# INSTRUÇÕES DE EXECUÇÃO - PROCESSO SEGURO DE LIMPEZA
# ============================================================================
#
# PASSO 1: BACKUP DOS DADOS (RECOMENDADO)
# ----------------------------------------
# Antes de executar qualquer destroy, faça backup dos dados S3:
#
# aws s3 sync s3://datalake-pipeline-silver-dev/car_telemetry_new/ \
#              s3://datalake-pipeline-backups-dev/silver_legacy_backup/
#
# aws s3 sync s3://datalake-pipeline-gold-dev/performance_alerts_log/ \
#              s3://datalake-pipeline-backups-dev/gold_alerts_legacy_backup/
#
#
# PASSO 2: IMPORT DOS RECURSOS LEGADOS NO TERRAFORM STATE
# --------------------------------------------------------
# Para cada recurso que deseja remover, execute:
#
# terraform import aws_glue_catalog_table.silver_car_telemetry_new_legacy \
#   datalake-pipeline-catalog-dev:silver_car_telemetry_new
#
# terraform import aws_glue_catalog_table.performance_alerts_log_legacy \
#   datalake-pipeline-catalog-dev:performance_alerts_log
#
# terraform import aws_glue_catalog_table.gold_car_current_state_legacy \
#   datalake-pipeline-catalog-dev:gold_car_current_state
#
#
# PASSO 3: DESTRUIR OS RECURSOS DO GLUE CATALOG
# ----------------------------------------------
# Descomente os blocos acima e execute:
#
# terraform destroy -target=aws_glue_catalog_table.silver_car_telemetry_new_legacy
# terraform destroy -target=aws_glue_catalog_table.performance_alerts_log_legacy
# terraform destroy -target=aws_glue_catalog_table.gold_car_current_state_legacy
#
#
# PASSO 4: LIMPEZA MANUAL DOS DADOS ÓRFÃOS NO S3
# -----------------------------------------------
# Após confirmar que as tabelas foram removidas e não há impacto:
#
# # Remover dados Silver legados
# aws s3 rm s3://datalake-pipeline-silver-dev/car_telemetry_new/ --recursive
#
# # Remover dados Gold Alerts legados
# aws s3 rm s3://datalake-pipeline-gold-dev/performance_alerts_log/ --recursive
#
# # Remover dados Gold Current State legados (APENAS SE PATH DIFERENTE)
# # Verifique primeiro se não é o mesmo path da tabela "_new"!
# aws s3 ls s3://datalake-pipeline-gold-dev/car_current_state/
# # Se retornar dados E for diferente de gold_car_current_state_new:
# aws s3 rm s3://datalake-pipeline-gold-dev/car_current_state/ --recursive
#
#
# PASSO 5: VERIFICAÇÃO PÓS-LIMPEZA
# ---------------------------------
# Confirme que apenas as tabelas corretas existem:
#
# aws glue get-tables --database-name datalake-pipeline-catalog-dev \
#   --query 'TableList[*].Name' --output table
#
# Tabelas esperadas após limpeza:
# - car_silver (Silver)
# - gold_car_current_state_new (Gold)
# - gold_fuel_efficiency (Gold)
# - gold_performance_alerts_slim (Gold)
#
# ============================================================================
# ECONOMIA DE CUSTOS ESTIMADA
# ============================================================================
#
# 1. Glue Data Catalog:
#    - 3 tabelas removidas × $1/mês = $3/mês economizados
#    - (Valores podem variar por região e volume de acesso)
#
# 2. S3 Storage:
#    - Silver legado: ~5-10 GB (estimativa) → $0.10-0.23/mês
#    - Gold Alerts legado: ~40-60% dos dados de alerts → $0.50-2.00/mês
#    - Total estimado: $0.60-2.23/mês em armazenamento S3
#
# 3. Athena Query Costs:
#    - Redução de confusão = menos queries acidentais em tabelas erradas
#    - Economia indireta difícil de quantificar
#
# 4. Custos de Manutenção:
#    - Redução de complexidade operacional
#    - Menor risco de erros por nomenclatura inconsistente
#    - Economia de tempo de desenvolvedores
#
# TOTAL ESTIMADO: $3.60-5.23/mês + economias operacionais indiretas
# ANUAL: ~$43-63/ano + melhor governança de dados
#
# ============================================================================
