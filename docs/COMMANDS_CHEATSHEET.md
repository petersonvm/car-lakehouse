# 🛠️ Comandos Úteis - Glue Job Silver Consolidation

## 📋 Índice Rápido

1. [Deploy](#deploy)
2. [Validação](#validação)
3. [Execução Manual](#execução-manual)
4. [Monitoramento](#monitoramento)
5. [Troubleshooting](#troubleshooting)
6. [Teste End-to-End](#teste-end-to-end)
7. [Manutenção](#manutenção)
8. [Rollback](#rollback)

---

## 🚀 Deploy

### Deploy Automatizado (Recomendado)

```powershell
cd terraform
.\deploy_glue_migration.ps1
```

### Deploy Manual

```bash
# 1. Validar script PySpark
python -m py_compile ../glue_jobs/silver_consolidation_job.py

# 2. Inicializar Terraform (primeira vez)
cd terraform
terraform init

# 3. Validar configuração
terraform validate

# 4. Ver plano de execução
terraform plan

# 5. Aplicar mudanças
terraform apply

# 6. Verificar outputs
terraform output
```

---

## ✅ Validação

### Verificar Glue Job

```bash
# Obter detalhes do Job
aws glue get-job --job-name datalake-pipeline-silver-consolidation-dev

# Ver apenas configurações principais
aws glue get-job --job-name datalake-pipeline-silver-consolidation-dev \
  --query 'Job.{Name:Name,Role:Role,GlueVersion:GlueVersion,WorkerType:WorkerType,NumberOfWorkers:NumberOfWorkers}'
```

### Verificar Trigger

```bash
# Obter detalhes do Trigger
aws glue get-trigger --name datalake-pipeline-silver-consolidation-trigger-dev

# Ver apenas estado e schedule
aws glue get-trigger --name datalake-pipeline-silver-consolidation-trigger-dev \
  --query 'Trigger.{Name:Name,Type:Type,State:State,Schedule:Schedule}'
```

### Verificar Script no S3

```bash
# Listar scripts
aws s3 ls s3://datalake-pipeline-glue-scripts-dev/glue_jobs/

# Ver detalhes do script
aws s3 ls s3://datalake-pipeline-glue-scripts-dev/glue_jobs/silver_consolidation_job.py --human-readable

# Baixar script (verificar conteúdo)
aws s3 cp s3://datalake-pipeline-glue-scripts-dev/glue_jobs/silver_consolidation_job.py - | head -20
```

### Verificar IAM Role

```bash
# Obter detalhes da Role
aws iam get-role --role-name datalake-pipeline-glue-job-role-dev

# Listar políticas anexadas
aws iam list-role-policies --role-name datalake-pipeline-glue-job-role-dev

# Ver conteúdo de uma política
aws iam get-role-policy --role-name datalake-pipeline-glue-job-role-dev \
  --policy-name glue-s3-access
```

### Verificar Buckets S3

```bash
# Verificar bucket de scripts
aws s3 ls s3://datalake-pipeline-glue-scripts-dev/

# Verificar bucket temp
aws s3 ls s3://datalake-pipeline-glue-temp-dev/

# Verificar tamanho dos buckets
aws s3 ls s3://datalake-pipeline-glue-scripts-dev/ --recursive --human-readable --summarize
```

---

## ▶️ Execução Manual

### Iniciar Job

```bash
# Executar job manualmente
aws glue start-job-run --job-name datalake-pipeline-silver-consolidation-dev

# Executar e capturar Job Run ID
JOB_RUN_ID=$(aws glue start-job-run --job-name datalake-pipeline-silver-consolidation-dev --query 'JobRunId' --output text)
echo "Job Run ID: $JOB_RUN_ID"
```

### Verificar Status da Execução

```bash
# Ver última execução
aws glue get-job-runs --job-name datalake-pipeline-silver-consolidation-dev --max-results 1

# Ver status de execução específica
aws glue get-job-run --job-name datalake-pipeline-silver-consolidation-dev --run-id $JOB_RUN_ID

# Ver apenas estado
aws glue get-job-run --job-name datalake-pipeline-silver-consolidation-dev --run-id $JOB_RUN_ID \
  --query 'JobRun.{JobRunState:JobRunState,ExecutionTime:ExecutionTime,ErrorMessage:ErrorMessage}'
```

### Listar Todas as Execuções

```bash
# Últimas 10 execuções
aws glue get-job-runs --job-name datalake-pipeline-silver-consolidation-dev --max-results 10

# Execuções com falha
aws glue get-job-runs --job-name datalake-pipeline-silver-consolidation-dev \
  --query 'JobRuns[?JobRunState==`FAILED`]'

# Execuções bem-sucedidas
aws glue get-job-runs --job-name datalake-pipeline-silver-consolidation-dev \
  --query 'JobRuns[?JobRunState==`SUCCEEDED`]'
```

### Parar Execução

```bash
# Cancelar job em execução
aws glue batch-stop-job-run --job-name datalake-pipeline-silver-consolidation-dev --job-run-ids $JOB_RUN_ID
```

---

## 📊 Monitoramento

### CloudWatch Logs

```bash
# Ver logs em tempo real (tail)
aws logs tail /aws-glue/jobs/datalake-pipeline-silver-consolidation-dev --follow

# Ver logs das últimas 2 horas
aws logs tail /aws-glue/jobs/datalake-pipeline-silver-consolidation-dev --since 2h

# Filtrar logs por palavra-chave
aws logs tail /aws-glue/jobs/datalake-pipeline-silver-consolidation-dev --since 1h --filter-pattern "ERROR"

# Ver logs de execução específica (por timestamp)
aws logs tail /aws-glue/jobs/datalake-pipeline-silver-consolidation-dev \
  --since "2025-10-30T15:00:00" --until "2025-10-30T16:00:00"
```

### Métricas CloudWatch

```bash
# Ver métricas do Glue Job (últimas 24h)
aws cloudwatch get-metric-statistics \
  --namespace Glue \
  --metric-name glue.driver.aggregate.numCompletedStages \
  --dimensions Name=JobName,Value=datalake-pipeline-silver-consolidation-dev \
  --start-time $(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 3600 \
  --statistics Sum
```

### Job Bookmarks

```bash
# Verificar estado dos bookmarks
aws glue get-job-bookmark --job-name datalake-pipeline-silver-consolidation-dev

# Ver apenas informações de progresso
aws glue get-job-bookmark --job-name datalake-pipeline-silver-consolidation-dev \
  --query 'JobBookmarkEntry.{RunId:RunId,Version:Version,JobBookmark:JobBookmark}'
```

### Trigger Status

```bash
# Verificar se trigger está habilitado
aws glue get-trigger --name datalake-pipeline-silver-consolidation-trigger-dev \
  --query 'Trigger.State'

# Verificar próxima execução agendada
aws glue get-trigger --name datalake-pipeline-silver-consolidation-trigger-dev \
  --query 'Trigger.{Schedule:Schedule,State:State}'
```

---

## 🔍 Troubleshooting

### Verificar Erros

```bash
# Ver última execução com falha
aws glue get-job-runs --job-name datalake-pipeline-silver-consolidation-dev \
  --query 'JobRuns[?JobRunState==`FAILED`] | [0]'

# Ver mensagem de erro da última falha
aws glue get-job-runs --job-name datalake-pipeline-silver-consolidation-dev \
  --query 'JobRuns[?JobRunState==`FAILED`] | [0].ErrorMessage'

# Ver logs de erro no CloudWatch
aws logs filter-log-events \
  --log-group-name /aws-glue/jobs/datalake-pipeline-silver-consolidation-dev \
  --filter-pattern "ERROR" \
  --max-items 10
```

### Verificar Permissões IAM

```bash
# Simular acesso S3 Bronze (read)
aws iam simulate-principal-policy \
  --policy-source-arn $(aws iam get-role --role-name datalake-pipeline-glue-job-role-dev --query 'Role.Arn' --output text) \
  --action-names s3:GetObject \
  --resource-arns arn:aws:s3:::datalake-pipeline-bronze-dev/*

# Simular acesso S3 Silver (write)
aws iam simulate-principal-policy \
  --policy-source-arn $(aws iam get-role --role-name datalake-pipeline-glue-job-role-dev --query 'Role.Arn' --output text) \
  --action-names s3:PutObject s3:DeleteObject \
  --resource-arns arn:aws:s3:::datalake-pipeline-silver-dev/*
```

### Verificar Dados

```bash
# Ver arquivos no Bronze
aws s3 ls s3://datalake-pipeline-bronze-dev/ingest_year=2025/ --recursive --human-readable

# Ver arquivos no Silver
aws s3 ls s3://datalake-pipeline-silver-dev/car_telemetry/ --recursive --human-readable

# Contar arquivos por partição
aws s3 ls s3://datalake-pipeline-silver-dev/car_telemetry/event_year=2025/event_month=10/event_day=29/ --recursive | wc -l
```

### Reset Job Bookmarks

```bash
# Resetar bookmarks (reprocessar tudo)
aws glue reset-job-bookmark --job-name datalake-pipeline-silver-consolidation-dev

# Verificar reset
aws glue get-job-bookmark --job-name datalake-pipeline-silver-consolidation-dev
```

### Recriar Job (se necessário)

```bash
# Via Terraform
cd terraform
terraform taint aws_glue_job.silver_consolidation
terraform apply
```

---

## 🧪 Teste End-to-End

### 1. Limpar Dados Anteriores

```bash
# Limpar Silver bucket
aws s3 rm s3://datalake-pipeline-silver-dev/car_telemetry/ --recursive

# Limpar Bronze bucket (opcional)
aws s3 rm s3://datalake-pipeline-bronze-dev/ --recursive

# Remover tabela Silver do Catalog
aws glue delete-table --database-name datalake-pipeline-catalog-dev --name silver_car_telemetry
```

### 2. Upload de Dados de Teste

```bash
# Upload arquivo 1 (carChassis=5ifRW..., mileage=4321)
aws s3 cp test_data/car_raw.json s3://datalake-pipeline-landing-dev/car_raw.json

# Aguardar Lambda Ingestion processar (30-60 segundos)
sleep 60

# Verificar Bronze
aws s3 ls s3://datalake-pipeline-bronze-dev/ingest_year=2025/ --recursive

# Upload arquivo 2 (MESMO carChassis, mileage=8500)
aws s3 cp test_data/car_silver_data_v1.json s3://datalake-pipeline-landing-dev/car_silver_data_v1.json

# Aguardar Lambda Ingestion
sleep 60

# Verificar Bronze novamente
aws s3 ls s3://datalake-pipeline-bronze-dev/ingest_year=2025/ --recursive
```

### 3. Executar Glue Job

```bash
# Iniciar job
JOB_RUN_ID=$(aws glue start-job-run --job-name datalake-pipeline-silver-consolidation-dev --query 'JobRunId' --output text)
echo "Job Run ID: $JOB_RUN_ID"

# Monitorar logs
aws logs tail /aws-glue/jobs/datalake-pipeline-silver-consolidation-dev --follow
```

### 4. Executar Crawler Silver

```bash
# Iniciar crawler
aws glue start-crawler --name datalake-pipeline-silver-crawler-dev

# Verificar status
aws glue get-crawler --name datalake-pipeline-silver-crawler-dev --query 'Crawler.State'

# Aguardar conclusão (pode levar 2-3 minutos)
while [ "$(aws glue get-crawler --name datalake-pipeline-silver-crawler-dev --query 'Crawler.State' --output text)" != "READY" ]; do
  echo "Crawler ainda em execução..."
  sleep 10
done
echo "Crawler concluído!"
```

### 5. Validar no Athena

```bash
# Query 1: Verificar duplicatas (DEVE RETORNAR 0)
aws athena start-query-execution \
  --query-string "SELECT carChassis, event_year, event_month, event_day, COUNT(*) as count FROM silver_car_telemetry GROUP BY carChassis, event_year, event_month, event_day HAVING COUNT(*) > 1;" \
  --result-configuration OutputLocation=s3://datalake-pipeline-athena-results-dev/ \
  --work-group datalake-pipeline-workgroup-dev

# Query 2: Verificar registro consolidado (DEVE RETORNAR mileage=8500)
aws athena start-query-execution \
  --query-string "SELECT carChassis, currentMileage, metrics_metricTimestamp FROM silver_car_telemetry WHERE event_year = '2025' AND event_month = '10' AND event_day = '29' ORDER BY currentMileage DESC;" \
  --result-configuration OutputLocation=s3://datalake-pipeline-athena-results-dev/ \
  --work-group datalake-pipeline-workgroup-dev

# Query 3: Contar total de registros
aws athena start-query-execution \
  --query-string "SELECT COUNT(*) as total FROM silver_car_telemetry;" \
  --result-configuration OutputLocation=s3://datalake-pipeline-athena-results-dev/ \
  --work-group datalake-pipeline-workgroup-dev
```

**OU via Console Athena:**

```sql
-- 1. Verificar duplicatas (esperado: 0 linhas)
SELECT carChassis, event_year, event_month, event_day, COUNT(*) as count
FROM silver_car_telemetry
GROUP BY carChassis, event_year, event_month, event_day
HAVING COUNT(*) > 1;

-- 2. Verificar registro consolidado (esperado: mileage=8500)
SELECT carChassis, currentMileage, metrics_metricTimestamp
FROM silver_car_telemetry
WHERE event_year = '2025' AND event_month = '10' AND event_day = '29'
ORDER BY currentMileage DESC;

-- 3. Contar registros (esperado: 1)
SELECT COUNT(*) as total FROM silver_car_telemetry;
```

---

## 🔧 Manutenção

### Atualizar Script PySpark

```bash
# 1. Modificar script local
vim ../glue_jobs/silver_consolidation_job.py

# 2. Terraform detecta mudança automaticamente
cd terraform
terraform plan
# Output: aws_s3_object.silver_consolidation_script will be updated in-place

# 3. Aplicar mudança
terraform apply

# 4. Próxima execução do Job usará novo script
```

### Ajustar Frequência do Job

```bash
# Via Terraform (editar variables.tf ou usar CLI)
cd terraform

# Opção 1: Alterar para 2×/dia
terraform apply -var="glue_trigger_schedule=cron(0 0,12 * * ? *)"

# Opção 2: Alterar para diário
terraform apply -var="glue_trigger_schedule=cron(0 2 * * ? *)"

# Opção 3: Alterar para semanal (segundas-feiras)
terraform apply -var="glue_trigger_schedule=cron(0 2 ? * MON *)"
```

### Desabilitar/Habilitar Trigger

```bash
# Desabilitar via Terraform
terraform apply -var="glue_trigger_enabled=false"

# Desabilitar via AWS CLI
aws glue stop-trigger --name datalake-pipeline-silver-consolidation-trigger-dev

# Habilitar via AWS CLI
aws glue start-trigger --name datalake-pipeline-silver-consolidation-trigger-dev

# Verificar estado
aws glue get-trigger --name datalake-pipeline-silver-consolidation-trigger-dev --query 'Trigger.State'
```

### Aumentar Capacidade de Processamento

```bash
# Via Terraform
cd terraform
terraform apply \
  -var="glue_worker_type=G.2X" \
  -var="glue_number_of_workers=5"
```

### Ajustar Timeout

```bash
# Via Terraform
terraform apply -var="glue_job_timeout_minutes=120"
```

### Limpar Logs Antigos

```bash
# Ajustar retenção via Terraform
terraform apply -var="cloudwatch_log_retention_days=7"

# Ou deletar log group e recriar
aws logs delete-log-group --log-group-name /aws-glue/jobs/datalake-pipeline-silver-consolidation-dev
terraform apply
```

### Limpar Arquivos Temp

```bash
# Arquivos temp são auto-deletados após 7 dias (lifecycle policy)
# Para limpar manualmente:
aws s3 rm s3://datalake-pipeline-glue-temp-dev/temp/ --recursive
```

---

## 🔄 Rollback

### Rollback Completo (Remover Glue Job)

```bash
# 1. Desabilitar trigger
aws glue stop-trigger --name datalake-pipeline-silver-consolidation-trigger-dev

# 2. Destruir recursos via Terraform
cd terraform
terraform destroy -target=aws_glue_trigger.silver_consolidation_schedule
terraform destroy -target=aws_glue_job.silver_consolidation
terraform destroy -target=aws_iam_role.glue_job
terraform destroy -target=aws_s3_bucket.glue_scripts
terraform destroy -target=aws_s3_bucket.glue_temp

# 3. Restaurar S3 trigger da Lambda Cleansing (se necessário)
# Descomentar código em lambda.tf e executar:
terraform apply
```

### Rollback Parcial (Manter Job, Desabilitar Trigger)

```bash
# Via Terraform
terraform apply -var="glue_trigger_enabled=false"

# Via AWS CLI
aws glue stop-trigger --name datalake-pipeline-silver-consolidation-trigger-dev
```

### Restaurar Estado Terraform

```bash
# Se backup foi criado por deploy_glue_migration.ps1
cd terraform
Copy-Item terraform-backups\terraform-state-YYYYMMDD_HHMMSS.tfstate terraform.tfstate -Force
terraform apply
```

---

## 📊 Custos

### Verificar Custos no AWS Cost Explorer

```bash
# Via Console AWS:
# AWS Cost Explorer → Filters → Service: AWS Glue

# Via CLI (últimos 30 dias)
aws ce get-cost-and-usage \
  --time-period Start=$(date -u -d '30 days ago' +%Y-%m-%d),End=$(date -u +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --filter file://cost-filter.json

# Onde cost-filter.json:
# {
#   "Dimensions": {
#     "Key": "SERVICE",
#     "Values": ["AWS Glue"]
#   }
# }
```

### Estimar Custos Antes do Deploy

```bash
# DPU-hours = execuções/dia × dias × minutos/execução × DPUs / 60
# Exemplo: 24 × 30 × 5 × 2 / 60 = 120 DPU-hours
# Custo = 120 × $0,44 = $52,80/mês

# Calcular para configuração customizada:
# EXECUTIONS_PER_DAY × DAYS × MINUTES_PER_RUN × DPUS / 60 × $0.44
```

---

## 🔐 Segurança

### Verificar Políticas IAM

```bash
# Ver trust policy da role
aws iam get-role --role-name datalake-pipeline-glue-job-role-dev \
  --query 'Role.AssumeRolePolicyDocument'

# Listar todas as políticas
aws iam list-role-policies --role-name datalake-pipeline-glue-job-role-dev

# Ver política S3
aws iam get-role-policy --role-name datalake-pipeline-glue-job-role-dev \
  --policy-name glue-s3-access
```

### Verificar Criptografia S3

```bash
# Verificar criptografia do bucket Silver
aws s3api get-bucket-encryption --bucket datalake-pipeline-silver-dev

# Verificar criptografia de objeto
aws s3api head-object --bucket datalake-pipeline-silver-dev \
  --key car_telemetry/event_year=2025/event_month=10/event_day=29/run-xxx.parquet
```

### Verificar Block Public Access

```bash
# Verificar bucket scripts
aws s3api get-public-access-block --bucket datalake-pipeline-glue-scripts-dev

# Verificar bucket temp
aws s3api get-public-access-block --bucket datalake-pipeline-glue-temp-dev
```

---

## 📝 Notas Importantes

### Job Bookmarks
- **NÃO** delete manualmente arquivos do Bronze durante processamento
- Para reprocessar dados: `aws glue reset-job-bookmark`
- Bookmarks rastreiam por arquivo S3 (não por conteúdo)

### Dynamic Partition Overwrite
- Sobrescreve **apenas** partições afetadas
- Outras partições permanecem intactas
- Essencial para performance em datasets grandes

### Deduplicação
- Regra padrão: `ORDER BY currentMileage DESC` (maior milhagem vence)
- Para alterar regra: editar script PySpark (linha ~250)
- Chave de deduplicação: `carChassis + event_year + event_month + event_day`

### Monitoramento
- Logs retidos por 14 dias (configurável)
- Métricas disponíveis no CloudWatch por 15 meses
- Job Bookmarks armazenados indefinidamente (até reset)

---

**Autor**: Sistema de Data Lakehouse  
**Data**: 2025-10-30  
**Versão**: 1.0
