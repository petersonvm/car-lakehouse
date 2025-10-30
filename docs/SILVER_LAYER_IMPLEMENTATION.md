# 🥈 Implementação da Camada Silver - Pipeline Bronze-to-Silver

**Data de Criação:** 30 de Outubro de 2025  
**Versão:** 1.0.0  
**Status:** ✅ Implementado e Documentado

---

## 📋 Índice

1. [Visão Geral](#visão-geral)
2. [Arquitetura do Pipeline](#arquitetura-do-pipeline)
3. [Componentes Implementados](#componentes-implementados)
4. [Lógica de Transformação](#lógica-de-transformação)
5. [Infraestrutura Terraform](#infraestrutura-terraform)
6. [Particionamento Baseado em Eventos](#particionamento-baseado-em-eventos)
7. [Deployment e Configuração](#deployment-e-configuração)
8. [Testes e Validação](#testes-e-validação)
9. [Queries Athena (Exemplos)](#queries-athena-exemplos)
10. [Troubleshooting](#troubleshooting)
11. [Próximos Passos](#próximos-passos)

---

## 🎯 Visão Geral

### Objetivo da Camada Silver

A **Camada Silver** (também chamada de "Refined Layer") é responsável por transformar os dados brutos preservados no Bronze em um formato otimizado para análises:

- ✅ **Achatamento:** Converte estruturas aninhadas (`struct` columns) em colunas planas
- ✅ **Limpeza:** Padroniza formatos (Title Case, lowercase, trim)
- ✅ **Conversão de Tipos:** Transforma strings em datetime/date conforme necessário
- ✅ **Enriquecimento:** Calcula métricas derivadas (percentuais, taxas, KPIs)
- ✅ **Particionamento Inteligente:** Organiza por data do evento (não de ingestão)

### Diferenças: Bronze vs Silver

| Aspecto | Bronze Layer | Silver Layer |
|---------|-------------|--------------|
| **Formato** | Parquet com structs aninhados | Parquet achatado (flat) |
| **Particionamento** | Data de ingestão (`ingest_year/month/day`) | Data do evento (`event_year/month/day`) |
| **Schema** | Preserva estrutura original JSON | Schema normalizado e limpo |
| **Dados** | Cópia fiel da fonte | Transformado, limpo e enriquecido |
| **Uso** | Auditoria, troubleshooting, reprocessamento | Analytics, BI, Machine Learning |
| **Queries** | Complexas (dot notation para structs) | Simples (colunas planas) |

---

## 🏗️ Arquitetura do Pipeline

### Fluxo End-to-End

```
┌─────────────┐
│   Landing   │  JSON/CSV files uploaded by users
│   Bucket    │
└──────┬──────┘
       │
       │ S3 Event (*.json, *.csv)
       ↓
┌─────────────────────┐
│ Ingestion Lambda    │  Converts to Parquet (preserves structs)
│ (Bronze Layer)      │  Partitions by ingest_date
└──────────┬──────────┘
           │
           │ Writes Parquet
           ↓
┌─────────────────────┐
│   Bronze Bucket     │  Parquet with nested structures
│ /bronze/car_data/   │  Partitions: ingest_year/month/day
└──────────┬──────────┘
           │
           │ S3 Event (*.parquet)
           ↓
┌─────────────────────┐
│ Cleansing Lambda    │  ✨ NEW - Silver Layer
│ (Silver Layer)      │  1. Flatten structs
│                     │  2. Cleanse data
│                     │  3. Enrich metrics
│                     │  4. Partition by event_date
└──────────┬──────────┘
           │
           │ Writes Flattened Parquet
           ↓
┌─────────────────────┐
│   Silver Bucket     │  Parquet with flat columns
│ /car_telemetry/     │  Partitions: event_year/month/day
└──────────┬──────────┘
           │
           │ Daily at 01:00 UTC
           ↓
┌─────────────────────┐
│  Silver Crawler     │  Catalogs flattened data
│  (AWS Glue)         │  Detects event-based partitions
└──────────┬──────────┘
           │
           │ Updates Catalog
           ↓
┌─────────────────────┐
│  Glue Data Catalog  │  Table: silver_car_telemetry
│                     │  Queryable via Athena
└─────────────────────┘
           │
           │ SQL Queries
           ↓
┌─────────────────────┐
│  Amazon Athena      │  Fast queries on flat data
│                     │  No dot notation needed
└─────────────────────┘
```

### Trigger Automático

**Evento:** S3 ObjectCreated no `bronze-bucket`  
**Filtro:** Apenas arquivos `.parquet`  
**Ação:** Invocação da `cleansing-function` (Lambda)

---

## 🔧 Componentes Implementados

### 1. **Lambda Function (Python)**
- **Arquivo:** `lambdas/cleansing/lambda_function.py`
- **Handler:** `lambda_handler`
- **Runtime:** Python 3.9
- **Memory:** 1024 MB (maior que ingestion devido ao processamento)
- **Timeout:** 300 segundos (5 minutos)
- **Lambda Layer:** pandas-pyarrow (compartilhada com ingestion)

### 2. **Terraform Resources**

#### Lambda Function
```hcl
resource "aws_lambda_function" "cleansing" {
  function_name = "datalake-pipeline-cleansing-dev"
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"
  timeout       = 300
  memory_size   = 1024
  layers        = [aws_lambda_layer_version.pandas_pyarrow.arn]
  
  environment {
    variables = {
      SILVER_BUCKET = aws_s3_bucket.data_lake["silver"].id
      # ... outras variáveis
    }
  }
}
```

#### S3 Trigger (Bronze Bucket)
```hcl
resource "aws_s3_bucket_notification" "bronze_bucket_notification" {
  bucket = aws_s3_bucket.data_lake["bronze"].id

  lambda_function {
    id                  = "parquet-trigger"
    lambda_function_arn = aws_lambda_function.cleansing.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".parquet"
  }
}
```

#### Glue Crawler (Silver)
```hcl
resource "aws_glue_crawler" "silver_crawler" {
  name          = "datalake-pipeline-silver-crawler-dev"
  table_prefix  = "silver_"
  schedule      = "cron(0 1 * * ? *)"  # Daily at 01:00 UTC
  
  s3_target {
    path = "s3://silver-dev/car_telemetry/"
    exclusions = ["**/_temporary/**", "**/_SUCCESS", "**/.spark*"]
  }
  
  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
  }
  
  configuration = jsonencode({
    CrawlerOutput = {
      Tables = {
        AddOrUpdateBehavior = "MergeNewColumns"
      }
    }
  })
}
```

---

## 🔄 Lógica de Transformação

### Visão Geral das 5 Etapas

```python
def transform_to_silver(df):
    """
    Pipeline de transformação Bronze-to-Silver
    
    INPUT:  DataFrame com colunas struct (metrics, carInsurance, market)
    OUTPUT: DataFrame achatado, limpo e enriquecido
    """
    
    # 1️⃣ ACHATAMENTO (Flatten)
    df_flat = flatten_nested_columns(df)
    
    # 2️⃣ LIMPEZA (Cleansing)
    df_clean = cleanse_data(df_flat)
    
    # 3️⃣ CONVERSÃO DE TIPOS
    df_typed = convert_data_types(df_clean)
    
    # 4️⃣ ENRIQUECIMENTO (Enrichment)
    df_enriched = enrich_metrics(df_typed)
    
    # 5️⃣ PARTICIONAMENTO
    df_partitioned = create_event_partitions(df_enriched)
    
    return df_partitioned
```

---

### 1️⃣ Achatamento (Flatten Nested Structures)

**Objetivo:** Converter colunas `struct` em colunas planas com separador `_`

**Exemplo:**

**Bronze (Aninhado):**
```python
{
  "metrics": {
    "engineTempCelsius": 85.5,
    "fuelAvailableLiters": 45.2,
    "trip": {
      "tripMileage": 123.4,
      "tripFuelLiters": 8.5
    }
  }
}
```

**Silver (Achatado):**
```python
{
  "metrics_engineTempCelsius": 85.5,
  "metrics_fuelAvailableLiters": 45.2,
  "metrics_trip_tripMileage": 123.4,
  "metrics_trip_tripFuelLiters": 8.5
}
```

**Implementação:**
```python
def flatten_nested_columns(df):
    """
    Achata structs usando pd.json_normalize com separador '_'
    """
    nested_cols = [col for col in df.columns 
                   if isinstance(df[col].iloc[0], dict)]
    
    df_result = df[[col for col in df.columns if col not in nested_cols]]
    
    for nested_col in nested_cols:
        # Converter dict para DataFrame achatado
        nested_data = df[nested_col].tolist()
        df_nested_flat = pd.json_normalize(nested_data, sep='_')
        
        # Adicionar prefixo com nome da coluna original
        df_nested_flat.columns = [f"{nested_col}_{col}" 
                                  for col in df_nested_flat.columns]
        
        df_result = pd.concat([df_result, df_nested_flat], axis=1)
    
    return df_result
```

---

### 2️⃣ Limpeza (Data Cleansing)

**Objetivo:** Padronizar formatos de texto

**Regras:**

| Campo | Regra | Exemplo |
|-------|-------|---------|
| `manufacturer` | Title Case | "hyundai" → "Hyundai" |
| `color` | lowercase | "Blue" → "blue" |

**Implementação:**
```python
def cleanse_data(df):
    df_clean = df.copy()
    
    # Manufacturer: Title Case
    if 'manufacturer' in df_clean.columns:
        df_clean['manufacturer'] = df_clean['manufacturer'].str.title()
    
    # color: lowercase
    if 'color' in df_clean.columns:
        df_clean['color'] = df_clean['color'].str.lower()
    
    return df_clean
```

---

### 3️⃣ Conversão de Tipos

**Objetivo:** Converter strings em tipos apropriados para análises

**Conversões:**

| Campo (Bronze) | Tipo Bronze | Tipo Silver |
|----------------|-------------|-------------|
| `metrics_metricTimestamp` | string (ISO 8601) | datetime |
| `metrics_trip_tripStartTimestamp` | string | datetime |
| `carInsurance_validUntil` | string (YYYY-MM-DD) | date |

**Implementação:**
```python
def convert_data_types(df):
    df_typed = df.copy()
    
    # Timestamps (string → datetime)
    timestamp_cols = [
        'metrics_metricTimestamp',
        'metrics_trip_tripStartTimestamp'
    ]
    for col in timestamp_cols:
        if col in df_typed.columns:
            df_typed[col] = pd.to_datetime(df_typed[col], errors='coerce')
    
    # Data de seguro (string → date)
    if 'carInsurance_validUntil' in df_typed.columns:
        df_typed['carInsurance_validUntil'] = pd.to_datetime(
            df_typed['carInsurance_validUntil'], errors='coerce'
        ).dt.date
    
    return df_typed
```

---

### 4️⃣ Enriquecimento (Metrics Enrichment)

**Objetivo:** Calcular métricas derivadas para facilitar análises

**Métricas Calculadas:**

#### 4.1. **Percentual de Combustível**
```python
metrics_fuel_level_percentage = (
    metrics_fuelAvailableLiters / fuelCapacityLiters
) * 100
```

**Exemplo:**
- `metrics_fuelAvailableLiters = 45.2`
- `fuelCapacityLiters = 60.0`
- `metrics_fuel_level_percentage = 75.33%`

#### 4.2. **Eficiência de Combustível (km/litro)**
```python
metrics_trip_km_per_liter = (
    metrics_trip_tripMileage / metrics_trip_tripFuelLiters
)
```

**Exemplo:**
- `metrics_trip_tripMileage = 123.4 km`
- `metrics_trip_tripFuelLiters = 8.5 litros`
- `metrics_trip_km_per_liter = 14.52 km/litro`

**⚠️ Tratamento de Divisão por Zero:**
```python
df_enriched['metrics_trip_km_per_liter'] = df.apply(
    lambda row: (
        round(row['metrics_trip_tripMileage'] / 
              row['metrics_trip_tripFuelLiters'], 2)
        if row['metrics_trip_tripFuelLiters'] > 0
        else None  # Retorna NULL se divisor for zero
    ),
    axis=1
)
```

**Implementação Completa:**
```python
def enrich_metrics(df):
    df_enriched = df.copy()
    
    # Percentual de combustível
    if 'metrics_fuelAvailableLiters' in df.columns and \
       'fuelCapacityLiters' in df.columns:
        df_enriched['metrics_fuel_level_percentage'] = (
            df['metrics_fuelAvailableLiters'] / 
            df['fuelCapacityLiters'] * 100
        ).round(2)
    
    # Eficiência (km/litro) com proteção contra divisão por zero
    if 'metrics_trip_tripMileage' in df.columns and \
       'metrics_trip_tripFuelLiters' in df.columns:
        df_enriched['metrics_trip_km_per_liter'] = df.apply(
            lambda row: (
                round(row['metrics_trip_tripMileage'] / 
                      row['metrics_trip_tripFuelLiters'], 2)
                if row['metrics_trip_tripFuelLiters'] > 0
                else None
            ),
            axis=1
        )
    
    return df_enriched
```

---

### 5️⃣ Particionamento por Data do Evento

**Objetivo:** Organizar dados pela data do evento (não de ingestão)

**Fonte:** Campo `metrics_metricTimestamp` (datetime do evento real)

**Partições Criadas:**
- `event_year` (int): Ano do evento (ex: 2025)
- `event_month` (int): Mês do evento (ex: 10)
- `event_day` (int): Dia do evento (ex: 30)

**Estrutura S3 Resultante:**
```
s3://silver-bucket/car_telemetry/
├── event_year=2025/
│   ├── event_month=10/
│   │   ├── event_day=28/
│   │   │   └── file_20251028_143022.parquet
│   │   ├── event_day=29/
│   │   │   └── file_20251029_091545.parquet
│   │   └── event_day=30/
│   │       └── file_20251030_120033.parquet
│   └── event_month=11/
│       └── event_day=01/
│           └── file_20251101_080012.parquet
```

**Vantagens do Particionamento por Evento:**
1. ✅ Queries mais eficientes (filtra por data do evento real)
2. ✅ Análises temporais precisas (trends, sazonalidade)
3. ✅ Redução de custos (scan apenas partições necessárias)

**Implementação:**
```python
def create_event_partitions(df):
    df_part = df.copy()
    
    if 'metrics_metricTimestamp' in df_part.columns:
        # Extrair componentes da data
        df_part['event_year'] = df_part['metrics_metricTimestamp'].dt.year
        df_part['event_month'] = df_part['metrics_metricTimestamp'].dt.month
        df_part['event_day'] = df_part['metrics_metricTimestamp'].dt.day
    else:
        # Fallback: usar data atual
        now = datetime.now()
        df_part['event_year'] = now.year
        df_part['event_month'] = now.month
        df_part['event_day'] = now.day
    
    return df_part
```

---

## 📦 Infraestrutura Terraform

### Arquivos Modificados

#### 1. `terraform/lambda.tf`
**Adicionado:**
- `aws_lambda_function.cleansing` (função Silver)
- `aws_lambda_permission.allow_s3_invoke_cleansing` (permissão S3)
- `aws_s3_bucket_notification.bronze_bucket_notification` (trigger)

#### 2. `terraform/variables.tf`
**Adicionado:**
```hcl
variable "cleansing_lambda_config" {
  description = "Configuration for the cleansing Lambda (Silver Layer)"
  type = object({
    function_name    = string
    description      = string
    handler          = string
    runtime          = string
    timeout          = number
    memory_size      = number
    environment_vars = map(string)
  })
  default = {
    function_name = "cleansing"
    description   = "Transforms Bronze Parquet (nested) to Silver (flattened)"
    handler       = "lambda_function.lambda_handler"
    runtime       = "python3.9"
    timeout       = 300
    memory_size   = 1024
    environment_vars = {
      STAGE = "cleansing"
    }
  }
}

variable "cleansing_package_path" {
  description = "Path to the cleansing Lambda deployment package"
  type        = string
  default     = "../assets/cleansing_package.zip"
}
```

#### 3. `terraform/glue.tf`
**Modificado:**
- `aws_glue_crawler.silver_crawler`
  - Path alterado: `silver/` → `car_telemetry/`
  - Adicionado `table_prefix = "silver_"`
  - Adicionados `exclusions` para arquivos temporários
  - Description atualizada

#### 4. `terraform/outputs.tf`
**Adicionado:**
- `cleansing_lambda_name`
- `cleansing_lambda_arn`
- `cleansing_lambda_invoke_arn`
- `cleansing_lambda_version`
- Atualizado `s3_trigger_info` para incluir cleansing
- Atualizado `pipeline_summary` com cleansing Lambda
- Atualizado `lakehouse_summary` com Silver crawler features

---

## 🗂️ Particionamento Baseado em Eventos

### Comparação: Ingestão vs Evento

#### Bronze (Particionado por Data de Ingestão)
```
s3://bronze-bucket/bronze/car_data/
├── ingest_year=2025/
│   └── ingest_month=10/
│       └── ingest_day=30/
│           └── file.parquet  (todos os dados ingeridos em 30/10)
```

**Uso:** Auditoria, rastreamento de quando os dados chegaram

#### Silver (Particionado por Data do Evento)
```
s3://silver-bucket/car_telemetry/
├── event_year=2025/
│   └── event_month=10/
│       ├── event_day=28/  (eventos de 28/10, ingeridos em 30/10)
│       ├── event_day=29/  (eventos de 29/10, ingeridos em 30/10)
│       └── event_day=30/  (eventos de 30/10, ingeridos em 30/10)
```

**Uso:** Análises temporais, trends, forecasting

### Exemplo de Query Eficiente (Athena)

**❌ SEM Particionamento:**
```sql
-- Scan completo de TODOS os arquivos (caro e lento)
SELECT COUNT(*) 
FROM silver_car_telemetry
WHERE metrics_metricTimestamp >= DATE '2025-10-28';
```
**Custo:** Scan de 100 GB = $0.50

**✅ COM Particionamento:**
```sql
-- Scan apenas das partições necessárias
SELECT COUNT(*) 
FROM silver_car_telemetry
WHERE event_year = 2025 
  AND event_month = 10
  AND event_day >= 28;
```
**Custo:** Scan de 15 GB = $0.075  
**Economia:** 85% de custo! 🎉

---

## 🚀 Deployment e Configuração

### Passo 1: Criar Pacote de Deployment

```powershell
# Navegar para a pasta da Lambda
cd c:\dev\HP\wsas\Poc\lambdas\cleansing

# Criar diretório temporário
New-Item -ItemType Directory -Force -Path .\package

# Instalar dependências (não necessário - usa Lambda Layer)
# pip install -r requirements.txt -t .\package

# Adicionar código da Lambda
Copy-Item lambda_function.py .\package\

# Criar ZIP
Compress-Archive -Path .\package\* -DestinationPath ..\..\assets\cleansing_package.zip -Force

# Limpar diretório temporário
Remove-Item -Recurse -Force .\package

Write-Host "✅ Pacote criado: assets/cleansing_package.zip"
```

### Passo 2: Aplicar Terraform

```powershell
cd c:\dev\HP\wsas\Poc\terraform

# Validar configuração
terraform validate

# Ver plano de execução
terraform plan

# Aplicar mudanças
terraform apply
```

**Recursos Criados:**
- ✅ `aws_lambda_function.cleansing`
- ✅ `aws_lambda_permission.allow_s3_invoke_cleansing`
- ✅ `aws_s3_bucket_notification.bronze_bucket_notification`

**Recursos Modificados:**
- 🔄 `aws_glue_crawler.silver_crawler` (path e configuração)

### Passo 3: Verificar Deployment

```powershell
# Verificar Lambda criada
aws lambda get-function --function-name datalake-pipeline-cleansing-dev --query "Configuration.[FunctionName,Runtime,MemorySize,Timeout]"

# Verificar trigger S3 configurado
aws lambda get-policy --function-name datalake-pipeline-cleansing-dev

# Verificar crawler atualizado
aws glue get-crawler --name datalake-pipeline-silver-crawler-dev --query "Crawler.[Name,Targets.S3Targets[0].Path,Configuration]"
```

---

## 🧪 Testes e Validação

### Teste End-to-End

#### 1. **Upload de Arquivo JSON (Landing)**

```powershell
# Preparar arquivo de teste
$testJson = @"
{
  "carId": "TEST-001",
  "manufacturer": "tesla",
  "model": "Model 3",
  "year": 2024,
  "color": "Midnight Silver Metallic",
  "fuelCapacityLiters": 0,
  "metrics": {
    "engineTempCelsius": 22.5,
    "fuelAvailableLiters": 0,
    "speedKmh": 95.0,
    "metricTimestamp": "2025-10-30T14:30:45Z",
    "trip": {
      "tripMileage": 456.7,
      "tripFuelLiters": 0,
      "tripStartTimestamp": "2025-10-30T08:00:00Z"
    }
  },
  "carInsurance": {
    "provider": "Tesla Insurance",
    "policyNumber": "TSL-2024-789",
    "validUntil": "2026-12-31",
    "coverageType": "Full Coverage"
  },
  "market": {
    "marketRegion": "North America",
    "currentPrice": 45000.00,
    "currency": "USD"
  }
}
"@

# Salvar em arquivo
$testJson | Out-File -FilePath test_silver.json -Encoding UTF8

# Upload para Landing
aws s3 cp test_silver.json s3://datalake-pipeline-landing-dev/test_silver.json
```

#### 2. **Verificar Processamento Bronze**

```powershell
# Aguardar processamento (5-10 segundos)
Start-Sleep -Seconds 10

# Verificar logs da Ingestion Lambda
aws logs tail /aws/lambda/datalake-pipeline-ingestion-dev --follow --since 1m

# Verificar arquivo Parquet criado no Bronze
aws s3 ls s3://datalake-pipeline-bronze-dev/bronze/car_data/ingest_year=2025/ --recursive
```

**Saída Esperada:**
```
2025-10-30 14:31:02    1234 bronze/car_data/ingest_year=2025/ingest_month=10/ingest_day=30/test_silver_20251030_143102.parquet
```

#### 3. **Verificar Processamento Silver (Automático)**

```powershell
# Aguardar trigger e processamento (5-10 segundos)
Start-Sleep -Seconds 10

# Verificar logs da Cleansing Lambda
aws logs tail /aws/lambda/datalake-pipeline-cleansing-dev --follow --since 1m

# Verificar arquivo Parquet criado no Silver
aws s3 ls s3://datalake-pipeline-silver-dev/car_telemetry/event_year=2025/ --recursive
```

**Saída Esperada:**
```
2025-10-30 14:31:15    2345 car_telemetry/event_year=2025/event_month=10/event_day=30/test_silver_20251030_143102_20251030_143115.parquet
```

#### 4. **Executar Crawlers**

```powershell
# Bronze Crawler
aws glue start-crawler --name datalake-pipeline-bronze-car-data-crawler-dev

# Aguardar conclusão (30-60 segundos)
aws glue get-crawler --name datalake-pipeline-bronze-car-data-crawler-dev --query "Crawler.State"

# Silver Crawler
aws glue start-crawler --name datalake-pipeline-silver-crawler-dev

# Aguardar conclusão
aws glue get-crawler --name datalake-pipeline-silver-crawler-dev --query "Crawler.State"
```

#### 5. **Verificar Tabelas no Glue Catalog**

```powershell
# Listar tabelas
aws glue get-tables --database-name datalake-pipeline-catalog-dev --query "TableList[*].Name"

# Schema da tabela Bronze
aws glue get-table --database-name datalake-pipeline-catalog-dev --name bronze_ingest_year_2025 --query "Table.StorageDescriptor.Columns[*].[Name,Type]"

# Schema da tabela Silver
aws glue get-table --database-name datalake-pipeline-catalog-dev --name silver_car_telemetry --query "Table.StorageDescriptor.Columns[*].[Name,Type]"
```

**Schema Esperado (Silver):**
```
carId                              | string
manufacturer                       | string  (Title Case)
model                              | string
year                               | int
color                              | string  (lowercase)
fuelCapacityLiters                 | double
metrics_engineTempCelsius          | double
metrics_fuelAvailableLiters        | double
metrics_speedKmh                   | double
metrics_metricTimestamp            | timestamp
metrics_trip_tripMileage           | double
metrics_trip_tripFuelLiters        | double
metrics_trip_tripStartTimestamp    | timestamp
metrics_fuel_level_percentage      | double  (ENRIQUECIDO)
metrics_trip_km_per_liter          | double  (ENRIQUECIDO)
carInsurance_provider              | string
carInsurance_policyNumber          | string
carInsurance_validUntil            | date
carInsurance_coverageType          | string
market_marketRegion                | string
market_currentPrice                | double
market_currency                    | string
event_year                         | int     (PARTIÇÃO)
event_month                        | int     (PARTIÇÃO)
event_day                          | int     (PARTIÇÃO)
```

---

## 📊 Queries Athena (Exemplos)

### 1. **Query Básica (Silver)**

```sql
-- Contar registros
SELECT COUNT(*) AS total_records
FROM silver_car_telemetry;
```

### 2. **Análise de Métricas Enriquecidas**

```sql
-- Top 10 veículos com menor eficiência de combustível
SELECT 
    carId,
    manufacturer,
    model,
    AVG(metrics_trip_km_per_liter) AS avg_km_per_liter,
    AVG(metrics_fuel_level_percentage) AS avg_fuel_level_pct
FROM silver_car_telemetry
WHERE metrics_trip_km_per_liter IS NOT NULL
GROUP BY carId, manufacturer, model
ORDER BY avg_km_per_liter ASC
LIMIT 10;
```

### 3. **Análise Temporal (Com Partições)**

```sql
-- Velocidade média por dia (última semana)
SELECT 
    event_year,
    event_month,
    event_day,
    AVG(metrics_speedKmh) AS avg_speed,
    MAX(metrics_speedKmh) AS max_speed,
    COUNT(*) AS num_readings
FROM silver_car_telemetry
WHERE event_year = 2025
  AND event_month = 10
  AND event_day >= 23  -- Últimos 7 dias
GROUP BY event_year, event_month, event_day
ORDER BY event_year, event_month, event_day;
```

### 4. **Análise por Fabricante**

```sql
-- Estatísticas por fabricante (após limpeza Title Case)
SELECT 
    manufacturer,
    COUNT(DISTINCT carId) AS num_cars,
    AVG(metrics_engineTempCelsius) AS avg_temp,
    AVG(metrics_trip_km_per_liter) AS avg_efficiency,
    AVG(market_currentPrice) AS avg_price
FROM silver_car_telemetry
GROUP BY manufacturer
ORDER BY num_cars DESC;
```

### 5. **Join Bronze + Silver (Comparação)**

```sql
-- Comparar estrutura aninhada (Bronze) vs achatada (Silver)
SELECT 
    b.carId,
    b.metrics.speedKmh AS bronze_speed,  -- Dot notation (Bronze)
    s.metrics_speedKmh AS silver_speed    -- Flat column (Silver)
FROM bronze_ingest_year_2025 b
JOIN silver_car_telemetry s
    ON b.carId = s.carId
LIMIT 10;
```

### 6. **Análise de Seguros (Data Conversion)**

```sql
-- Seguros expirando nos próximos 90 dias
SELECT 
    carId,
    manufacturer,
    model,
    carInsurance_provider,
    carInsurance_validUntil,
    DATE_DIFF('day', CURRENT_DATE, CAST(carInsurance_validUntil AS DATE)) AS days_until_expiry
FROM silver_car_telemetry
WHERE CAST(carInsurance_validUntil AS DATE) <= CURRENT_DATE + INTERVAL '90' DAY
ORDER BY days_until_expiry ASC;
```

### 7. **Análise de Combustível (Enriquecimento)**

```sql
-- Veículos com nível crítico de combustível (<20%)
SELECT 
    carId,
    manufacturer,
    model,
    metrics_fuelAvailableLiters AS fuel_available,
    fuelCapacityLiters AS tank_capacity,
    metrics_fuel_level_percentage AS fuel_percentage,
    CASE 
        WHEN metrics_fuel_level_percentage < 10 THEN 'CRÍTICO'
        WHEN metrics_fuel_level_percentage < 20 THEN 'BAIXO'
        ELSE 'OK'
    END AS fuel_status
FROM silver_car_telemetry
WHERE metrics_fuel_level_percentage < 20
ORDER BY metrics_fuel_level_percentage ASC;
```

### 8. **Time Series Analysis (Partições Otimizadas)**

```sql
-- Tendência de velocidade média ao longo do tempo
SELECT 
    DATE(CAST(metrics_metricTimestamp AS TIMESTAMP)) AS event_date,
    AVG(metrics_speedKmh) AS avg_speed,
    STDDEV(metrics_speedKmh) AS speed_std_dev,
    COUNT(*) AS num_readings
FROM silver_car_telemetry
WHERE event_year = 2025
  AND event_month = 10
GROUP BY DATE(CAST(metrics_metricTimestamp AS TIMESTAMP))
ORDER BY event_date;
```

---

## 🔍 Troubleshooting

### Problema 1: Lambda Não é Invocada

**Sintomas:**
- Arquivo Parquet criado no Bronze
- Nenhum arquivo criado no Silver
- Nenhuma entrada nos logs da Cleansing Lambda

**Diagnóstico:**
```powershell
# Verificar trigger configurado
aws s3api get-bucket-notification-configuration --bucket datalake-pipeline-bronze-dev

# Verificar permissão Lambda
aws lambda get-policy --function-name datalake-pipeline-cleansing-dev
```

**Soluções:**
1. ✅ Verificar se `aws_s3_bucket_notification.bronze_bucket_notification` foi aplicado
2. ✅ Verificar se `aws_lambda_permission.allow_s3_invoke_cleansing` existe
3. ✅ Re-aplicar Terraform: `terraform apply`
4. ✅ Testar upload manual: `aws s3 cp test.parquet s3://bronze-bucket/test.parquet`

---

### Problema 2: Erro "KeyError" ao Achatar Structs

**Sintomas:**
```
ERROR: KeyError: 'metrics'
Traceback: flatten_nested_columns()
```

**Causa:** Arquivo Bronze não contém as colunas esperadas (corrupto ou formato diferente)

**Diagnóstico:**
```powershell
# Baixar e inspecionar arquivo Bronze
aws s3 cp s3://bronze-bucket/bronze/car_data/.../file.parquet .
python -c "import pandas as pd; df = pd.read_parquet('file.parquet'); print(df.columns)"
```

**Solução:**
- Adicionar validação no código:
```python
nested_cols = []
for col in df.columns:
    if len(df) > 0 and isinstance(df[col].iloc[0], dict):
        nested_cols.append(col)
```

---

### Problema 3: Divisão por Zero em `km_per_liter`

**Sintomas:**
```
WARNING: RuntimeWarning: divide by zero encountered in double_scalars
```

**Causa:** `metrics_trip_tripFuelLiters = 0`

**Solução Implementada:**
```python
df_enriched['metrics_trip_km_per_liter'] = df.apply(
    lambda row: (
        round(row['metrics_trip_tripMileage'] / 
              row['metrics_trip_tripFuelLiters'], 2)
        if row['metrics_trip_tripFuelLiters'] > 0
        else None  # ← Retorna NULL ao invés de erro
    ),
    axis=1
)
```

---

### Problema 4: Crawler Não Detecta Partições

**Sintomas:**
- Tabela `silver_car_telemetry` criada
- Partições (`event_year`, `event_month`, `event_day`) não aparecem como partition keys
- Queries não filtram por partições

**Diagnóstico:**
```powershell
# Verificar estrutura S3
aws s3 ls s3://silver-bucket/car_telemetry/ --recursive

# Verificar configuração do crawler
aws glue get-crawler --name datalake-pipeline-silver-crawler-dev --query "Crawler.Configuration"
```

**Solução:**
1. ✅ Garantir estrutura HIVE: `event_year=2025/event_month=10/event_day=30/`
2. ✅ Deletar tabela incorreta: `aws glue delete-table --database-name ... --name silver_car_telemetry`
3. ✅ Re-executar crawler: `aws glue start-crawler --name ...`

---

### Problema 5: Timeout da Lambda (300s)

**Sintomas:**
```
ERROR: Task timed out after 300.00 seconds
```

**Causa:** Arquivo Parquet muito grande (>50 MB) ou processamento ineficiente

**Soluções:**
1. ✅ **Aumentar Timeout:** Editar `variables.tf` → `timeout = 600` (10 min)
2. ✅ **Aumentar Memória:** `memory_size = 2048` (mais CPU disponível)
3. ✅ **Otimizar Código:** Processar em chunks
```python
# Processar em batches de 10000 linhas
chunk_size = 10000
for i in range(0, len(df), chunk_size):
    df_chunk = df.iloc[i:i+chunk_size]
    transform_and_write(df_chunk)
```

---

### Problema 6: Schema Drift (Novas Colunas)

**Sintomas:**
- Query retorna erro: "Column 'new_field' not found"
- Novos campos JSON não aparecem em Athena

**Causa:** Crawler não re-catalogou schema após mudanças

**Solução:**
```powershell
# Re-executar crawler (detecta novas colunas)
aws glue start-crawler --name datalake-pipeline-silver-crawler-dev

# Verificar configuração "MergeNewColumns" no crawler
aws glue get-crawler --name datalake-pipeline-silver-crawler-dev \
    --query "Crawler.Configuration" --output json
```

**Garantir em Terraform:**
```hcl
configuration = jsonencode({
  CrawlerOutput = {
    Tables = {
      AddOrUpdateBehavior = "MergeNewColumns"  # ← CRÍTICO
    }
  }
})
```

---

## 🎯 Próximos Passos

### 1. **Pipeline Gold (Analytics Layer)**
- Criar agregações pré-computadas
- Views materializadas para dashboards
- Integração com QuickSight/Tableau

### 2. **Monitoramento e Alertas**
- CloudWatch Alarms para falhas de Lambda
- SNS notifications para erros
- Dashboards de métricas (duração, custos)

### 3. **Data Quality Checks**
- Validações de schema (Great Expectations)
- Testes de integridade (duplicados, nulls)
- Alertas para anomalias

### 4. **Otimizações de Performance**
- Compactação de arquivos pequenos (S3 Small Files Problem)
- Particionamento adicional (por `manufacturer`, `region`)
- Uso de Z-Ordering para queries complexas

### 5. **CI/CD Pipeline**
- GitHub Actions para deploy automático
- Testes unitários Python (pytest)
- Validação Terraform (terraform fmt, validate)

---

## 📚 Referências

### Documentação AWS
- [AWS Lambda Developer Guide](https://docs.aws.amazon.com/lambda/)
- [AWS Glue Crawler Configuration](https://docs.aws.amazon.com/glue/latest/dg/crawler-configuration.html)
- [Amazon Athena User Guide](https://docs.aws.amazon.com/athena/)
- [S3 Event Notifications](https://docs.aws.amazon.com/AmazonS3/latest/userguide/NotificationHowTo.html)

### Bibliotecas Python
- [Pandas Documentation](https://pandas.pydata.org/docs/)
- [PyArrow Parquet](https://arrow.apache.org/docs/python/parquet.html)
- [Boto3 (AWS SDK)](https://boto3.amazonaws.com/v1/documentation/api/latest/index.html)

### Terraform
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Lambda Resources](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function)
- [S3 Notifications](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_notification)

---

## ✅ Checklist de Implementação

- [x] Lambda function criada (`cleansing-function`)
- [x] S3 trigger configurado (Bronze bucket → `.parquet`)
- [x] Lambda Layer compartilhada (pandas + pyarrow)
- [x] Lógica de achatamento implementada (`json_normalize`)
- [x] Limpeza de dados (Title Case, lowercase)
- [x] Conversão de tipos (datetime, date)
- [x] Enriquecimento de métricas (fuel %, km/L)
- [x] Particionamento por evento (event_year/month/day)
- [x] Glue Crawler atualizado (target `car_telemetry/`)
- [x] Terraform resources criados e testados
- [x] Outputs atualizados (Lambda ARNs, crawler info)
- [x] Documentação completa
- [x] Testes end-to-end validados
- [x] Queries Athena exemplificadas
- [x] Troubleshooting documentado

---

**Status Final:** ✅ **Silver Layer IMPLEMENTADA E FUNCIONAL**

**Data:** 30 de Outubro de 2025  
**Autor:** Pipeline de Dados - AWS Lakehouse  
**Versão:** 1.0.0
