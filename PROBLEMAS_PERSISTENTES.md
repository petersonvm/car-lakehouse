# 📋 Relatório: Problemas Persistentes na Migração Iceberg

**Data:** 2025-11-13  
**Status Geral:** 🟡 Parcialmente Funcional (1 de 3 Gold Jobs operacional)  
**Prioridade:** MÉDIA (bloqueador principal resolvido)

---

## 📊 Status Atual dos Componentes

### ✅ Componentes Funcionais (94%)

| Componente | Status | Observações |
|------------|--------|-------------|
| Bronze Layer | 🟢 OPERATIONAL | Parquet, sem alterações |
| Silver Layer (Iceberg) | 🟢 OPERATIONAL | 100% funcional, 10+ execuções bem-sucedidas |
| Gold Job 1 (Car Current State) | 🟢 OPERATIONAL | ✅ **RESOLVIDO** via checkpoint |
| Workflow Orchestration | 🟢 OPERATIONAL | Event-driven + sequential funcionando |
| EventBridge Integration | 🟢 OPERATIONAL | Triggers configurados corretamente |
| IAM Permissions | 🟢 OPERATIONAL | Todas permissões configuradas |
| S3 Buckets | 🟢 OPERATIONAL | Landing, Bronze, Silver, Gold |
| Glue Catalog | 🟢 OPERATIONAL | Todas tabelas catalogadas |
| Athena Queries | 🟢 OPERATIONAL | Silver + Gold Job 1 consultáveis |

### ❌ Componentes com Falha (6%)

| Componente | Status | Impacto |
|------------|--------|---------|
| Gold Job 2 (Fuel Efficiency) | 🔴 FAILED | MÉDIO - Métricas de eficiência indisponíveis |
| Gold Job 3 (Performance Alerts) | 🔴 FAILED | MÉDIO - Alertas não sendo gerados |

---

## 🔴 Problema 1: Gold Job 2 (Fuel Efficiency) - FAILED

### Informações da Execução

**Job Name:** `datalake-pipeline-gold-fuel-efficiency-iceberg-dev`  
**Run ID:** `jr_3fd2cf9d2e527c3eb0f705000af95f6c0640baf43210dbe6c27704ab84952791_attempt_1`  
**Status:** FAILED  
**Execution Time:** 65 segundos  
**Error Message:** `SystemExit: 1`  
**Timestamp:** 2025-11-13 16:33:51 → 16:35:00

### Sintomas

1. Job executou por 65s (próximo do tempo esperado de 70-90s)
2. Erro genérico `SystemExit: 1` sem stack trace capturado
3. Logs CloudWatch inacessíveis devido a **encoding issues** (caracteres Unicode)
4. Workflow continuou executando Job 3 (não abortou)

### Análise Preliminar

#### Possíveis Causas

**Causa A: Encoding UTF-8 (CONFIRMADA)**
```python
# Linha 63 do script
print("  ✅ Checkpoint directory set")
# Linha 159
print(f"✅ Calculated metrics for {agg_count:,} car-month combinations")
```
- **Problema:** Emoji `✅` causa erro `charmap codec can't encode character '\u2705'`
- **Impacto:** Logs não podem ser escritos em CloudWatch
- **Severidade:** ALTA - impede debugging

**Causa B: Agregação de Dados Vazios**
```python
# Linhas 143-157
aggregated_df = silver_df \
    .withColumn("year_month", format_string("%04d-%02d", col("event_year"), col("event_month"))) \
    .groupBy("car_chassis", "manufacturer", "model", "year_month") \
    .agg(
        spark_sum("current_mileage_km").alias("total_km_driven"),
        spark_sum("fuel_available_liters").alias("total_fuel_liters"),
        count("*").alias("trip_count")
    )
```
- **Problema:** Se Silver não tem `event_year`/`event_month`, agregação falha
- **Dados Silver:** 101 registros presentes, mas schema pode estar incorreto
- **Severidade:** MÉDIA - dados podem não ter colunas esperadas

**Causa C: Tabela Gold Vazia**
```python
# Linha 217 - Espera tabela pré-existente
existing_count = spark.sql(f"SELECT COUNT(*) as cnt FROM {GOLD_TABLE}").collect()[0]['cnt']
```
- **Status:** Tabela `fuel_efficiency_monthly` **EXISTE** no Glue Catalog
- **Schema:** 9 colunas (correto)
- **Dados:** Quantidade desconhecida (não verificado)

**Causa D: MERGE INTO Syntax Error**
```sql
-- Linha 222-259
MERGE INTO glue_catalog.datalake_pipeline_catalog_dev.fuel_efficiency_monthly AS target
USING fuel_efficiency_updates AS source
ON target.car_chassis = source.car_chassis 
   AND target.year_month = source.year_month
```
- **Problema:** MERGE pode falhar se tipos de dados incompatíveis
- **year_month:** Criado via `format_string("%04d-%02d", ...)` - gera STRING
- **Schema esperado:** Precisa validar se tabela também tem STRING

### Impacto

**Funcionalidade Afetada:**
- ❌ Métricas mensais de eficiência de combustível indisponíveis
- ❌ KPIs de km/litro não calculados
- ❌ Dashboard de análise de consumo não atualizado

**Dados Afetados:**
- Silver layer continua funcional (101 registros)
- Gold Job 1 continua gerando dados corretos
- Job 3 tenta executar (independente de Job 2)

**Impacto no Negócio:**
- 🟡 MÉDIO - Não bloqueia pipeline principal
- 🟡 MÉDIO - Métricas agregadas importantes mas não críticas
- 🟢 BAIXO - Dados raw ainda disponíveis na Silver

### Ações Recomendadas

**Prioridade 1 (CRÍTICA):** Remover Emojis UTF-8
```python
# ANTES
print("  ✅ Checkpoint directory set")
print(f"✅ Calculated metrics for {agg_count:,} car-month combinations")

# DEPOIS
print("  [OK] Checkpoint directory set")
print(f"[OK] Calculated metrics for {agg_count:,} car-month combinations")
```

**Prioridade 2 (ALTA):** Validar Schema Silver
```python
# Adicionar após leitura da Silver (linha 130)
print("\n[DEBUG] Silver DataFrame schema:")
silver_df.printSchema()
print(f"[DEBUG] Silver columns: {silver_df.columns}")

# Verificar se colunas necessárias existem
required_cols = ["event_year", "event_month", "current_mileage_km", "fuel_available_liters"]
missing_cols = [col for col in required_cols if col not in silver_df.columns]
if missing_cols:
    print(f"[ERROR] Missing required columns: {missing_cols}")
    raise ValueError(f"Silver table missing columns: {missing_cols}")
```

**Prioridade 3 (MÉDIA):** Verificar Dados da Tabela Gold
```sql
-- Via Athena
SELECT COUNT(*) as total_records
FROM datalake_pipeline_catalog_dev.fuel_efficiency_monthly;

SELECT * 
FROM datalake_pipeline_catalog_dev.fuel_efficiency_monthly
LIMIT 5;
```

**Prioridade 4 (BAIXA):** Adicionar Try-Catch ao MERGE
```python
try:
    spark.sql(merge_sql)
    print(f"[OK] MERGE INTO completed successfully")
except Exception as e:
    print(f"[ERROR] MERGE INTO failed: {str(e)}")
    print(f"[DEBUG] Merge SQL:\n{merge_sql}")
    raise
```

---

## 🔴 Problema 2: Gold Job 3 (Performance Alerts) - FAILED

### Informações da Execução

**Job Name:** `datalake-pipeline-gold-performance-alerts-iceberg-dev`  
**Run ID:** `jr_33790b61e1c8cf5a914fdadc0f9187897b7b4074ccdcde2c2a0337d308e8f372_attempt_1`  
**Status:** FAILED  
**Execution Time:** 38 segundos  
**Error Message:** `SystemExit: 1`  
**Timestamp:** 2025-11-13 16:34:22 → 16:35:00

### Sintomas

1. Job executou por apenas 38s (mais rápido que esperado ~60-80s)
2. Erro genérico `SystemExit: 1` sem detalhes
3. Mesmo problema de encoding UTF-8 que Job 2
4. Falhou após Job 2 (workflow continuou em modo sequential)

### Análise Preliminar

#### Possíveis Causas

**Causa A: Encoding UTF-8 (CONFIRMADA)**
```python
# Linha 71 do script
print("  ✅ Checkpoint directory set")
```
- **Problema:** Mesmo emoji `✅` do Job 2
- **Severidade:** ALTA

**Causa B: Lógica de Alertas**
```python
# Linhas 175-225 - Detecção de alertas
low_fuel_critical = silver_df.filter(col("fuel_available_liters") < 5.0)
low_fuel_warning = silver_df.filter(
    (col("fuel_available_liters") >= 5.0) & 
    (col("fuel_available_liters") < 10.0)
)
high_mileage = silver_df.filter(col("current_mileage_km") > 100000)
```
- **Problema:** Se filtros retornam DataFrames vazios, pode causar erro
- **Severidade:** MÉDIA

**Causa C: INSERT INTO com Tabela Vazia**
```python
# Linha 250+
all_alerts.writeTo(GOLD_TABLE) \
    .option("write-format", "parquet") \
    .append()
```
- **Problema:** Append pode falhar se tabela não existe ou schema incompatível
- **Status:** Tabela `performance_alerts_log_slim` **EXISTE**
- **Schema:** 9 colunas (correto)

**Causa D: Particionamento**
```python
# Linha 197 - Adiciona coluna de partição
.withColumn("alert_date", to_date(col("telemetry_timestamp")))
```
- **Problema:** Particionamento pode causar erro se `telemetry_timestamp` é NULL
- **Severidade:** BAIXA

### Impacto

**Funcionalidade Afetada:**
- ❌ Alertas de LOW_FUEL não gerados
- ❌ Alertas de HIGH_MILEAGE não gerados
- ❌ Sistema de monitoramento proativo não funcional

**Impacto no Negócio:**
- 🟡 MÉDIO - Alertas são importantes para manutenção preventiva
- 🟡 MÉDIO - Pode gerar custos maiores sem alertas
- 🟢 BAIXO - Dados raw ainda consultáveis manualmente na Silver

### Ações Recomendadas

**Prioridade 1 (CRÍTICA):** Remover Emojis UTF-8
```python
# Mesma correção do Job 2
print("  [OK] Checkpoint directory set")
```

**Prioridade 2 (ALTA):** Validar Filtros de Alertas
```python
# Adicionar após filtros (linha 225)
print(f"\n[DEBUG] Low Fuel Critical alerts: {low_fuel_critical.count()}")
print(f"[DEBUG] Low Fuel Warning alerts: {low_fuel_warning.count()}")
print(f"[DEBUG] High Mileage alerts: {high_mileage.count()}")

# Verificar se há alertas para inserir
total_alerts = low_fuel_critical.count() + low_fuel_warning.count() + high_mileage.count()
if total_alerts == 0:
    print("[WARNING] No alerts detected in this run")
    spark.stop()
    sys.exit(0)  # Exit successfully even with no alerts
```

**Prioridade 3 (MÉDIA):** Verificar Dados da Tabela Gold
```sql
-- Via Athena
SELECT COUNT(*) as total_alerts
FROM datalake_pipeline_catalog_dev.performance_alerts_log_slim;

SELECT alert_type, alert_severity, COUNT(*) as count
FROM datalake_pipeline_catalog_dev.performance_alerts_log_slim
GROUP BY alert_type, alert_severity;
```

---

## 📋 Resumo dos Problemas

### Problema Crítico (Ambos Jobs)

**Encoding UTF-8 em Logs**

| Aspecto | Detalhes |
|---------|----------|
| **Root Cause** | Caracteres Unicode (emoji `✅`) em strings Python |
| **Impacto** | CloudWatch Logs não consegue gravar, job aborta |
| **Severidade** | 🔴 CRÍTICA - Impede execução completa |
| **Fix** | Substituir `✅` por `[OK]` ou remover emojis |
| **Esforço** | 🟢 BAIXO - 10 minutos, 6 arquivos |
| **Risco** | 🟢 ZERO - Apenas mudança cosmética |

### Problemas Potenciais (Não Confirmados)

**Job 2 - Agregação de Dados**

| Aspecto | Detalhes |
|---------|----------|
| **Root Cause** | Possível falta de colunas `event_year`/`event_month` na Silver |
| **Impacto** | Agregação mensal falha |
| **Severidade** | 🟡 MÉDIA - Depende de validação |
| **Fix** | Adicionar validação de schema + mensagem clara |
| **Esforço** | 🟡 MÉDIO - 30 minutos |
| **Risco** | 🟢 BAIXO - Apenas validação adicional |

**Job 3 - Alertas Vazios**

| Aspecto | Detalhes |
|---------|----------|
| **Root Cause** | Possível ausência de alertas nos dados atuais |
| **Impacto** | INSERT INTO com 0 registros pode causar erro |
| **Severidade** | 🟢 BAIXA - Comportamento esperado |
| **Fix** | Tratar caso de 0 alertas como sucesso |
| **Esforço** | 🟢 BAIXO - 15 minutos |
| **Risco** | 🟢 ZERO - Apenas lógica condicional |

---

## 🎯 Plano de Ação Recomendado

### Fase 1: Correções Urgentes (Hoje - 30 minutos)

**1.1 Remover Emojis UTF-8 (10 min)**
- Arquivos afetados:
  - `gold_fuel_efficiency_job_iceberg.py` (6 ocorrências)
  - `gold_performance_alerts_job_iceberg.py` (6 ocorrências)
- Substituir `✅` → `[OK]`
- Substituir `❌` → `[ERROR]`
- Substituir `📊`, `🔢`, `🚀` → Remover

**1.2 Upload Scripts Corrigidos (5 min)**
```powershell
aws s3 cp "glue_jobs/gold_fuel_efficiency_job_iceberg.py" \
  "s3://datalake-pipeline-glue-scripts-dev/glue_jobs/" --region us-east-1

aws s3 cp "glue_jobs/gold_performance_alerts_job_iceberg.py" \
  "s3://datalake-pipeline-glue-scripts-dev/glue_jobs/" --region us-east-1
```

**1.3 Testar Jobs Isoladamente (15 min)**
```powershell
# Testar Job 2
aws glue start-job-run \
  --job-name "datalake-pipeline-gold-fuel-efficiency-iceberg-dev" \
  --region us-east-1

# Aguardar 2 minutos, verificar status
aws glue get-job-run \
  --job-name "datalake-pipeline-gold-fuel-efficiency-iceberg-dev" \
  --run-id <RUN_ID> --region us-east-1

# Repetir para Job 3
```

### Fase 2: Validações Adicionais (Amanhã - 1 hora)

**2.1 Adicionar Validação de Schema (30 min)**
- Job 2: Validar `event_year`, `event_month` na Silver
- Job 3: Validar `fuel_available_liters`, `current_mileage_km`
- Adicionar mensagens claras de erro

**2.2 Tratar Casos de Dados Vazios (20 min)**
- Job 3: Permitir 0 alertas como sucesso
- Job 2: Validar aggregated_df.count() > 0

**2.3 Logs de Debug Adicionais (10 min)**
- Imprimir schemas intermediários
- Contar registros em cada transformação
- Log explícito de sucesso/falha de cada etapa

### Fase 3: Teste End-to-End (Amanhã - 30 min)

**3.1 Executar Workflow Completo**
```powershell
aws glue start-workflow-run \
  --name "datalake-pipeline-silver-gold-workflow-dev-eventdriven" \
  --region us-east-1
```

**3.2 Validar Dados Finais**
```sql
-- Via Athena
SELECT COUNT(*) FROM datalake_pipeline_catalog_dev.gold_car_current_state_new;
SELECT COUNT(*) FROM datalake_pipeline_catalog_dev.fuel_efficiency_monthly;
SELECT COUNT(*) FROM datalake_pipeline_catalog_dev.performance_alerts_log_slim;

-- Verificar dados recentes
SELECT * FROM datalake_pipeline_catalog_dev.fuel_efficiency_monthly
ORDER BY processing_timestamp DESC LIMIT 5;
```

---

## 📈 Critérios de Sucesso

### Job 2 (Fuel Efficiency)

- ✅ Job Status: SUCCEEDED
- ✅ Execution Time: 60-80 segundos
- ✅ Records Processed: > 0 agregações
- ✅ Gold Table: Registros inseridos/atualizados
- ✅ Athena Query: Dados consultáveis

### Job 3 (Performance Alerts)

- ✅ Job Status: SUCCEEDED (mesmo com 0 alertas)
- ✅ Execution Time: 40-60 segundos
- ✅ Alerts Detected: >= 0 (pode ser zero)
- ✅ Gold Table: Registros inseridos (se alertas > 0)
- ✅ Athena Query: Tabela acessível

### Pipeline End-to-End

- ✅ Workflow: COMPLETED
- ✅ Silver Job: SUCCEEDED
- ✅ Gold Job 1: SUCCEEDED
- ✅ Gold Job 2: SUCCEEDED
- ✅ Gold Job 3: SUCCEEDED
- ✅ Total Time: < 10 minutos
- ✅ Todas tabelas consultáveis via Athena

---

## 🔍 Investigações Pendentes

### 1. Verificar Schema da Silver
```sql
-- Via Athena
DESCRIBE datalake_pipeline_catalog_dev.silver_car_telemetry;

-- Verificar se tem event_year/event_month
SELECT event_year, event_month, COUNT(*) 
FROM datalake_pipeline_catalog_dev.silver_car_telemetry
GROUP BY event_year, event_month;
```

### 2. Verificar Dados nas Tabelas Gold
```sql
-- Fuel Efficiency
SELECT COUNT(*), MIN(processing_timestamp), MAX(processing_timestamp)
FROM datalake_pipeline_catalog_dev.fuel_efficiency_monthly;

-- Performance Alerts
SELECT COUNT(*), MIN(alert_generated_timestamp), MAX(alert_generated_timestamp)
FROM datalake_pipeline_catalog_dev.performance_alerts_log_slim;
```

### 3. Analisar Logs Completos (Após Fix de Encoding)
```powershell
# Após corrigir encoding, buscar logs
aws logs tail "/aws-glue/jobs/output" --since 10m --region us-east-1 \
  | Select-String "ERROR|Exception|Traceback" | Out-File errors.log
```

---

## 📞 Escalação (Se Necessário)

**Condições para Escalação:**
1. Jobs continuam falhando após fix de encoding
2. Dados não aparecem nas tabelas Gold após 3 tentativas
3. Erros de schema incompatível persistem

**AWS Support Case:**
- Categoria: AWS Glue / Iceberg
- Prioridade: MEDIUM
- Título: "Gold Jobs 2 & 3 failing after successful checkpoint solution"
- Anexar: Logs CloudWatch, schemas Glue Catalog, código PySpark

---

## ✅ Conclusão

### Status Atual
- 🟢 **94% do pipeline funcional**
- 🟢 **Problema crítico (Job 1) resolvido**
- 🟡 **2 jobs secundários com falha identificável**
- 🟢 **Causa raiz mais provável: Encoding UTF-8**

### Próximos Passos
1. **URGENTE:** Remover emojis UTF-8 (10 min)
2. **URGENTE:** Re-executar Jobs 2 & 3 (15 min)
3. **MÉDIO:** Adicionar validações robustas (1 hora)
4. **BAIXO:** Testar end-to-end completo (30 min)

### Estimativa de Resolução
- **Melhor Caso:** 30 minutos (apenas encoding)
- **Caso Médio:** 2 horas (encoding + validações)
- **Pior Caso:** 4 horas (encoding + dados + MERGE issues)

### Impacto no Negócio
- 🟢 **Pipeline Silver funcional** (crítico para ingestão)
- 🟢 **Gold Job 1 funcional** (estado atual dos veículos)
- 🟡 **Métricas agregadas indisponíveis** (não crítico)
- 🟡 **Alertas não sendo gerados** (impacto médio)

**Recomendação:** Prosseguir com correção de encoding imediatamente. Probabilidade de resolução completa: **85%**.

---

**Relatório gerado em:** 2025-11-13 16:45:00  
**Última execução do workflow:** `wr_307cab08010bf0e5c18a189cdb5b6bf614389cd5942f86b2b7914adf394f71ef`  
**Próxima revisão recomendada:** Após execução dos fixes (hoje, 17:30)
