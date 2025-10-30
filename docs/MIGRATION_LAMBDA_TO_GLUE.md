# Migração: Lambda → Glue Job (Silver Layer)

## 📋 Visão Geral

Esta documentação descreve a migração da arquitetura de processamento da Camada Silver de **Lambda baseado em eventos** para **AWS Glue Job agendado**.

## 🔄 Comparação: Antes vs Depois

### ❌ ANTES (Lambda Event-Driven)

```
Landing → Bronze (Lambda Ingestion) → Silver (Lambda Cleansing)
           ↓                            ↓
      S3 Event Trigger            S3 Event Trigger
```

**Fluxo Antigo:**
1. Arquivo `.json` chega no **Landing**
2. Lambda Ingestion é **acionada automaticamente** (S3 trigger)
3. Processa e grava `.parquet` (nested) no **Bronze**
4. Lambda Cleansing é **acionada automaticamente** (S3 trigger)
5. Processa e **anexa** dados no **Silver**
6. ⚠️ **PROBLEMA**: Múltiplos arquivos para o mesmo `carChassis` + `event_day` geram duplicatas

### ✅ DEPOIS (Glue Job Scheduled)

```
Landing → Bronze (Lambda Ingestion) → Silver (Glue Job Consolidation)
           ↓                            ↓
      S3 Event Trigger            Scheduled Trigger (Hourly)
```

**Fluxo Novo:**
1. Arquivo `.json` chega no **Landing**
2. Lambda Ingestion é **acionada automaticamente** (mantido)
3. Processa e grava `.parquet` (nested) no **Bronze**
4. ⏰ **AWS Glue Job roda de hora em hora** (scheduled)
5. **Lê dados novos** do Bronze (Job Bookmarks)
6. **Carrega dados existentes** do Silver
7. **Aplica deduplicação** com Window function
8. **Sobrescreve partições afetadas** (Dynamic Partition Overwrite)
9. ✅ **SOLUÇÃO**: Apenas 1 registro por `carChassis` + `event_day`

## 🎯 Motivação da Migração

### Por que mudar de Lambda para Glue Job?

| Aspecto | Lambda (Antigo) | Glue Job (Novo) |
|---------|-----------------|-----------------|
| **Trigger** | Evento S3 (cada arquivo) | Agendado (ex: horário) |
| **Processamento** | Individual (arquivo por arquivo) | Batch (lote de arquivos) |
| **Lógica** | Append simples | Upsert com deduplicação |
| **Duplicatas** | ❌ Sim (múltiplos registros) | ✅ Não (apenas 1 registro) |
| **Consolidação** | ❌ Não suportado | ✅ Window functions |
| **Bookmarks** | ❌ Não | ✅ Processa apenas novos |
| **Partition Overwrite** | ❌ Não | ✅ Dynamic (eficiente) |
| **Custo** | Proporcional ao nº de arquivos | Proporcional ao volume de dados |
| **Escalabilidade** | Limitada (15 min timeout) | Alta (horas de execução) |

### Problema Concreto Resolvido

**Cenário:**
- Upload de `car_raw.json` → Bronze → Silver (registro 1)
- Upload de `car_silver_data_v1.json` → Bronze → Silver (registro 2)
- **Mesmo carChassis**, mesma data, milhagem diferente

**Com Lambda (Antigo):**
```sql
SELECT carChassis, currentMileage, event_day
FROM silver_car_telemetry
WHERE event_day = '29';

-- Resultado (DUPLICATAS):
carChassis          | currentMileage | event_day
5ifRW...            | 4321           | 29
5ifRW...            | 8500           | 29   ← Duplicata!
```

**Com Glue Job (Novo):**
```sql
SELECT carChassis, currentMileage, event_day
FROM silver_car_telemetry
WHERE event_day = '29';

-- Resultado (ÚNICO REGISTRO):
carChassis          | currentMileage | event_day
5ifRW...            | 8500           | 29   ← Mantém maior milhagem ✅
```

## 🏗️ Mudanças na Infraestrutura

### Recursos REMOVIDOS

```hcl
# ❌ REMOVIDO: Lambda Permission para S3 invocar cleansing
resource "aws_lambda_permission" "allow_s3_invoke_cleansing" { ... }

# ❌ REMOVIDO: S3 Notification no Bronze bucket
resource "aws_s3_bucket_notification" "bronze_bucket_notification" { ... }
```

### Recursos ADICIONADOS

```hcl
# ✅ NOVO: Bucket para scripts Glue
resource "aws_s3_bucket" "glue_scripts" { ... }

# ✅ NOVO: Upload do script PySpark
resource "aws_s3_object" "silver_consolidation_script" { ... }

# ✅ NOVO: Bucket temporário do Glue
resource "aws_s3_bucket" "glue_temp" { ... }

# ✅ NOVO: IAM Role para Glue Job
resource "aws_iam_role" "glue_job" { ... }
  - Policy: S3 Bronze (read)
  - Policy: S3 Silver (read/write/delete)
  - Policy: Glue Data Catalog (full access)
  - Policy: CloudWatch Logs

# ✅ NOVO: AWS Glue Job
resource "aws_glue_job" "silver_consolidation" { ... }

# ✅ NOVO: Glue Trigger (Scheduled)
resource "aws_glue_trigger" "silver_consolidation_schedule" { ... }

# ✅ NOVO: CloudWatch Log Group
resource "aws_cloudwatch_log_group" "glue_job_logs" { ... }
```

### Recursos MANTIDOS (sem alterações)

- ✅ Lambda Ingestion (Landing → Bronze)
- ✅ S3 Trigger para Ingestion Lambda
- ✅ Lambda Cleansing function (mantida, mas não acionada)
- ✅ Todos os S3 buckets (landing, bronze, silver, gold)
- ✅ Glue Crawlers (bronze, silver)
- ✅ Athena Workgroup

## 📦 Arquivos Terraform Modificados

### 1. `terraform/glue_jobs.tf` (NOVO)

**O que contém:**
- Bucket S3 para scripts Glue
- Upload do script PySpark
- IAM Role com políticas granulares
- AWS Glue Job com configuração completa
- Glue Trigger (agendamento horário)
- CloudWatch Log Group

**Linhas de código:** ~400

### 2. `terraform/lambda.tf` (MODIFICADO)

**O que mudou:**
- ❌ Removido: `aws_lambda_permission.allow_s3_invoke_cleansing`
- ❌ Removido: `aws_s3_bucket_notification.bronze_bucket_notification`
- ✅ Adicionado: Comentário explicativo sobre a migração

**Mantido intacto:**
- Lambda Ingestion (Landing → Bronze)
- Lambda Cleansing function (pode ser removida posteriormente)
- S3 Trigger para Ingestion

### 3. `terraform/variables.tf` (MODIFICADO)

**Variáveis adicionadas:**
- `glue_silver_script_path`: Caminho do script PySpark
- `glue_version`: Versão do Glue (default: 4.0)
- `glue_worker_type`: Tipo de worker (default: G.1X)
- `glue_number_of_workers`: Número de workers (default: 2)
- `glue_job_timeout_minutes`: Timeout do job (default: 60)
- `glue_trigger_schedule`: Cron expression (default: horário)
- `bronze_table_name`: Nome da tabela Bronze
- `silver_table_name`: Nome da tabela Silver
- `silver_path`: Path no bucket Silver
- `cloudwatch_log_retention_days`: Retenção de logs

## 🚀 Como Aplicar a Migração

### Passo 1: Validar o Script PySpark

```bash
# Verificar se o script existe
ls ../glue_jobs/silver_consolidation_job.py

# Validar sintaxe Python
python -m py_compile ../glue_jobs/silver_consolidation_job.py
```

### Passo 2: Inicializar Terraform (se necessário)

```bash
cd terraform
terraform init
```

### Passo 3: Revisar o Plano de Execução

```bash
terraform plan
```

**O que esperar:**
```
Plan: 11 to add, 0 to change, 2 to destroy.

Resources to ADD:
  + aws_s3_bucket.glue_scripts
  + aws_s3_bucket.glue_temp
  + aws_s3_object.silver_consolidation_script
  + aws_iam_role.glue_job
  + aws_iam_role_policy.glue_s3_access
  + aws_iam_role_policy.glue_catalog_access
  + aws_iam_role_policy.glue_cloudwatch_logs
  + aws_glue_job.silver_consolidation
  + aws_glue_trigger.silver_consolidation_schedule
  + aws_cloudwatch_log_group.glue_job_logs
  + data sources...

Resources to DESTROY:
  - aws_lambda_permission.allow_s3_invoke_cleansing
  - aws_s3_bucket_notification.bronze_bucket_notification
```

### Passo 4: Aplicar as Mudanças

```bash
terraform apply
```

**Confirme com:** `yes`

### Passo 5: Validar a Criação

```bash
# Verificar Glue Job
aws glue get-job --job-name datalake-pipeline-silver-consolidation-dev

# Verificar Trigger
aws glue get-trigger --name datalake-pipeline-silver-consolidation-trigger-dev

# Listar scripts no S3
aws s3 ls s3://datalake-pipeline-glue-scripts-dev/glue_jobs/
```

## 🧪 Testando a Nova Arquitetura

### Teste 1: Executar Glue Job Manualmente

```bash
# Iniciar job
aws glue start-job-run \
  --job-name datalake-pipeline-silver-consolidation-dev

# Verificar status
aws glue get-job-runs \
  --job-name datalake-pipeline-silver-consolidation-dev \
  --max-results 1
```

### Teste 2: Upload de Dados de Teste

```bash
# Upload arquivo 1
aws s3 cp test_data/car_raw.json \
  s3://datalake-pipeline-landing-dev/car_raw.json

# Aguardar Lambda Ingestion processar (30-60 segundos)

# Upload arquivo 2 (mesmo carChassis, milhagem diferente)
aws s3 cp test_data/car_silver_data_v1.json \
  s3://datalake-pipeline-landing-dev/car_silver_data_v1.json

# Aguardar Lambda Ingestion processar

# Executar Glue Job
aws glue start-job-run \
  --job-name datalake-pipeline-silver-consolidation-dev

# Aguardar job concluir (verificar CloudWatch Logs)
```

### Teste 3: Validar Deduplicação no Athena

```sql
-- Executar crawler primeiro
-- AWS Console → Glue → Crawlers → silver-crawler → Run

-- Verificar duplicatas (deve retornar 0)
SELECT carChassis, event_year, event_month, event_day, COUNT(*) as count
FROM silver_car_telemetry
GROUP BY carChassis, event_year, event_month, event_day
HAVING COUNT(*) > 1;

-- Verificar registro consolidado (deve mostrar apenas o de maior milhagem)
SELECT carChassis, currentMileage, metrics_metricTimestamp
FROM silver_car_telemetry
WHERE event_year = '2025' AND event_month = '10' AND event_day = '29'
ORDER BY currentMileage DESC;
```

**Resultado esperado:**
```
carChassis                              | currentMileage
5ifRW9gP5zZoInGkEhwYR2gO5cLdR1SZrOdY... | 8500          ← Único registro
```

## 📊 Monitoramento

### CloudWatch Logs

```bash
# Ver logs do Glue Job
aws logs tail /aws-glue/jobs/datalake-pipeline-silver-consolidation-dev --follow
```

### CloudWatch Metrics

No Console AWS:
- **CloudWatch → Metrics → Glue → JobName**
- Métricas importantes:
  - `glue.driver.ExecutorAllocationManager.executors.numberAllExecutors`
  - `glue.ALL.s3.filesystem.read_bytes`
  - `glue.ALL.s3.filesystem.write_bytes`
  - `glue.driver.aggregate.numCompletedStages`

### Glue Job Bookmarks

```bash
# Verificar estado dos bookmarks
aws glue get-job-bookmark \
  --job-name datalake-pipeline-silver-consolidation-dev
```

## ⚙️ Configurações Personalizáveis

### Frequência do Job (terraform/variables.tf)

```hcl
variable "glue_trigger_schedule" {
  default = "cron(0 */1 * * ? *)"  # A cada hora
  
  # Outras opções:
  # "cron(0 */2 * * ? *)"   # A cada 2 horas
  # "cron(0 0 * * ? *)"     # Diariamente à meia-noite UTC
  # "cron(0 2 * * ? *)"     # Diariamente às 2 AM UTC
  # "cron(0 0 ? * MON *)"   # Semanalmente às segundas-feiras
}
```

### Capacidade de Processamento

```hcl
variable "glue_worker_type" {
  default = "G.1X"  # 4 vCPU, 16 GB RAM
  
  # Outras opções:
  # "G.025X"  # 2 vCPU, 4 GB RAM (mais barato)
  # "G.2X"    # 8 vCPU, 32 GB RAM (mais potente)
}

variable "glue_number_of_workers" {
  default = 2
  
  # Ajuste conforme volume de dados:
  # 2-5 workers: Até 1 GB de dados novos/hora
  # 5-10 workers: 1-10 GB de dados novos/hora
  # 10+ workers: >10 GB de dados novos/hora
}
```

### Timeout e Retries

```hcl
variable "glue_job_timeout_minutes" {
  default = 60  # 1 hora
  
  # Ajuste se job demorar mais
}

variable "glue_job_max_retries" {
  default = 1
  
  # Aumentar se houver falhas transitórias (ex: throttling S3)
}
```

## 🔧 Troubleshooting

### Problema: Job não inicia

**Sintoma:**
```
Trigger habilitado, mas Job não executa no horário agendado
```

**Verificações:**
```bash
# 1. Verificar se trigger está habilitado
aws glue get-trigger --name datalake-pipeline-silver-consolidation-trigger-dev

# 2. Verificar permissões IAM
aws iam get-role --role-name datalake-pipeline-glue-job-role-dev

# 3. Verificar CloudWatch Events
aws events list-rules --name-prefix datalake-pipeline
```

### Problema: Job falha com erro de permissão S3

**Sintoma:**
```
AccessDeniedException: User: arn:aws:sts::...:assumed-role/glue-job-role/GlueJobRunnerSession is not authorized to perform: s3:GetObject
```

**Solução:**
```bash
# Verificar políticas IAM
terraform state show aws_iam_role_policy.glue_s3_access

# Recriar se necessário
terraform taint aws_iam_role_policy.glue_s3_access
terraform apply
```

### Problema: Job processa dados antigos (Bookmarks não funcionam)

**Sintoma:**
```
Job reprocessa arquivos já processados do Bronze
```

**Solução:**
```bash
# Verificar se bookmarks estão habilitados
aws glue get-job --job-name datalake-pipeline-silver-consolidation-dev \
  --query 'Job.DefaultArguments."--job-bookmark-option"'

# Resultado esperado: "job-bookmark-enable"

# Se necessário, resetar bookmarks
aws glue reset-job-bookmark \
  --job-name datalake-pipeline-silver-consolidation-dev
```

### Problema: Partições não são sobrescritas (dados duplicados)

**Sintoma:**
```
Query no Athena retorna múltiplos registros para mesmo carChassis + event_day
```

**Solução:**
```bash
# Verificar configuração Spark
aws glue get-job --job-name datalake-pipeline-silver-consolidation-dev \
  --query 'Job.DefaultArguments."--conf"'

# Resultado esperado: "spark.sql.sources.partitionOverwriteMode=dynamic"

# Se ausente, atualizar terraform/glue_jobs.tf e recriar Job
terraform taint aws_glue_job.silver_consolidation
terraform apply
```

## 💰 Estimativa de Custos

### Lambda (Arquitetura Antiga)

**Premissas:**
- 100 uploads/dia ao Bronze
- Cada execução: 1024 MB, 30 segundos
- Região: us-east-1

**Cálculo:**
```
Requests: 100/dia × 30 dias = 3.000/mês
Compute: 3.000 × 30s × (1024/1024) GB = 90.000 GB-s

Custo Requests: $0,20 por 1M requests = $0,0006
Custo Compute: $0,0000166667 por GB-s = $1,50
Total: ~$1,50/mês
```

### Glue Job (Arquitetura Nova)

**Premissas:**
- Job roda 24×/dia (a cada hora)
- Cada execução: 2 DPUs, 5 minutos
- Região: us-east-1

**Cálculo:**
```
Runs: 24/dia × 30 dias = 720/mês
Compute: 720 × 5min × 2 DPUs = 7.200 DPU-minutes = 120 DPU-hours

Custo: $0,44 por DPU-hour = $52,80/mês
Total: ~$53/mês
```

### Comparação

| Item | Lambda | Glue Job | Diferença |
|------|--------|----------|-----------|
| Custo Mensal | $1,50 | $53,00 | +$51,50 |
| Duplicatas | ❌ Sim | ✅ Não | - |
| Consolidação | ❌ Não | ✅ Sim | - |
| Escalabilidade | ⚠️ Limitada | ✅ Alta | - |

**Conclusão:** Glue Job é mais caro, mas resolve o problema de duplicatas e oferece melhor consolidação de dados.

**Otimização de custos:**
- Reduzir frequência: horário → 2×/dia = $4,40/mês
- Usar workers menores: G.025X se volume baixo
- Habilitar auto-scaling

## 📝 Próximos Passos

1. ✅ **Aplicar Terraform** (`terraform apply`)
2. ✅ **Executar teste manual** do Glue Job
3. ✅ **Validar deduplicação** com dados de teste
4. ⏳ **Monitorar execuções** por 1 semana
5. ⏳ **Ajustar schedule** se necessário
6. ⏳ **Remover Lambda Cleansing** (opcional, após validação)
7. ⏳ **Documentar runbooks** de operação

## 📚 Referências

- [AWS Glue Job Bookmarks](https://docs.aws.amazon.com/glue/latest/dg/monitor-continuations.html)
- [Dynamic Partition Overwrite](https://docs.aws.amazon.com/glue/latest/dg/aws-glue-programming-etl-partitions.html)
- [Spark Window Functions](https://spark.apache.org/docs/latest/api/python/reference/pyspark.sql/window.html)
- [Glue Job Parameters](https://docs.aws.amazon.com/glue/latest/dg/aws-glue-programming-etl-glue-arguments.html)

---

**Autor**: Sistema de Data Lakehouse  
**Data**: 2025-10-30  
**Versão**: 1.0  
**Status**: Migração Planejada
