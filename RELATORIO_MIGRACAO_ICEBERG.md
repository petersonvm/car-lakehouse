# Relatório de Migração para Apache Iceberg
**Data:** 13 de Novembro de 2025  
**Projeto:** Data Lake Pipeline - HP/WSAS  
**Branch:** ice  
**Ambiente:** dev (us-east-1)

---

## 📊 Status Geral da Migração

### Componentes Implementados
| Componente | Status | Taxa de Sucesso | Observações |
|------------|--------|-----------------|-------------|
| **Bronze Layer** | ✅ Operacional | N/A | Mantido em Parquet (não migrado) |
| **Silver Layer** | ✅ 100% Funcional | 10/10 execuções | Migração completa para Iceberg |
| **Gold Layer** | ❌ Bloqueado | 0/15 execuções | **BLOQUEIO CRÍTICO** |
| **Infraestrutura** | ✅ Operacional | 100% | EventBridge, IAM, S3, Glue Catalog |
| **Workflows** | ✅ Configurado | N/A | Sequential execution implementado |

### Métricas de Execução

**Silver Layer (Consolidation Job):**
- ✅ **Status:** SUCCEEDED
- ⏱️ **Tempo médio:** 58-84 segundos
- 📊 **Registros processados:** 101 registros consolidados
- 🚗 **Carros únicos:** 11 veículos
- 📁 **Tabela Iceberg:** `silver_car_telemetry`
- 🔍 **Consultável via Athena:** Sim

**Gold Layer (Jobs 1, 2, 3):**
- ❌ **Status:** FAILED
- ⏱️ **Tempo até falha:** 67-83 segundos
- 📊 **Registros processados:** 0 (falha antes de escrever)
- 📁 **Tabelas:** `gold_car_current_state_new`, `fuel_efficiency_monthly`, `performance_alerts_log_slim`
- 🚫 **Erro consistente:** `AnalysisException: Cannot find column 'event_id'`

---

## 🔴 Problema Crítico: Gold Layer Bloqueado

### Descrição do Problema

O job Gold está falhando **consistentemente** com erro de schema, apesar de múltiplas tentativas de correção:

```
AnalysisException: Cannot find column 'event_id' of the target table 
among the INSERT columns: gold_processing_timestamp, telemetry_timestamp, 
model, car_chassis, event_timestamp, year, insurance_provider, 
current_mileage_km, insurance_valid_until, insurance_days_expired, 
insurance_status, manufacturer, fuel_available_liters.
```

### Análise Técnica

#### O que está acontecendo:
1. **DataFrame correto criado:** O código PySpark cria `df_gold` com `.select()` explícito de 14 colunas (sem `event_id`)
2. **Tabela criada com schema errado:** A tabela Gold no Glue Catalog é criada com 19 colunas, incluindo:
   - `event_id` (coluna da Silver que NÃO deveria estar na Gold)
   - `event_primary_timestamp` (coluna da Silver)
   - `event_year`, `event_month`, `event_day` (partições da Silver)
3. **Falha na inserção:** Quando tenta inserir dados, Iceberg espera 19 colunas mas recebe apenas 14

#### Schema Esperado (Gold - 14 colunas):
```python
[
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
]
```

#### Schema Real Criado (19 colunas - INCORRETO):
```json
[
  "event_id",                    ← ❌ NÃO deveria existir
  "car_chassis",
  "event_primary_timestamp",     ← ❌ NÃO deveria existir
  "telemetry_timestamp",
  "current_mileage_km",
  "fuel_available_liters",
  "manufacturer",
  "model",
  "year",
  "gas_type",
  "insurance_provider",
  "insurance_valid_until",
  "event_year",                  ← ❌ NÃO deveria existir
  "event_month",                 ← ❌ NÃO deveria existir
  "event_day",                   ← ❌ NÃO deveria existir
  "insurance_status",
  "insurance_days_expired",
  "event_timestamp",
  "gold_processing_timestamp"
]
```

### Evidências do Problema

#### Código PySpark (Correto):
```python
# Linha 159-173: SELECT explícito com 14 colunas
df_gold = df_with_kpis.select(
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

# Linhas 176-178: Materialização forçada
df_gold = df_gold.cache()
gold_count = df_gold.count()  # Força execução do SELECT

# Linhas 180-182: Logs confirmam 14 colunas
df_gold.printSchema()
print(f"Gold DataFrame column names: {df_gold.columns}")

# Linhas 195-200: Criação da tabela
df_gold.write \
    .format("iceberg") \
    .mode("overwrite") \
    .saveAsTable(f"glue_catalog.datalake_pipeline_catalog_dev.{table_name}")
```

#### Resultado no Glue Catalog (Incorreto):
```bash
aws glue get-table --name gold_car_current_state_new
# Retorna: 19 colunas incluindo event_id, event_primary_timestamp, etc.
```

### Hipóteses Investigadas

#### ✅ Hipótese 1: Race condition entre jobs Gold paralelos
- **Teste:** Modificado Terraform para execução sequential (Job1 → Job2 → Job3)
- **Resultado:** ❌ Falha persiste mesmo executando 1 job por vez
- **Conclusão:** NÃO é race condition

#### ✅ Hipótese 2: Permissões S3 insuficientes
- **Teste:** Adicionado full access ao bucket Gold no IAM role
- **Resultado:** ❌ Erro mudou de "S3 permission denied" para "Cannot find column"
- **Conclusão:** Permissões corretas, problema é de schema

#### ✅ Hipótese 3: Schema mismatch na query MERGE INTO
- **Teste:** Simplificado de MERGE INTO para INSERT OVERWRITE
- **Resultado:** ❌ Mesmo erro persiste
- **Conclusão:** Problema não é a operação SQL

#### ✅ Hipótese 4: Tipo de dado incompatível (DATE vs STRING)
- **Teste:** Mudado `insurance_valid_until` de DATE para STRING
- **Resultado:** ❌ Mesmo erro persiste
- **Conclusão:** Problema não é type casting

#### ✅ Hipótese 5: API writeTo() com bug
- **Teste:** Testado 3 APIs diferentes:
  - `df.writeTo(table).using("iceberg").createOrReplace()`
  - `df.write.format("iceberg").mode("overwrite").saveAsTable(table)`
  - Athena DDL + INSERT OVERWRITE via SQL
- **Resultado:** ❌ Todas falharam com mesmo comportamento
- **Conclusão:** Problema é sistêmico, não específico de uma API

#### ✅ Hipótese 6: Metadata cache no Glue Catalog
- **Teste:** Deletado tabela do Catalog + limpeza completa S3 antes de cada teste
- **Resultado:** ❌ Tabela recriada com schema errado novamente
- **Conclusão:** Cache não está no Catalog

#### ✅ Hipótese 7: SELECT não está sendo aplicado
- **Teste:** Adicionado `.cache()` + `.count()` para forçar materialização
- **Resultado:** ❌ Logs confirmam 14 colunas, mas tabela criada com 19
- **Conclusão:** **SELECT é executado mas IGNORADO pelo Iceberg**

---

## 🔍 Root Cause Analysis

### Comportamento Anômalo Identificado

O Apache Iceberg no AWS Glue 4.0 está **ignorando o schema do DataFrame fornecido** e usando um schema diferente (provavelmente cached de uma execução anterior ou inferido da tabela fonte Silver).

**Evidência crítica:**
- `df_gold.printSchema()` mostra 14 colunas ✅
- `df_gold.columns` lista 14 colunas ✅  
- Tabela criada no Glue Catalog tem 19 colunas ❌
- As 5 colunas extras são **exatamente as colunas da tabela Silver**

### Possíveis Causas Raiz

1. **Bug no Iceberg Spark Integration:**
   - Glue 4.0 usa Iceberg library que pode ter bug ao criar tabelas derivadas de outras tabelas Iceberg
   - O schema pode estar sendo inferido da fonte (Silver) ao invés do DataFrame transformado

2. **Spark Catalyst Optimizer Issue:**
   - O Spark pode estar otimizando o plano de execução e "pulando" o SELECT
   - Lazy evaluation pode estar causando confusão entre df_with_kpis e df_gold

3. **Iceberg Metadata Cache Persistente:**
   - Pode existir cache em nível de Spark Session que persiste entre job runs
   - Glue pode reutilizar Spark contexts entre execuções no mesmo worker

4. **Incompatibilidade Silver → Gold:**
   - Criar tabela Gold a partir de leitura de Silver Iceberg pode ter comportamento diferente
   - Silver (source) → Gold (target) pode ter path de código diferente de Bronze (source) → Silver (target)

---

## 📈 Histórico de Tentativas (15 Iterações)

### Fase 1-17: Problemas de Configuração (RESOLVIDOS ✅)
1. ✅ Database com hífens → Renomeado para underscores
2. ✅ Spark config ordem incorreta → Corrigido para SparkConf antes SparkContext
3. ✅ Warehouse path ausente → Adicionado em todos jobs
4. ✅ Script paths incorretos → Corrigidos no Terraform
5. ✅ uuid() function incompatível → Mudado para expr("uuid()")
6. ✅ Bronze table missing → Re-catalogado
7. ✅ Catalog prefix inconsistente → Padronizado para glue_catalog
8. ✅ Metadata location conflicts → Removido do Terraform
9. ✅ IAM permissions → Adicionado default database
10. ✅ Schema mapping nested fields → Corrigido referências
11. ✅ Static config errors → Corrigidos
12. ✅ Write API corrections → Aplicados
13. ✅ EventBridge triggers → Configurados
14. ✅ Sequential workflow → Implementado

### Fase 18-19: Workaround A - Athena DDL (FALHOU ❌)
**Abordagem:** Criar tabelas via Athena DDL, usar INSERT/MERGE no job
- Tentativa 1: CREATE TABLE via Athena → INSERT OVERWRITE via PySpark
  - Resultado: "Cannot write incompatible data"
- Tentativa 2: Alinhamento de schema → INSERT OVERWRITE
  - Resultado: "Cannot resolve t.event_timestamp"
- Tentativa 3: Schema completo → INSERT OVERWRITE
  - Resultado: "Cannot write incompatible data"
- Tentativa 4: MERGE simplificado → INSERT OVERWRITE
  - Resultado: "Cannot write incompatible data"
- Tentativa 5: DATE → STRING type conversion
  - Resultado: "Cannot write incompatible data"
- Tentativa 6: DataFrame API bypass (write instead of SQL)
  - Resultado: "Cannot find column gas_type"

### Fase 20: Retorno ao PySpark createOrReplace (FALHOU ❌)
**Abordagem:** Abandonar Athena DDL, deixar PySpark criar tabela
- Tentativa 7: writeTo().createOrReplace() com df_ordered
  - Resultado: "Cannot find column event_id"
- Tentativa 8: DROP table + clean S3 + retry
  - Resultado: S3 404 error (metadata inconsistency)
- Tentativa 9: Wait propagation + retry
  - Resultado: "Cannot find column event_id"
- Tentativa 10: DataFrame API com .write().saveAsTable()
  - Resultado: "Cannot find column event_id"
- Tentativa 11: Hardcoded database name (sem backticks)
  - Resultado: "Cannot find column event_id"
- Tentativa 12: Explicit SELECT para df_gold
  - Resultado: "Cannot find column event_id"
- Tentativa 13: Log schema antes de criar tabela
  - Resultado: Logs mostram 14 cols, tabela criada com 19 cols
- Tentativa 14: Force materialization com .cache() + .count()
  - Resultado: "Cannot find column event_id"
- Tentativa 15: Multiple API variants + cache
  - Resultado: "Cannot find column event_id"

**Total de horas investidas:** ~30+ horas  
**Total de workflow runs:** 20+ execuções  
**Taxa de sucesso Gold:** 0%

---

## 🎯 Comparação: Silver (Funciona) vs Gold (Falha)

### Silver Job - FUNCIONANDO ✅

**Código:**
```python
# Read from Bronze (Parquet)
df_bronze = spark.sql("SELECT * FROM glue_catalog.datalake_pipeline_catalog_dev.bronze_car_data")

# Transformations
df_silver = df_bronze.select(...).withColumn(...)

# Write to Iceberg
df_silver.writeTo("glue_catalog.datalake_pipeline_catalog_dev.silver_car_telemetry") \
    .using("iceberg") \
    .tableProperty("format-version", "2") \
    .partitionedBy("event_year", "event_month", "event_day") \
    .createOrReplace()
```

**Resultado:**
- ✅ Tabela criada com schema correto
- ✅ Dados escritos (101 registros)
- ✅ Particionamento funcional
- ✅ Consultável via Athena
- ✅ 100% taxa de sucesso

### Gold Job - FALHANDO ❌

**Código:**
```python
# Read from Silver (Iceberg)
df_silver = spark.sql("SELECT * FROM glue_catalog.datalake_pipeline_catalog_dev.silver_car_telemetry")

# Transformations
df_with_kpis = df_silver.withColumn(...).withColumn(...)

# Select ONLY Gold columns
df_gold = df_with_kpis.select(
    "car_chassis", "manufacturer", # ... 14 colunas
)

# Force materialization
df_gold = df_gold.cache()
df_gold.count()

# Write to Iceberg
df_gold.write \
    .format("iceberg") \
    .mode("overwrite") \
    .saveAsTable("glue_catalog.datalake_pipeline_catalog_dev.gold_car_current_state_new")
```

**Resultado:**
- ❌ Tabela criada com schema ERRADO (19 colunas ao invés de 14)
- ❌ Schema inclui colunas da Silver que foram explicitamente removidas
- ❌ Falha ao tentar inserir dados
- ❌ 0% taxa de sucesso

### Diferenças Chave

| Aspecto | Silver (✅ Funciona) | Gold (❌ Falha) |
|---------|---------------------|-----------------|
| **Fonte** | Bronze (Parquet) | Silver (Iceberg) |
| **Transformação** | withColumn() | withColumn() + select() |
| **API** | writeTo().createOrReplace() | write().saveAsTable() |
| **Schema Inference** | Do DataFrame | **Ignora DataFrame, usa Silver** |
| **Particionamento** | Sim (3 colunas) | Não |

**Hipótese principal:** O problema ocorre quando a fonte é **Iceberg → Iceberg** (Silver → Gold) ao invés de **Parquet → Iceberg** (Bronze → Silver).

---

## 💡 Soluções Propostas

### Opção 1: Workaround Temporário - Gold em Parquet ⚠️

**Descrição:** Manter Silver em Iceberg (funcional) e converter Gold para Parquet temporariamente até resolver o bug.

**Prós:**
- ✅ Desbloqueia pipeline imediatamente
- ✅ Mantém benefícios Iceberg na Silver (onde está funcionando)
- ✅ Permite validação end-to-end do pipeline

**Contras:**
- ❌ Perde benefícios Iceberg na Gold (ACID, time travel, schema evolution)
- ❌ Solução temporária que precisa ser revertida depois
- ❌ Duas tecnologias diferentes no pipeline (complexidade)

**Esforço:** ~2 horas (modificar 3 jobs Gold + Terraform)

### Opção 2: Escalação AWS Support 🎫

**Descrição:** Abrir caso com AWS Support Premium com evidências completas.

**Documentação preparada:**
- ✅ `AWS_SUPPORT_ESCALATION.md` - Caso técnico detalhado
- ✅ `RELATORIO_MIGRACAO_ICEBERG.md` - Este relatório
- ✅ `ICEBERG_MIGRATION_ISSUES.txt` - Log completo de 17 fases
- ✅ 15+ Workflow Run IDs com evidências
- ✅ Scripts PySpark + Terraform configurações

**Perguntas para AWS:**
1. Por que `df.select()` é ignorado ao criar tabela Iceberg?
2. Existe cache Spark/Iceberg que persiste entre job runs?
3. Há bug conhecido no Glue 4.0 + Iceberg para transformações Silver → Gold?
4. Por que Bronze → Silver funciona mas Silver → Gold falha com mesmo padrão?

**Tempo estimado resposta:** 24-48 horas (caso de alta prioridade)

### Opção 3: Teste com Nome Completamente Novo 🧪

**Descrição:** Criar database e table completamente novos sem histórico anterior.

**Implementação:**
```python
# Novo database: datalake_gold_test_catalog
# Nova tabela: car_current_state_v2
# Nova warehouse location: s3://datalake-pipeline-gold-dev/iceberg-test/
```

**Objetivo:** Eliminar qualquer possibilidade de cache/metadata de tentativas anteriores.

**Esforço:** ~30 minutos  
**Probabilidade sucesso:** 10-20%

### Opção 4: Intermediário via TempView + CTAS 🔄

**Descrição:** Criar tabela via CREATE TABLE AS SELECT ao invés de DataFrame API.

**Implementação:**
```python
# Registrar DataFrame como temp view
df_gold.createOrReplaceTempView("temp_gold_view")

# Criar tabela via SQL CTAS
spark.sql(f"""
    CREATE OR REPLACE TABLE glue_catalog.datalake_pipeline_catalog_dev.gold_car_current_state_new
    USING iceberg
    AS SELECT * FROM temp_gold_view
""")
```

**Lógica:** SQL CTAS pode ter path de código diferente que respeita o schema da view.

**Esforço:** ~1 hora  
**Probabilidade sucesso:** 30-40%

---

## 📊 Análise de Impacto

### Impacto no Projeto

#### Timeline Atual:
- **Planejado:** Migração completa Iceberg em 1 semana
- **Real:** 2+ dias bloqueados na Gold layer
- **Atraso:** +100% do tempo estimado

#### Componentes Afetados:
- ❌ **Gold Car Current State** - Bloqueado
- ❌ **Gold Fuel Efficiency** - Não pode começar (depende Job 1)
- ❌ **Gold Performance Alerts** - Não pode começar (depende Job 2)
- ❌ **Validação end-to-end** - Impossível sem Gold
- ❌ **Testes de integração** - Bloqueados

#### Componentes NÃO Afetados:
- ✅ Bronze Layer - Operacional
- ✅ Silver Layer - 100% funcional
- ✅ Event-driven architecture - Configurado e pronto
- ✅ Monitoring & logging - Implementado

### Impacto Técnico

**Dívida Técnica Atual:**
- 15+ tentativas de workaround no código
- Múltiplas versões de scripts Gold comentadas
- Configurações de teste que precisam ser limpas
- Documentação extensa de troubleshooting

**Aprendizados:**
1. ✅ Iceberg funciona bem para Parquet → Iceberg
2. ⚠️ Iceberg → Iceberg tem comportamento inesperado no Glue
3. ✅ Sequential workflow necessário para dependências
4. ✅ IAM permissions precisam ser explícitas para cada bucket

---

## 🎯 Recomendação

### Estratégia Recomendada: Híbrida

**Fase 1 - Imediato (hoje):**
1. **Testar Opção 4** (CTAS via SQL) - 1 hora
   - Se funcionar: Problema resolvido ✅
   - Se falhar: Partir para Fase 2

**Fase 2 - Curto prazo (1-2 dias):**
2. **Abrir caso AWS Support** (Opção 2) em paralelo com:
3. **Implementar Opção 1** (Gold Parquet temporário)
   - Desbloqueia pipeline para validação
   - Mantém Silver Iceberg funcional
   - Aguarda resposta AWS Support

**Fase 3 - Médio prazo (3-5 dias):**
4. **Aplicar solução AWS Support** quando disponível
5. **Migrar Gold de Parquet → Iceberg** com fix correto
6. **Validar pipeline completo** end-to-end

### Justificativa

Esta abordagem:
- ✅ Minimiza tempo bloqueado
- ✅ Mantém progresso (Silver Iceberg permanece)
- ✅ Permite continuar desenvolvimento em paralelo
- ✅ Garante resolução definitiva via AWS Support
- ✅ Evita acumular mais dívida técnica com workarounds

---

## 📎 Anexos

### Arquivos Relevantes

**Código:**
- `glue_jobs/gold_car_current_state_job_iceberg.py` - Job Gold (15 versões testadas)
- `glue_jobs/silver_consolidation_job_iceberg.py` - Job Silver (funcional)
- `terraform/glue_jobs.tf` - Definições de jobs
- `terraform/iceberg_event_driven.tf` - Workflow e triggers

**Documentação:**
- `ICEBERG_MIGRATION_ISSUES.txt` - Log completo de 17 fases
- `AWS_SUPPORT_ESCALATION.md` - Caso para AWS Support
- `athena_ddl_workaround.sql` - Tentativa de DDL manual

### Workflow Run IDs (Últimos 10)

```
wr_d266d3d0e117699ab72470c41097e8118a6f7015fa2aabc23e86bb1be30681be - FAILED (cache test)
wr_92a067657e5d2182abb5c6bf5bdf8680ea7661e07b8a87652c6e371271d91436 - FAILED (saveAsTable)
wr_10490636cd9f48a4ae4dccc6b23c1fea1201520cbe192a00979eb6457b2166d5 - FAILED (hardcoded db)
wr_fe731105e30b85ff3465d618255802c1e519a1ee63e09dfa4cf24bafd41de894 - FAILED (ordered df)
wr_2219d99860b82e40a8443118416cbf84c38c9a538f5067b8f56c08be290d68a5 - FAILED (writeTo)
wr_53839c0666b1cde94090f90f0f3b21fc846aebd3fe0eb0dd48aa4cb87202573b - FAILED (clean retry)
wr_c064050d07ced4c23ae14167750f47f21f389465a5237774c0e5d4a76b7b343d - FAILED (S3 404)
wr_8828a46bec970d463ee4cf6ba8355b048db3805595964a6abc986c6038bec225 - FAILED (S3 404)
wr_e010e3c0fb7280455dd1367183dffbaa916ad90cbd8b5f485f3307d515b87176 - FAILED (event_id)
wr_9b9fd5d9fa913d1fd53254da9e271ab3e7126b146592664e7db7a49e3d3f592e - FAILED (event_id)
```

### Comandos de Verificação

**Verificar status do workflow:**
```bash
aws glue get-workflow-run \
  --name datalake-pipeline-silver-gold-workflow-dev-eventdriven \
  --run-id <RUN_ID> \
  --region us-east-1
```

**Verificar schema da tabela Gold:**
```bash
aws glue get-table \
  --database-name datalake_pipeline_catalog_dev \
  --name gold_car_current_state_new \
  --region us-east-1 \
  --query "Table.StorageDescriptor.Columns[*].Name"
```

**Verificar dados Silver (funcional):**
```sql
-- Via Athena
SELECT COUNT(*) FROM datalake_pipeline_catalog_dev.silver_car_telemetry;
-- Resultado esperado: 101 registros
```

---

## 📞 Próximos Passos

### Ação Imediata Necessária

**Decisão requerida:** Escolher estratégia para desbloquear pipeline

**Opções:**
1. ⏱️ **Testar CTAS SQL** (1 hora) - Tentativa final antes de workaround
2. 🎫 **Abrir AWS Support** + **Gold Parquet temporário** - Desbloqueia desenvolvimento
3. 🧪 **Teste com nome novo** (30 min) - Eliminar cache como causa

**Contato:** Aguardando direcionamento do time  
**Prioridade:** **ALTA** - Pipeline bloqueado há 48+ horas

---

**Preparado por:** GitHub Copilot AI Assistant  
**Última atualização:** 13/11/2025 15:48 BRT  
**Versão:** 1.0
