# Terraform - Infraestrutura AWS Glue Job

## 📁 Estrutura de Arquivos

```
terraform/
├── glue_jobs.tf                    # ✅ NOVO - Infraestrutura Glue Job
├── lambda.tf                       # 🔄 MODIFICADO - Removido S3 trigger cleansing
├── variables.tf                    # 🔄 MODIFICADO - Adicionadas variáveis Glue
├── s3.tf                          # ⚪ SEM ALTERAÇÕES
├── glue.tf                        # ⚪ SEM ALTERAÇÕES (crawlers)
├── iam.tf                         # ⚪ SEM ALTERAÇÕES
├── athena.tf                      # ⚪ SEM ALTERAÇÕES
├── outputs.tf                     # ⚪ SEM ALTERAÇÕES
├── provider.tf                    # ⚪ SEM ALTERAÇÕES
├── deploy_glue_migration.ps1      # ✅ NOVO - Script de deploy automatizado
└── terraform-backups/             # ✅ NOVO - Diretório para backups
```

## 🎯 O que foi criado: `glue_jobs.tf`

### Recursos Provisionados

#### 1️⃣ **S3 Buckets**
```hcl
aws_s3_bucket.glue_scripts       # Scripts PySpark
aws_s3_bucket.glue_temp          # Arquivos temporários do Glue
```

**Propósito:**
- `glue_scripts`: Armazena o script `silver_consolidation_job.py`
- `glue_temp`: Usado pelo Glue para arquivos temporários durante execução

**Configurações:**
- ✅ Versionamento habilitado (scripts)
- ✅ Block Public Access
- ✅ Lifecycle policy (temp bucket: delete após 7 dias)

#### 2️⃣ **Upload do Script**
```hcl
aws_s3_object.silver_consolidation_script
```

**Propósito:**
- Faz upload do script PySpark local para o S3
- Detecta mudanças via `filemd5()` (re-upload automático)

**Path local:** `../glue_jobs/silver_consolidation_job.py`  
**Path S3:** `s3://datalake-pipeline-glue-scripts-dev/glue_jobs/silver_consolidation_job.py`

#### 3️⃣ **IAM Role para Glue**
```hcl
aws_iam_role.glue_job                        # Role principal
aws_iam_role_policy.glue_s3_access          # Acesso S3
aws_iam_role_policy.glue_catalog_access     # Acesso Glue Catalog
aws_iam_role_policy.glue_cloudwatch_logs    # Acesso CloudWatch
```

**Políticas Implementadas:**

| Política | Recursos | Permissões |
|----------|----------|------------|
| **glue_s3_access** | Bronze bucket | `s3:GetObject`, `s3:ListBucket` |
|  | Silver bucket | `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket` |
|  | Scripts bucket | `s3:GetObject`, `s3:ListBucket` |
|  | Temp bucket | `s3:*` |
| **glue_catalog_access** | Glue Database | `glue:Get*`, `glue:Create*`, `glue:Update*`, `glue:Delete*` |
|  | Glue Tables | `glue:*Partition*`, `glue:*Table*` |
| **glue_cloudwatch_logs** | CloudWatch Logs | `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents` |

**Princípio de Menor Privilégio:**
- ✅ Bronze: **Somente leitura** (input imutável)
- ✅ Silver: **Leitura/Escrita/Delete** (necessário para Dynamic Partition Overwrite)
- ✅ Gold: **Sem acesso** (não usado neste job)

#### 4️⃣ **AWS Glue Job**
```hcl
aws_glue_job.silver_consolidation
```

**Configuração:**

| Parâmetro | Valor | Descrição |
|-----------|-------|-----------|
| `name` | `datalake-pipeline-silver-consolidation-dev` | Nome do Job |
| `role_arn` | IAM Role criada | Permissões de execução |
| `glue_version` | `4.0` | Spark 3.3, Python 3 |
| `command.name` | `glueetl` | Tipo de Job (ETL) |
| `command.script_location` | S3 path do script | Script PySpark |
| `worker_type` | `G.1X` | 4 vCPU, 16 GB RAM |
| `number_of_workers` | `2` | 2 workers (escalável) |
| `timeout` | `60` min | Timeout máximo |
| `max_retries` | `1` | Tentativas em caso de falha |

**Argumentos do Job (`default_arguments`):**

```hcl
--job-bookmark-option              = "job-bookmark-enable"
--enable-glue-datacatalog          = "true"
--enable-metrics                   = "true"
--enable-continuous-cloudwatch-log = "true"
--enable-spark-ui                  = "true"
--conf                             = "spark.sql.sources.partitionOverwriteMode=dynamic"
--TempDir                          = "s3://glue-temp-bucket/temp/"
--enable-auto-scaling              = "true"

# Parâmetros customizados do script
--bronze_database  = "datalake-pipeline-catalog-dev"
--bronze_table     = "bronze_ingest_year_2025"
--silver_database  = "datalake-pipeline-catalog-dev"
--silver_table     = "silver_car_telemetry"
--silver_bucket    = "datalake-pipeline-silver-dev"
--silver_path      = "car_telemetry/"
```

**Argumentos Críticos:**

- `--job-bookmark-enable`: Habilita processamento incremental (apenas arquivos novos)
- `--conf spark.sql.sources.partitionOverwriteMode=dynamic`: Essencial para Upsert (sobrescreve apenas partições afetadas)
- `--enable-auto-scaling`: Workers escalados automaticamente conforme carga

#### 5️⃣ **Glue Trigger (Agendamento)**
```hcl
aws_glue_trigger.silver_consolidation_schedule
```

**Configuração:**

| Parâmetro | Valor | Descrição |
|-----------|-------|-----------|
| `type` | `SCHEDULED` | Trigger baseado em schedule |
| `schedule` | `cron(0 */1 * * ? *)` | A cada hora |
| `enabled` | `true` | Habilitado por padrão |

**Formato Cron AWS:**
```
cron(Minutes Hours Day-of-month Month Day-of-week Year)
      ↓       ↓         ↓         ↓        ↓        ↓
     0-59   0-23      1-31      1-12    SUN-SAT    *
```

**Exemplos:**
- `cron(0 */1 * * ? *)` → A cada hora
- `cron(0 */2 * * ? *)` → A cada 2 horas
- `cron(0 0 * * ? *)` → Diariamente à meia-noite UTC
- `cron(0 2 * * ? *)` → Diariamente às 2 AM UTC
- `cron(0 0 ? * MON *)` → Semanalmente às segundas-feiras

#### 6️⃣ **CloudWatch Log Group**
```hcl
aws_cloudwatch_log_group.glue_job_logs
```

**Configuração:**
- Nome: `/aws-glue/jobs/datalake-pipeline-silver-consolidation-dev`
- Retenção: 14 dias
- Criado antecipadamente (evita criação automática sem retenção)

## 🔧 Variáveis Configuráveis

### Arquivo: `variables.tf`

```hcl
# Script PySpark
variable "glue_silver_script_path" {
  default = "../glue_jobs/silver_consolidation_job.py"
}

# Versão do Glue (Spark + Python)
variable "glue_version" {
  default = "4.0"  # Spark 3.3, Python 3
}

# Capacidade de processamento
variable "glue_worker_type" {
  default = "G.1X"  # 4 vCPU, 16 GB RAM
  # Opções: "G.025X", "G.1X", "G.2X", "G.4X", "G.8X"
}

variable "glue_number_of_workers" {
  default = 2
  # Ajustar conforme volume de dados
}

# Timeout e retries
variable "glue_job_timeout_minutes" {
  default = 60  # 1 hora
}

variable "glue_job_max_retries" {
  default = 1
}

variable "glue_max_concurrent_runs" {
  default = 1  # Evita execuções sobrepostas
}

# Agendamento
variable "glue_trigger_schedule" {
  default = "cron(0 */1 * * ? *)"  # Horário
}

variable "glue_trigger_enabled" {
  default = true
}

# Nomes de tabelas
variable "bronze_table_name" {
  default = "bronze_ingest_year_2025"
}

variable "silver_table_name" {
  default = "silver_car_telemetry"
}

variable "silver_path" {
  default = "car_telemetry/"
}

# Logs
variable "cloudwatch_log_retention_days" {
  default = 14
}
```

## 🗑️ O que foi removido: `lambda.tf`

### Recursos Deletados

```hcl
# ❌ REMOVIDO
resource "aws_lambda_permission" "allow_s3_invoke_cleansing" { ... }

# ❌ REMOVIDO
resource "aws_s3_bucket_notification" "bronze_bucket_notification" { ... }
```

**Por que removidos?**
- Lambda Cleansing não é mais acionada por eventos S3
- Glue Job roda em schedule (não precisa de S3 trigger)
- Lambda Cleansing function **mantida** (pode ser útil para debug/fallback)

## 🚀 Como Usar

### Opção 1: Script Automatizado (Recomendado)

```powershell
cd terraform
.\deploy_glue_migration.ps1
```

**O script faz:**
1. ✅ Valida pré-requisitos (Terraform, AWS CLI, credenciais)
2. ✅ Verifica sintaxe do script PySpark
3. ✅ Cria backup do estado Terraform
4. ✅ Executa `terraform plan` e mostra mudanças
5. ✅ Pede confirmação manual
6. ✅ Executa `terraform apply`
7. ✅ Valida recursos criados (Glue Job, Trigger, IAM Role, etc.)
8. ✅ Exibe resumo e próximos passos

### Opção 2: Manual

```bash
# 1. Inicializar (se necessário)
terraform init

# 2. Validar configuração
terraform validate

# 3. Ver plano de execução
terraform plan

# 4. Aplicar mudanças
terraform apply

# 5. Verificar outputs
terraform output
```

## 🧪 Validação Pós-Deploy

### 1. Verificar Glue Job

```bash
aws glue get-job --job-name datalake-pipeline-silver-consolidation-dev
```

**Output esperado:**
```json
{
  "Job": {
    "Name": "datalake-pipeline-silver-consolidation-dev",
    "Role": "arn:aws:iam::...:role/datalake-pipeline-glue-job-role-dev",
    "Command": {
      "Name": "glueetl",
      "ScriptLocation": "s3://datalake-pipeline-glue-scripts-dev/glue_jobs/silver_consolidation_job.py"
    },
    "GlueVersion": "4.0"
  }
}
```

### 2. Verificar Trigger

```bash
aws glue get-trigger --name datalake-pipeline-silver-consolidation-trigger-dev
```

**Output esperado:**
```json
{
  "Trigger": {
    "Name": "datalake-pipeline-silver-consolidation-trigger-dev",
    "Type": "SCHEDULED",
    "State": "ACTIVATED",
    "Schedule": "cron(0 */1 * * ? *)"
  }
}
```

### 3. Verificar Script no S3

```bash
aws s3 ls s3://datalake-pipeline-glue-scripts-dev/glue_jobs/
```

**Output esperado:**
```
2025-10-30 15:00:00      12345 silver_consolidation_job.py
```

### 4. Teste Manual do Job

```bash
# Iniciar job
aws glue start-job-run --job-name datalake-pipeline-silver-consolidation-dev

# Verificar status
aws glue get-job-runs --job-name datalake-pipeline-silver-consolidation-dev --max-results 1
```

### 5. Monitorar Logs

```bash
# Tail dos logs (real-time)
aws logs tail /aws-glue/jobs/datalake-pipeline-silver-consolidation-dev --follow

# Últimos 100 logs
aws logs tail /aws-glue/jobs/datalake-pipeline-silver-consolidation-dev --since 1h
```

## 🔄 Atualizações Futuras

### Atualizar Script PySpark

```bash
# 1. Modificar script local
vim ../glue_jobs/silver_consolidation_job.py

# 2. Terraform detecta mudança via filemd5()
terraform plan
# Output: aws_s3_object.silver_consolidation_script will be updated in-place

# 3. Aplicar
terraform apply
# O Glue Job usará o novo script na próxima execução
```

### Ajustar Frequência do Job

```hcl
# terraform.tfvars
glue_trigger_schedule = "cron(0 */2 * * ? *)"  # A cada 2 horas
```

```bash
terraform apply
```

### Desabilitar Trigger (sem deletar Job)

```bash
terraform apply -var="glue_trigger_enabled=false"
```

### Aumentar Capacidade de Processamento

```hcl
# terraform.tfvars
glue_worker_type      = "G.2X"  # 8 vCPU, 32 GB RAM
glue_number_of_workers = 5
```

```bash
terraform apply
```

## 💰 Estimativa de Custos

### Configuração Padrão
- Worker Type: G.1X (4 vCPU, 16 GB RAM)
- Workers: 2
- Execuções: 24/dia (horário)
- Duração média: 5 minutos/execução

### Cálculo Mensal (us-east-1)

```
DPU-hours = 24 execuções/dia × 30 dias × 5 min × 2 DPUs = 120 DPU-hours
Custo = 120 DPU-hours × $0,44/DPU-hour = $52,80/mês
```

### Otimizações de Custo

| Mudança | Custo Mensal | Economia |
|---------|--------------|----------|
| **Configuração Atual** (horário, G.1X, 2 workers) | **$52,80** | - |
| Reduzir para 2×/dia | $4,40 | 92% |
| Usar G.025X (se volume baixo) | $26,40 | 50% |
| Reduzir para 1 worker | $26,40 | 50% |
| Combo: 1×/dia + G.025X + 1 worker | $0,66 | 99% |

### S3 e Outros Custos

- **Glue Scripts Bucket**: ~$0,01/mês (< 1 MB)
- **Glue Temp Bucket**: ~$0,10/mês (lifecycle 7 dias)
- **CloudWatch Logs**: ~$0,50/mês (14 dias retenção)
- **Glue Data Catalog**: Gratuito (< 1M objetos)

**Total estimado:** ~$53,50/mês

## 📊 Outputs Terraform

Após `terraform apply`, os seguintes outputs estão disponíveis:

```bash
terraform output
```

```hcl
glue_job_name = "datalake-pipeline-silver-consolidation-dev"
glue_job_arn = "arn:aws:glue:us-east-1:123456789012:job/datalake-pipeline-silver-consolidation-dev"
glue_trigger_name = "datalake-pipeline-silver-consolidation-trigger-dev"
glue_scripts_bucket = "datalake-pipeline-glue-scripts-dev"
glue_job_role_arn = "arn:aws:iam::123456789012:role/datalake-pipeline-glue-job-role-dev"
```

## 🆘 Troubleshooting

### Erro: "Script not found in S3"

**Causa:** Script local não existe ou path incorreto

**Solução:**
```bash
# Verificar path
ls ../glue_jobs/silver_consolidation_job.py

# Ajustar variável se necessário
terraform apply -var="glue_silver_script_path=/caminho/correto/silver_consolidation_job.py"
```

### Erro: "AccessDeniedException" ao executar Job

**Causa:** IAM Role sem permissões suficientes

**Solução:**
```bash
# Verificar políticas
terraform state show aws_iam_role_policy.glue_s3_access

# Recriar políticas
terraform taint aws_iam_role_policy.glue_s3_access
terraform apply
```

### Erro: Job Bookmarks não funcionam

**Causa:** Parâmetro `--job-bookmark-option` incorreto

**Solução:**
```bash
# Verificar argumentos do Job
aws glue get-job --job-name datalake-pipeline-silver-consolidation-dev \
  --query 'Job.DefaultArguments."--job-bookmark-option"'

# Deve retornar: "job-bookmark-enable"
```

### Trigger não executa Job

**Causa:** Trigger desabilitado ou schedule incorreto

**Solução:**
```bash
# Verificar estado
aws glue get-trigger --name datalake-pipeline-silver-consolidation-trigger-dev

# Habilitar manualmente
aws glue start-trigger --name datalake-pipeline-silver-consolidation-trigger-dev
```

## 📚 Referências

- [Terraform AWS Glue Job](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/glue_job)
- [Terraform AWS Glue Trigger](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/glue_trigger)
- [AWS Glue Job Parameters](https://docs.aws.amazon.com/glue/latest/dg/aws-glue-programming-etl-glue-arguments.html)
- [AWS Glue Job Bookmarks](https://docs.aws.amazon.com/glue/latest/dg/monitor-continuations.html)

---

**Autor**: Sistema de Data Lakehouse  
**Data**: 2025-10-30  
**Versão**: 1.0
