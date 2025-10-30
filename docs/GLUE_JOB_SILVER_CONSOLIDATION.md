# AWS Glue Job - Silver Layer Consolidation com Upsert

## 📋 Visão Geral

Script PySpark completo para AWS Glue ETL que implementa:
- ✅ Leitura incremental com **Glue Job Bookmarks**
- ✅ Transformações Silver (flatten, cleanse, enrich, partition)
- ✅ **Consolidação com Upsert** (elimina duplicatas)
- ✅ **Dynamic Partition Overwrite** (atualiza apenas partições afetadas)

## 🎯 Problema Resolvido

**Antes (Lambda):**
- Cada execução **anexava** dados sem verificar duplicatas
- Mesmo `carChassis` + `event_day` podia ter múltiplos registros
- Queries retornavam dados duplicados

**Depois (Glue Job):**
- Carrega dados novos **+** dados existentes
- Aplica deduplicação com **Window function**
- Sobrescreve apenas partições afetadas
- **1 registro único** por `carChassis` + `event_day`

## 🔑 Parâmetros do Job

O script espera os seguintes parâmetros ao criar o Glue Job:

| Parâmetro | Descrição | Exemplo |
|-----------|-----------|---------|
| `bronze_database` | Database do Bronze no Glue Catalog | `datalake-pipeline-catalog-dev` |
| `bronze_table` | Tabela Bronze | `bronze_ingest_year_2025` |
| `silver_database` | Database do Silver no Glue Catalog | `datalake-pipeline-catalog-dev` |
| `silver_table` | Tabela Silver | `silver_car_telemetry` |
| `silver_bucket` | Bucket S3 do Silver | `datalake-pipeline-silver-dev` |
| `silver_path` | Path dentro do bucket | `car_telemetry/` |

## 🔄 Fluxo de Execução

### 1️⃣ **Leitura Incremental (Bookmarks)**
```python
bronze_dynamic_frame = glueContext.create_dynamic_frame.from_catalog(
    database=args['bronze_database'],
    table_name=args['bronze_table'],
    transformation_ctx="bronze_source",  # ← Bookmark tracking
)
```
- ✅ Processa **apenas arquivos novos** no Bronze
- ✅ Rastreia arquivos já processados via `transformation_ctx`
- ✅ Evita reprocessamento desnecessário

### 2️⃣ **Transformações Silver (5 Etapas)**

#### A. Achatamento (Flattening)
```python
# Achatar struct 'metrics'
df_flattened = df.select(
    "*",
    F.col("metrics.engineTempCelsius").alias("metrics_engineTempCelsius"),
    F.col("metrics.trip.tripMileage").alias("metrics_trip_tripMileage"),
    ...
).drop("metrics")
```
- `metrics` → `metrics_engineTempCelsius`, `metrics_fuelAvailableLiters`, etc.
- `metrics.trip` → `metrics_trip_tripMileage`, `metrics_trip_tripFuelLiters`, etc.
- `carInsurance` → `carInsurance_number`, `carInsurance_provider`, etc.
- `market` → `market_currentPrice`, `market_location`, etc.

#### B. Limpeza (Cleansing)
```python
df_clean = df.withColumn("Manufacturer", F.initcap(F.col("Manufacturer")))
              .withColumn("color", F.lower(F.col("color")))
```
- `Manufacturer`: `hyundai` → `Hyundai` (Title Case)
- `color`: `Blue` → `blue` (lowercase)

#### C. Conversão de Tipos
```python
df_typed = df.withColumn(
    "metrics_metricTimestamp",
    F.to_timestamp(F.col("metrics_metricTimestamp"), "EEE, dd MMM yyyy HH:mm:ss")
)
```
- Timestamps: String → `timestamp` type
- Datas: String → `date` type

#### D. Enriquecimento (Enrichment)
```python
df_enriched = df.withColumn(
    "metrics_fuel_level_percentage",
    F.round((F.col("metrics_fuelAvailableLiters") / F.col("fuelCapacityLiters")) * 100, 2)
).withColumn(
    "metrics_trip_km_per_liter",
    F.round(F.col("metrics_trip_tripMileage") / F.col("metrics_trip_tripFuelLiters"), 2)
)
```
- `metrics_fuel_level_percentage`: (fuelAvailable / fuelCapacity) × 100
- `metrics_trip_km_per_liter`: tripMileage / tripFuelLiters

#### E. Particionamento (Event-based)
```python
df_partitioned = df.withColumn("event_year", F.year(F.col("metrics_metricTimestamp")))
                   .withColumn("event_month", F.month(F.col("metrics_metricTimestamp")))
                   .withColumn("event_day", F.dayofmonth(F.col("metrics_metricTimestamp")))
```
- Partições baseadas na **data do evento** (não da ingestão)
- Formato: `event_year=2025/event_month=10/event_day=29/`

### 3️⃣ **Consolidação (Upsert/Deduplicação)**

Este é o **coração do Job** que resolve o problema de duplicatas.

#### Passo A: Carregar Dados Existentes
```python
df_silver_existing = glueContext.create_dynamic_frame.from_catalog(
    database=args['silver_database'],
    table_name=args['silver_table']
).toDF()
```

#### Passo B: Unir Novos + Existentes
```python
df_union = df_silver_new.unionByName(df_silver_existing)
```

#### Passo C: Aplicar Deduplicação (Window Function)
```python
window_spec = Window.partitionBy(
    "carChassis",
    "event_year",
    "event_month",
    "event_day"
).orderBy(
    F.col("currentMileage").desc()  # ← Regra de precedência
)

df_deduplicated = df_union.withColumn(
    "row_num",
    F.row_number().over(window_spec)
).filter(
    F.col("row_num") == 1
).drop("row_num")
```

**Lógica de Deduplicação:**
- **Chave de negócio**: `carChassis` + `event_year` + `event_month` + `event_day`
- **Regra de precedência**: `currentMileage DESC` (maior milhagem = mais recente)
- **Resultado**: Mantém apenas 1 registro por combinação de chave

**Exemplo:**
```
ANTES DA DEDUPLICAÇÃO:
carChassis          | currentMileage | event_day | row_num
5ifRW...            | 4321           | 29        | 2  ← descartado
5ifRW...            | 8500           | 29        | 1  ← mantido ✅

DEPOIS DA DEDUPLICAÇÃO:
carChassis          | currentMileage | event_day
5ifRW...            | 8500           | 29        ← único registro
```

### 4️⃣ **Escrita (Dynamic Partition Overwrite)**

```python
spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")

glueContext.write_dynamic_frame.from_options(
    frame=silver_output_dynamic_frame,
    connection_type="s3",
    connection_options={
        "path": "s3://silver-bucket/car_telemetry/",
        "partitionKeys": ["event_year", "event_month", "event_day"]
    },
    format="parquet"
)
```

**Dynamic Partition Overwrite:**
- ✅ Sobrescreve **apenas** partições afetadas (ex: `event_day=29`)
- ✅ **Preserva** todas as outras partições intactas
- ✅ Evita reescrever o dataset inteiro

**Exemplo:**
```
PARTIÇÕES ANTES:
├── event_day=28/  ← intocado ✅
├── event_day=29/  ← sobrescrito (consolidado) 🔄
└── event_day=30/  ← intocado ✅
```

## 🚀 Como Usar

### 1. Criar o Glue Job no Terraform

Adicione ao seu `terraform/glue.tf`:

```hcl
resource "aws_glue_job" "silver_consolidation" {
  name     = "datalake-pipeline-silver-consolidation-dev"
  role_arn = aws_iam_role.glue_job_role.arn
  
  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.scripts.id}/glue_jobs/silver_consolidation_job.py"
    python_version  = "3"
  }
  
  glue_version = "4.0"
  
  default_arguments = {
    "--job-language"                     = "python"
    "--job-bookmark-option"              = "job-bookmark-enable"  # ← Bookmarks habilitados
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--TempDir"                          = "s3://${aws_s3_bucket.scripts.id}/temp/"
    
    # Parâmetros personalizados
    "--bronze_database"  = aws_glue_catalog_database.data_lake_database.name
    "--bronze_table"     = "bronze_ingest_year_2025"
    "--silver_database"  = aws_glue_catalog_database.data_lake_database.name
    "--silver_table"     = "silver_car_telemetry"
    "--silver_bucket"    = aws_s3_bucket.data_lake["silver"].id
    "--silver_path"      = "car_telemetry/"
  }
  
  max_retries      = 0
  timeout          = 60  # 60 minutos
  worker_type      = "G.1X"
  number_of_workers = 2
}
```

### 2. Fazer Upload do Script

```bash
aws s3 cp glue_jobs/silver_consolidation_job.py \
  s3://your-scripts-bucket/glue_jobs/
```

### 3. Executar o Job

**Manualmente:**
```bash
aws glue start-job-run --job-name datalake-pipeline-silver-consolidation-dev
```

**Agendado (via Trigger):**
```hcl
resource "aws_glue_trigger" "silver_consolidation_schedule" {
  name     = "silver-consolidation-daily"
  type     = "SCHEDULED"
  schedule = "cron(0 2 * * ? *)"  # Diariamente às 2 AM UTC
  
  actions {
    job_name = aws_glue_job.silver_consolidation.name
  }
}
```

## 📊 Exemplo de Execução

```
🚀 Job iniciado: silver-consolidation-dev
📅 Timestamp: 2025-10-30T15:45:00

📥 ETAPA 1: Leitura de dados novos do Bronze...
   ✅ Registros novos encontrados: 1

🔄 ETAPA 2: Aplicando transformações Silver...
   🔹 1/5: Achatando estruturas aninhadas (structs)...
      ✅ 36 colunas após achatamento
   🔹 2/5: Aplicando limpeza e padronização...
      ✅ Manufacturer → Title Case, color → lowercase
   🔹 3/5: Convertendo tipos de dados...
      ✅ Timestamps e datas convertidos
   🔹 4/5: Calculando métricas enriquecidas...
      ✅ Métricas calculadas
   🔹 5/5: Criando colunas de partição...
      ✅ Partições criadas

📚 ETAPA 3: Carregando dados existentes do Silver...
   ✅ Registros existentes: 1

🔀 ETAPA 4: Consolidando dados (Upsert/Deduplicação)...
   📊 Total antes da deduplicação: 2
   ✅ Total após deduplicação: 1
   🗑️  Duplicatas removidas: 1

💾 ETAPA 5: Escrevendo dados consolidados no Silver...
   ✅ Dados escritos com sucesso!
   📦 Registros finais: 1
   📂 Partições escritas: event_year=2025/event_month=10/event_day=29

✅ JOB CONCLUÍDO COM SUCESSO!
```

## 🧪 Validação no Athena

Após executar o Job, valide que não há duplicatas:

```sql
-- Verificar duplicatas (deve retornar 0)
SELECT carChassis, event_year, event_month, event_day, COUNT(*) as count
FROM silver_car_telemetry
GROUP BY carChassis, event_year, event_month, event_day
HAVING COUNT(*) > 1;

-- Verificar registro consolidado (deve mostrar currentMileage mais alto)
SELECT carChassis, currentMileage, metrics_metricTimestamp, event_day
FROM silver_car_telemetry
WHERE event_year = '2025' AND event_month = '10' AND event_day = '29';
```

## ⚡ Performance

**Otimizações Implementadas:**
- ✅ **Bookmarks**: Processa apenas dados novos
- ✅ **Predicate Pushdown**: Filtros aplicados no Data Catalog
- ✅ **Dynamic Partitioning**: Escreve apenas partições modificadas
- ✅ **Compression**: Parquet com Snappy
- ✅ **Columnar Format**: Queries otimizadas

**Escalabilidade:**
- Worker Type: `G.1X` (4 vCPU, 16 GB RAM)
- Workers: 2 (ajuste conforme volume de dados)
- Timeout: 60 minutos

## 🎯 Próximos Passos

1. **Criar Glue Job no Terraform**
2. **Fazer upload do script para S3**
3. **Executar job manualmente** para testar
4. **Executar Glue Crawler** no Silver para atualizar catálogo
5. **Validar no Athena** (verificar ausência de duplicatas)
6. **Configurar trigger agendado** (diário, horário, etc.)

## 📝 Notas Importantes

- ⚠️ **Primeira Execução**: Se tabela Silver não existir, apenas escreve dados novos
- ⚠️ **Regra de Deduplicação**: Ajuste `orderBy()` conforme sua regra de negócio
- ⚠️ **Bookmarks**: Não delete manualmente - use reset via AWS CLI se necessário
- ⚠️ **IAM Permissions**: Role do Glue precisa de `s3:GetObject`, `s3:PutObject`, `glue:GetTable`

---

**Autor**: Sistema de Data Lakehouse  
**Data**: 2025-10-30  
**Versão**: 1.0
