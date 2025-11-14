# Implementação de Correções - Gold Layer Iceberg

**Data:** 13 de Novembro de 2025  
**Branch:** ice  
**Status:** PRONTO PARA TESTE

---

## 🎯 Objetivo

Implementar correções avançadas nos Jobs Gold para forçar materialização do schema correto e eliminar o problema de colunas da Silver sendo incluídas na Gold.

---

## ✅ Alterações Implementadas

### 1. **Scripts PySpark - Todos os 3 Jobs Gold**

Arquivos modificados:
- `glue_jobs/gold_car_current_state_job_iceberg.py`
- `glue_jobs/gold_fuel_efficiency_job_iceberg.py`
- `glue_jobs/gold_performance_alerts_job_iceberg.py`

#### A. Habilitação de Checkpointing (Linha ~73)
```python
# Configure Spark checkpoint directory (for forced materialization)
print("\n  Configuring Spark checkpoint directory...")
spark.sparkContext.setCheckpointDir("s3://datalake-pipeline-glue-temp-dev/spark-checkpoints/gold/")
print("  ✅ Checkpoint directory set")
```

**Objetivo:** Configurar diretório S3 para checkpoint do Spark, permitindo quebra de linhagem.

#### B. Drop Explícito de Colunas Silver (Novo Step 2.5)
```python
# ============================================================================
# 3.5. DROP UNWANTED COLUMNS (EXPLICIT REMOVAL)
# ============================================================================

print("\n" + "=" * 80)
print(" STEP 2.5: Dropping Silver-inherited columns")
print("=" * 80)

# Explicitly drop Silver partition columns and Silver-only metadata
df_cleaned = df_with_kpis.drop(
    "event_id",               # Silver primary key (not needed in Gold)
    "event_primary_timestamp", # Silver metadata (not needed in Gold)
    "event_year",              # Silver partition column
    "event_month",             # Silver partition column
    "event_day"                # Silver partition column
)

print("\n  ✅ Dropped 5 Silver-inherited columns: event_id, event_primary_timestamp, event_year, event_month, event_day")
```

**Objetivo:** Remover explicitamente **ANTES** do `.select()` todas as colunas herdadas da Silver que não devem existir na Gold.

#### C. Seleção de Colunas Gold (Step 2.5 continuação)
```python
# Select only Gold columns from cleaned DataFrame
print("\n  Selecting final Gold layer columns from cleaned DataFrame...")
df_gold = df_cleaned.select(
    "car_chassis",
    "manufacturer",
    "model",
    "year",
    "gas_type",
    "insurance_provider",
    "insurance_valid_until",
    "current_mileage_km",
    "fuel_available_liters",
    "telemetry_timestamp",
    "insurance_status",
    "insurance_days_expired",
    "event_timestamp",
    "gold_processing_timestamp"
)
```

**Objetivo:** Selecionar apenas as 14 colunas corretas do DataFrame **JÁ LIMPO**.

#### D. Forçar Materialização via Checkpoint (Novo Step 2.6)
```python
# ============================================================================
# 3.6. FORCE MATERIALIZATION (CHECKPOINT - BREAKS LINEAGE)
# ============================================================================

print("\n  Checkpointing df_gold to break Spark lineage and force schema materialization...")
print("  This ensures Iceberg receives the EXACT schema defined above (14 columns)")

# CRITICAL: checkpoint() forces Spark to materialize the DataFrame and breaks lineage
# This prevents Iceberg from "looking back" at parent DataFrames (df_with_kpis)
df_gold = df_gold.checkpoint()

gold_count = df_gold.count()
print(f"\n  ✅ Checkpoint completed: {gold_count} rows materialized")
```

**Objetivo:** **QUEBRAR A LINHAGEM DO SPARK**. O `checkpoint()` força materialização física do DataFrame em S3 e elimina referências aos DataFrames pais (df_with_kpis, df_silver). O Iceberg não pode mais "olhar para trás" e usar schema anterior.

#### E. Validação de Schema (Novo Step 2.7)
```python
# ============================================================================
# 3.7. SCHEMA VALIDATION (DEBUGGING)
# ============================================================================

print("\n  Final schema being sent to Iceberg:")
df_gold.printSchema()

print(f"\n  Final column list ({len(df_gold.columns)} columns):")
for idx, col_name in enumerate(df_gold.columns, 1):
    print(f"    {idx}. {col_name}")

print("\n  ⚠️  CRITICAL CHECK: Verify NO Silver columns (event_id, event_year, etc.)")
silver_only_cols = ["event_id", "event_primary_timestamp", "event_year", "event_month", "event_day"]
found_silver_cols = [col for col in silver_only_cols if col in df_gold.columns]

if found_silver_cols:
    error_msg = f"❌ ERROR: Silver columns still present in df_gold: {found_silver_cols}"
    print(f"\n  {error_msg}")
    raise ValueError(error_msg)
else:
    print("\n  ✅ VALIDATION PASSED: No Silver-only columns in df_gold")
```

**Objetivo:** Validar com **erro fatal** se alguma coluna Silver ainda está presente. Logging detalhado para diagnóstico.

#### F. Criação da Tabela Iceberg
```python
# Create/Replace Iceberg table using writeTo() API
print("\n  Calling writeTo().createOrReplace()...")
print("  (Using checkpointed DataFrame with materialized schema)")

df_gold.writeTo(gold_table) \
    .using("iceberg") \
    .tableProperty("format-version", "2") \
    .createOrReplace()

print("\n  ✅ Table created/replaced successfully")
```

**Objetivo:** Usar API `writeTo()` com DataFrame **checkpointed** (sem linhagem).

---

### 2. **Infraestrutura Terraform**

Arquivo modificado:
- `terraform/iceberg_migration.tf`

#### A. Spark UI Path Atualizado (3 jobs)
```terraform
"--spark-event-logs-path" = "s3://${aws_s3_bucket.glue_temp.bucket}/spark-ui-logs/"
```

**Mudança:** `spark-logs/` → `spark-ui-logs/` (mais específico)

**Objetivo:** Logs organizados para análise do plano de execução Spark.

#### B. Workflow Sequential (JÁ IMPLEMENTADO)

Arquivo: `terraform/iceberg_event_driven.tf`

**Triggers configurados:**
1. **Trigger 1:** Silver SUCCESS → Gold Job 1 (Car Current State)
2. **Trigger 2:** Gold Job 1 SUCCESS → Gold Job 2 (Fuel Efficiency)
3. **Trigger 3:** Gold Job 2 SUCCESS → Gold Job 3 (Performance Alerts)

**Status:** ✅ Já estava implementado (Fase 18)

---

## 🔬 Teoria da Correção

### Problema Identificado
O Iceberg `writeTo().createOrReplace()` estava usando o schema do DataFrame **pai** (`df_with_kpis` com 19 colunas) ao invés do DataFrame **derivado** (`df_gold` com 14 colunas).

### Causa Raiz
**Lazy Evaluation do Spark + Lineage Tracking:**
- Spark mantém linhagem de transformações sem executá-las
- Iceberg pode estar inspecionando a linhagem e inferindo schema do DataFrame fonte (df_with_kpis)
- `.cache()` não quebra linhagem (apenas marca para materialização em memória)
- `.select()` é uma transformação lógica, não quebra linhagem

### Solução Implementada
**Forçar Materialização Física com `.checkpoint()`:**

1. **`.drop()` explícito** → Remove colunas Silver ANTES do `.select()`
2. **`.select()` específico** → Define schema Gold (14 colunas)
3. **`.checkpoint()`** → **QUEBRA LINHAGEM** e materializa fisicamente em S3
4. **Validação fatal** → Garante que não há colunas Silver
5. **`writeTo()`** → Usa DataFrame **sem linhagem** (apenas schema materializado)

**Diferença crítica:**
- **Antes:** `df_with_kpis (19 cols) → .select() → df_gold (14 cols logicamente)` → Iceberg vê linhagem e usa 19 cols
- **Depois:** `df_with_kpis (19 cols) → .drop() → .select() → .checkpoint()` → **Linhagem quebrada** → `df_gold (14 cols fisicamente)` → Iceberg vê apenas 14 cols

---

## 📊 Diagrama de Fluxo

### Fluxo ANTIGO (Falhava)
```
df_silver (19 cols com event_id)
    ↓ withColumn() [transformações lógicas]
df_with_kpis (19 cols ainda)
    ↓ select() [transformação lógica - não quebra linhagem]
df_gold (14 cols LOGICAMENTE)
    ↓ writeTo().createOrReplace()
    ↓ [Iceberg inspeciona linhagem, vê df_with_kpis]
❌ Tabela criada com 19 colunas
```

### Fluxo NOVO (Deve Funcionar)
```
df_silver (19 cols com event_id)
    ↓ withColumn() [transformações lógicas]
df_with_kpis (19 cols ainda)
    ↓ drop() [remove explícitamente 5 cols]
df_cleaned (14 cols)
    ↓ select() [seleciona 14 cols específicas]
df_gold (14 cols LOGICAMENTE)
    ↓ checkpoint() [QUEBRA LINHAGEM - materialização física S3]
    ↓ [Grava parquet no S3, destroi histórico de transformações]
df_gold (14 cols FISICAMENTE - sem linhagem)
    ↓ writeTo().createOrReplace()
    ↓ [Iceberg recebe DataFrame sem linhagem, usa schema físico]
✅ Tabela criada com 14 colunas
```

---

## 🚀 Próximos Passos para Teste

### 1. Limpar Ambiente
```bash
# Deletar tabelas Gold existentes
aws glue delete-table --database-name "datalake_pipeline_catalog_dev" --name "gold_car_current_state_new"
aws glue delete-table --database-name "datalake_pipeline_catalog_dev" --name "fuel_efficiency_monthly"
aws glue delete-table --database-name "datalake_pipeline_catalog_dev" --name "performance_alerts_log_slim"

# Limpar S3 Gold
aws s3 rm "s3://datalake-pipeline-gold-dev/iceberg-warehouse/datalake_pipeline_catalog_dev.db/" --recursive

# Limpar checkpoints anteriores
aws s3 rm "s3://datalake-pipeline-glue-temp-dev/spark-checkpoints/" --recursive
```

### 2. Upload Scripts Corrigidos
```bash
cd c:\dev\HP\wsas\Poc

# Upload dos 3 jobs Gold corrigidos
aws s3 cp glue_jobs/gold_car_current_state_job_iceberg.py s3://datalake-pipeline-glue-scripts-dev/
aws s3 cp glue_jobs/gold_fuel_efficiency_job_iceberg.py s3://datalake-pipeline-glue-scripts-dev/
aws s3 cp glue_jobs/gold_performance_alerts_job_iceberg.py s3://datalake-pipeline-glue-scripts-dev/
```

### 3. Aplicar Terraform
```bash
cd terraform
terraform apply -target=aws_glue_job.gold_car_current_state_iceberg
terraform apply -target=aws_glue_job.gold_fuel_efficiency_iceberg
terraform apply -target=aws_glue_job.gold_performance_alerts_iceberg
```

### 4. Executar Workflow
```bash
# Aguardar 2 minutos para propagação S3
Start-Sleep -Seconds 120

# Iniciar workflow
aws glue start-workflow-run --name "datalake-pipeline-silver-gold-workflow-dev-eventdriven"
```

### 5. Monitorar Execução (10-15 minutos)
```bash
# Obter RunId
$runId = (aws glue get-workflow-runs --name "datalake-pipeline-silver-gold-workflow-dev-eventdriven" --max-results 1 --query "Runs[0].WorkflowRunId" --output text)

# Aguardar 10 minutos
Start-Sleep -Seconds 600

# Verificar status
aws glue get-workflow-run --name "datalake-pipeline-silver-gold-workflow-dev-eventdriven" --run-id $runId
```

---

## 📝 Pontos de Atenção no Log

### Sucesso Esperado:
```
✅ Checkpoint directory set
✅ Dropped 5 Silver-inherited columns: event_id, event_primary_timestamp, event_year, event_month, event_day
✅ Checkpoint completed: 11 rows materialized
✅ VALIDATION PASSED: No Silver-only columns in df_gold
Final column list (14 columns):
    1. car_chassis
    2. manufacturer
    ...
    14. gold_processing_timestamp
✅ Table created/replaced successfully
```

### Falha (Schema validation):
```
❌ ERROR: Silver columns still present in df_gold: ['event_id', 'event_year']
ValueError: Silver columns still present in df_gold: ['event_id', 'event_year']
```

---

## 🎯 Expectativa de Resultado

### Se FUNCIONAR ✅:
- Job Gold 1: **SUCCEEDED** (criação da tabela com 14 colunas)
- Job Gold 2: **SUCCEEDED** (dependência satisfeita)
- Job Gold 3: **SUCCEEDED** (pipeline completo)
- Tabelas Gold consultáveis via Athena
- **Problema resolvido**

### Se FALHAR ❌:
- Analisar CloudWatch Logs para ver qual validação falhou
- Verificar Spark UI para inspeção do plano físico (Spark event logs em `s3://.../spark-ui-logs/`)
- Se erro persiste mesmo com checkpoint → **Bug confirmado do Iceberg/Glue 4.0** → Escalar AWS Support com evidências

---

## 📦 Arquivos Modificados (Para Commit)

```
glue_jobs/
├── gold_car_current_state_job_iceberg.py    [MODIFICADO - checkpoint + validação]
├── gold_fuel_efficiency_job_iceberg.py       [MODIFICADO - checkpoint + validação]
└── gold_performance_alerts_job_iceberg.py    [MODIFICADO - checkpoint + validação]

terraform/
└── iceberg_migration.tf                      [MODIFICADO - spark-ui-logs path]

IMPLEMENTACAO_CORRECOES_GOLD.md              [NOVO - este documento]
```

---

## 🔧 Rollback (Se Necessário)

Se as correções causarem novos problemas:

```bash
# Reverter para versão anterior dos scripts
git checkout HEAD~1 glue_jobs/gold_*_iceberg.py

# Re-upload
aws s3 cp glue_jobs/gold_car_current_state_job_iceberg.py s3://datalake-pipeline-glue-scripts-dev/
aws s3 cp glue_jobs/gold_fuel_efficiency_job_iceberg.py s3://datalake-pipeline-glue-scripts-dev/
aws s3 cp glue_jobs/gold_performance_alerts_job_iceberg.py s3://datalake-pipeline-glue-scripts-dev/
```

---

**Preparado por:** GitHub Copilot AI Assistant  
**Data:** 13/11/2025 16:15 BRT  
**Versão:** 1.0  
**Status:** PRONTO PARA TESTE
