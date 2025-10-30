# Camada Silver - Data Lakehouse Pipeline

## 📋 Visão Geral

A **Camada Silver** é responsável por transformar dados brutos (Bronze) em dados limpos, padronizados e prontos para análise. Esta camada implementa processos de **Data Cleansing** e **Data Standardization**.

## 🏗️ Arquitetura Implementada

### Componentes Principais

```
┌─────────────────────────────────────────────────────────────────┐
│                    SILVER LAYER ARCHITECTURE                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐    ┌─────────────────┐    ┌──────────────┐  │
│  │   Bronze     │───▶│  Silver Lambda   │───▶│    Silver    │  │
│  │   Bucket     │    │  (Cleansing)     │    │    Bucket    │  │
│  │  (Parquet)   │    │                  │    │  (Parquet)   │  │
│  └──────────────┘    └─────────────────┘    └──────────────┘  │
│         │                     │                      │          │
│         │                     │                      │          │
│         ▼                     ▼                      ▼          │
│  ┌──────────────┐    ┌─────────────────┐    ┌──────────────┐  │
│  │ EventBridge  │    │   CloudWatch    │    │ Glue Crawler │  │
│  │  Scheduler   │    │      Logs       │    │   (Daily)    │  │
│  │  (Hourly)    │    │                 │    │              │  │
│  └──────────────┘    └─────────────────┘    └──────────────┘  │
│                                                      │          │
│                                                      ▼          │
│                                              ┌──────────────┐  │
│                                              │ Glue Catalog │  │
│                                              │ (Metadata)   │  │
│                                              └──────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### 1. **AWS Lambda Function - `cleansing-function`**

**Responsabilidades:**
- Ler dados particionados do Bronze bucket
- Aplicar transformações de limpeza e padronização
- Escrever dados limpos no Silver bucket (formato Parquet particionado)

**Configuração:**
- **Runtime:** Python 3.9
- **Memory:** 1024 MB
- **Timeout:** 600 segundos (10 minutos)
- **Lambda Layer:** pandas + pyarrow (compartilhado)

**Variáveis de Ambiente:**
```hcl
BRONZE_BUCKET_NAME    = "datalake-pipeline-bronze-dev"
SILVER_BUCKET_NAME    = "datalake-pipeline-silver-dev"
GLUE_DATABASE_NAME    = "datalake-pipeline-catalog-dev"
LOG_LEVEL             = "INFO"
PARTITION_COLUMNS     = "partition_year,partition_month,partition_day"
ENABLE_DATA_QUALITY   = "true"
```

### 2. **IAM Role - `silver-lambda-role`**

**Permissões Concedidas:**

**S3 Access:**
- **Read from Bronze:** `s3:GetObject`, `s3:ListBucket` em `bronze-bucket/*`
- **Write to Silver:** `s3:PutObject`, `s3:PutObjectAcl`, `s3:DeleteObject` em `silver-bucket/*`

**CloudWatch Logs:**
- `logs:CreateLogGroup`
- `logs:CreateLogStream`
- `logs:PutLogEvents`

**Glue Catalog (Read):**
- `glue:GetDatabase`
- `glue:GetTable`
- `glue:GetPartitions`
- `glue:BatchGetPartition`

### 3. **Amazon EventBridge Scheduler**

**Configuração:**
- **Nome:** `silver-etl-schedule`
- **Schedule:** `rate(1 hour)` - Executa a cada hora
- **Target:** Lambda `cleansing-function`
- **Retry Policy:** 2 tentativas, janela de 1 hora

**Payload de Entrada:**
```json
{
  "source_bucket": "datalake-pipeline-bronze-dev",
  "target_bucket": "datalake-pipeline-silver-dev",
  "table_name": "bronze",
  "triggered_by": "eventbridge-scheduler"
}
```

### 4. **AWS Glue Crawler - `silver_data_crawler`**

**Configuração:**
- **Schedule:** `cron(0 1 * * ? *)` - Diariamente às 01:00 UTC
- **Target Path:** `s3://silver-bucket/silver/`
- **Database:** `analytics_db` (catálogo existente)
- **Partition Detection:** Habilitado (detecta `partition_year`, `partition_month`, `partition_day`)

**Schema Change Policy:**
- **Delete Behavior:** LOG (registra exclusões)
- **Update Behavior:** UPDATE_IN_DATABASE (atualiza schema automaticamente)

**Table Behavior:**
- **Add/Update Behavior:** MergeNewColumns (adiciona novas colunas sem sobrescrever)

## 🔄 Fluxo de Dados

### Passo a Passo:

1. **Trigger Agendado (EventBridge)**
   - A cada hora, o EventBridge Scheduler aciona a Lambda de Cleansing

2. **Leitura do Bronze**
   - Lambda lê as partições mais recentes do Bronze bucket
   - Formato: `bronze/partition_year=YYYY/partition_month=MM/partition_day=DD/*.parquet`

3. **Transformações Aplicadas**
   - **Flatten:** Estruturas já achatadas no Bronze (JSON normalize)
   - **Padronização:** Nomes de colunas → `lowercase_snake_case`
   - **Deduplicação:** Remove registros duplicados exatos
   - **Validação:** Garante tipos de dados corretos (float64 para numéricos)
   - **Enriquecimento:** Adiciona metadados:
     - `silver_processing_timestamp`
     - `silver_processing_date`
     - `data_quality_score`
   - **Particionamento:** Adiciona colunas `event_year`, `event_month`, `event_day`

4. **Escrita no Silver**
   - Dados limpos são escritos no Silver bucket
   - Formato: `silver/partition_year=YYYY/partition_month=MM/partition_day=DD/car_telemetry_*.parquet`
   - Compressão: Snappy
   - Metadados S3: Incluem contagem de registros, timestamp, etc.

5. **Catalogação (Glue Crawler)**
   - Diariamente às 01:00 UTC, o Crawler escaneia o Silver bucket
   - Detecta novas partições automaticamente
   - Atualiza o Glue Data Catalog com schema e metadados
   - Torna os dados consultáveis via Amazon Athena

## 📊 Estrutura de Dados

### Bronze → Silver Transformation

**Bronze (Input):**
```
carchassis, model, year, modelyear, manufacturer, ...
metrics.trip.tripfuelliters, metrics.trip.tripmileage, ...
ingestion_timestamp, source_file, source_bucket
```

**Silver (Output):**
```
carchassis, model, year, modelyear, manufacturer, ...
metrics_trip_tripfuelliters, metrics_trip_tripmileage, ...  ← Standardized names
ingestion_timestamp, source_file, source_bucket
silver_processing_timestamp ← New metadata
silver_processing_date ← New metadata
data_quality_score ← New metadata
event_year, event_month, event_day ← Partition columns (NOT in data)
```

### Partições no Silver

```
s3://silver-bucket/
└── silver/
    └── partition_year=2025/
        └── partition_month=10/
            └── partition_day=30/
                ├── car_telemetry_20251030_120000.parquet
                ├── car_telemetry_20251030_130000.parquet
                └── car_telemetry_20251030_140000.parquet
```

## 🚀 Como Implantar

### 1. Validar Variáveis (terraform/variables.tf)

```hcl
# Ajustar conforme necessário
variable "silver_lambda_memory" {
  default = 1024  # MB
}

variable "silver_lambda_timeout" {
  default = 600  # 10 minutos
}

variable "silver_etl_schedule" {
  default = "rate(1 hour)"  # A cada hora
}

variable "silver_crawler_schedule" {
  default = "cron(0 1 * * ? *)"  # 01:00 UTC diariamente
}
```

### 2. Aplicar Terraform

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

### 3. Verificar Recursos Criados

```bash
# Lambda Function
aws lambda get-function --function-name datalake-pipeline-cleansing-silver-dev

# EventBridge Scheduler
aws scheduler get-schedule --name datalake-pipeline-silver-etl-schedule-dev

# Glue Crawler
aws glue get-crawler --name datalake-pipeline-silver-crawler-dev
```

### 4. Testar Manualmente

**Invocar Lambda manualmente:**
```bash
aws lambda invoke \
  --function-name datalake-pipeline-cleansing-silver-dev \
  --payload '{"source_bucket":"datalake-pipeline-bronze-dev","target_bucket":"datalake-pipeline-silver-dev"}' \
  response.json

cat response.json
```

**Executar Crawler manualmente:**
```bash
aws glue start-crawler --name datalake-pipeline-silver-crawler-dev

# Verificar status
aws glue get-crawler --name datalake-pipeline-silver-crawler-dev
```

## 📈 Monitoramento

### CloudWatch Logs

```bash
# Ver logs da Lambda
aws logs tail /aws/lambda/datalake-pipeline-cleansing-silver-dev --follow

# Ver logs do Crawler
aws logs tail /aws-glue/crawlers --filter-pattern "silver-crawler" --follow
```

### Métricas CloudWatch

- **Lambda:**
  - Invocations
  - Duration
  - Errors
  - Throttles

- **Scheduler:**
  - InvocationAttemptCount
  - InvocationSuccessCount
  - InvocationFailureCount

## 🎯 Benefícios da Camada Silver

### 1. **Dados Limpos e Confiáveis**
- Remoção de duplicatas
- Validação de tipos de dados
- Tratamento de valores nulos

### 2. **Padronização**
- Nomes de colunas consistentes
- Formato uniforme (Parquet)
- Estrutura previsível

### 3. **Performance Otimizada**
- Particionamento por data
- Compressão Snappy
- Formato colunar (Parquet)

### 4. **Rastreabilidade**
- Metadados de processamento
- Score de qualidade de dados
- Timestamps de transformação

### 5. **Pronto para Análise**
- Dados estruturados
- Schema catalogado no Glue
- Consultável via Athena

## 🔧 Customizações Comuns

### Alterar Frequência do ETL

**Executar a cada 30 minutos:**
```hcl
variable "silver_etl_schedule" {
  default = "rate(30 minutes)"
}
```

**Executar diariamente às 02:00 UTC:**
```hcl
variable "silver_etl_schedule" {
  default = "cron(0 2 * * ? *)"
}
```

### Aumentar Recursos da Lambda

```hcl
variable "silver_lambda_memory" {
  default = 2048  # 2 GB
}

variable "silver_lambda_timeout" {
  default = 900  # 15 minutos
}
```

### Adicionar Transformações Customizadas

Edite `lambdas/silver/silver_etl.py` e adicione lógica na função `apply_transformations()`:

```python
def apply_transformations(df):
    # ... existing transformations ...
    
    # Custom transformation example
    df['vehicle_age'] = 2025 - df['year']
    
    # Add business logic
    df['price_category'] = df['market_currentprice'].apply(
        lambda x: 'High' if x > 50000 else 'Medium' if x > 25000 else 'Low'
    )
    
    return df
```

## 📚 Referências

- [AWS Lambda Documentation](https://docs.aws.amazon.com/lambda/)
- [Amazon EventBridge Scheduler](https://docs.aws.amazon.com/scheduler/)
- [AWS Glue Crawler](https://docs.aws.amazon.com/glue/latest/dg/add-crawler.html)
- [Apache Parquet](https://parquet.apache.org/)
- [Pandas Documentation](https://pandas.pydata.org/)

## 🎉 Próximos Passos

1. ✅ **Silver Layer Implementada**
2. 🚧 **Implementar Gold Layer** (Agregações e Analytics)
3. 🚧 **Adicionar Data Quality Checks**
4. 🚧 **Implementar Alertas CloudWatch**
5. 🚧 **Dashboard de Monitoramento**

---

**Criado por:** Data Engineering Team  
**Última Atualização:** 2025-10-30  
**Versão:** 1.0.0
