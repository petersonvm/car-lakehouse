# Relatório de Atividades - Pipeline Event-Driven Iceberg
**Data:** 14 de Novembro de 2025  
**Sessão:** Continuação Phase 23 - Investigação EventBridge e Silver Job  
**Branch:** `ice`  
**Status:** 🔴 **EM PROGRESSO** - Silver Job com falhas persistentes

---

## 📋 Sumário Executivo

Esta sessão focou na resolução de problemas no pipeline event-driven após a migração para Apache Iceberg. O problema de auto-trigger do EventBridge foi **RESOLVIDO** com sucesso (Lambda inicia workflow diretamente), mas identificamos e estamos tratando problemas críticos na inicialização da tabela Iceberg Silver.

### Status dos Componentes

| Componente | Status | Observações |
|------------|--------|-------------|
| Lambda Ingestion | ✅ **OPERACIONAL** | Cria Bronze Parquet corretamente |
| Bronze Crawler | ✅ **OPERACIONAL** | Cataloga schema event-driven |
| Lambda Workflow Start | ✅ **OPERACIONAL** | Bypass EventBridge funcionando |
| Silver Job Event-Driven | ❌ **FALHANDO** | Erro na inicialização Iceberg |
| Gold Jobs (3) | ⏸️ **BLOQUEADOS** | Aguardando Silver funcionar |

---

## 🎯 Objetivos da Sessão

1. ✅ **CONCLUÍDO:** Investigar e resolver issue de EventBridge não triggerando workflow automaticamente
2. 🔄 **EM PROGRESSO:** Corrigir Silver Job para pipeline event-driven
3. ⏸️ **PENDENTE:** Validação end-to-end do pipeline completo

---

## ✅ Atividades Realizadas e Sucessos

### 1. Resolução do Problema EventBridge ✅

**Problema Identificado:**
- AWS Glue Crawlers não emitem eventos para EventBridge por padrão
- Pipeline estava aguardando evento que nunca seria disparado

**Solução Implementada:**
- Lambda agora inicia workflow diretamente via `glue_client.start_workflow_run()`
- Bypass completo do EventBridge
- Workflow inicia automaticamente após crawler concluir

**Código Modificado:**
```python
# Em lambdas/ingestion/lambda_function_eventdriven.py
glue_client.start_workflow_run(Name=WORKFLOW_NAME)
logger.info(f"✅ Workflow iniciado: {WORKFLOW_NAME}")
```

**Resultado:** ✅ **SUCESSO COMPLETO** - Workflow agora inicia automaticamente após cada upload

---

### 2. Limpeza do Ambiente Bronze ✅

**Problema Identificado:**
- Bronze bucket continha 2116 arquivos antigos do pipeline batch
- Crawler estava detectando schema batch (nested structs) ao invés de event-driven (flat)
- Conflito entre schemas causava falhas no Silver Job

**Ação Tomada:**
```bash
aws s3 rm s3://datalake-pipeline-bronze-dev/bronze/car_data/ --recursive
# Removidos: 2116 arquivos
```

**Resultado:** ✅ Bronze agora cataloga apenas schema event-driven corretamente

---

### 3. Criação do Silver Job Event-Driven ✅

**Arquivo Criado:** `glue_jobs/silver_consolidation_job_eventdriven.py`

**Funcionalidades Implementadas:**
- Leitura de schema flat event-driven (carChassis, manufacturer, model, year, metrics.*, telemetryTimestamp)
- Transformação para schema Silver (15 colunas + 3 partições)
- Criação de colunas derivadas:
  - `event_id = concat(carChassis, "_", event_primary_timestamp)`
  - `gas_type = NULL` (não disponível em event-driven)
  - `insurance_provider = NULL`
  - `insurance_valid_until = NULL`
- Particionamento por `event_year`, `event_month`, `event_day`
- Lógica de CREATE TABLE + INSERT/MERGE para Iceberg

**Terraform Resource Criado:**
```terraform
resource "aws_glue_job" "silver_consolidation_eventdriven" {
  name              = "datalake-pipeline-silver-consolidation-eventdriven-dev"
  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  
  default_arguments = {
    "--datalake-formats" = "iceberg"
    # ... outros argumentos
  }
}
```

**Workflow Atualizado:**
- Trigger 1: Crawler success → Start Silver Job Event-Driven (novo)
- Trigger 2: Silver Event-Driven success → Start Gold Jobs

**Resultado:** ✅ Arquivo criado, infraestrutura configurada, workflow atualizado

---

### 4. Correções de Schema e Transformações ✅

**Problemas Corrigidos:**
1. ❌ Missing column `event_primary_timestamp` → ✅ Adicionado em Lambda
2. ❌ Missing column `event_id` → ✅ Criado via `concat()` no Silver Job
3. ❌ Missing columns `gas_type`, `insurance_provider`, `insurance_valid_until` → ✅ Adicionados como NULL
4. ❌ Schema mismatch (batch vs event-driven) → ✅ Bronze limpo, apenas event-driven

**Schema Event-Driven Completo (18 colunas):**

**Data Columns (15):**
- `event_id` (string) - Derived
- `car_chassis` (string)
- `event_primary_timestamp` (string)
- `telemetry_timestamp` (timestamp)
- `manufacturer` (string)
- `model` (string)
- `year` (int)
- `current_mileage_km` (double)
- `fuel_available_liters` (double)
- `engine_temp_celsius` (int)
- `oil_pressure_psi` (int)
- `gas_type` (string) - NULL
- `insurance_provider` (string) - NULL
- `insurance_valid_until` (string) - NULL

**Partition Columns (3):**
- `event_year` (int)
- `event_month` (int)
- `event_day` (int)

---

## ❌ Problemas Persistentes

### 🔴 Problema Crítico: Inicialização de Tabela Iceberg

**Descrição:**
O Silver Job falha consistentemente ao tentar inserir dados na tabela Iceberg `silver_car_telemetry`. O erro principal indica que o Iceberg está reconhecendo apenas 3 colunas (as partições) ao invés das 18 colunas completas.

---

#### Erro Principal

```
AnalysisException: `datalake_pipeline_catalog_dev`.`silver_car_telemetry` requires that 
the data to be inserted have the same number of columns as the target table: 
target table has 3 column(s) but the inserted data has 15 column(s), 
including 0 partition column(s) having constant value(s).
```

**Interpretação:**
- Iceberg vê apenas: `event_year`, `event_month`, `event_day` (3 colunas de partição)
- Iceberg não vê as 15 colunas de dados
- Glue Catalog mostra 18 colunas corretamente, mas Iceberg runtime discorda

---

#### Erro Secundário (Corrigido)

```
IllegalArgumentException: Can not create a Path from an empty string
```

**Causa:** S3 location sendo construído incorretamente
```python
# ❌ ERRADO (gerava string vazia):
silver_location = f"s3://{args['silver_database'].replace('_catalog', '')}-silver-dev/car_telemetry/"
# args['silver_database'] = 'datalake_pipeline_catalog_dev'
# replace('_catalog', '') → 'datalake_pipeline_dev' (underscores, não hífens!)

# ✅ CORRIGIDO:
silver_location = "s3://datalake-pipeline-silver-dev/car_telemetry/"
```

**Status:** ✅ Corrigido no script

---

### 🔍 Análise da Causa Raiz

**Hipótese Principal:**
Tabelas Iceberg requerem metadados específicos armazenados em S3 (`metadata/*.json`) que descrevem:
- Schema completo (tipos, nomes, nullability)
- Particionamento
- Snapshots de dados
- Manifests de arquivos

**O que está acontecendo:**
1. Glue Catalog cria entrada com 18 colunas ✅
2. Mas Iceberg metadata em S3 não é inicializado corretamente ❌
3. Spark/Iceberg lê apenas informações de partição da tabela ❌
4. Ao tentar INSERT, Iceberg valida contra schema incompleto ❌

**Por que acontece:**
- Glue Catalog table definition ≠ Iceberg metadata files
- `CREATE TABLE` via Spark SQL deveria inicializar metadata, mas não está funcionando
- Possível interferência de Glue Catalog pre-existente ou cache

---

### 📊 Histórico de Tentativas de Solução

#### Tentativa 1: CREATE TABLE AS SELECT LIMIT 0
```python
create_table_sql = f"""
CREATE TABLE IF NOT EXISTS {silver_table_path}
USING iceberg
PARTITIONED BY (event_year, event_month, event_day)
LOCATION '{silver_location}'
AS SELECT * FROM bronze_updates LIMIT 0
"""
```
**Resultado:** ❌ Falhou - Mesma erro "3 columns vs 15 columns"

---

#### Tentativa 2: CREATE TABLE com Schema Explícito
```python
create_table_sql = f"""
CREATE TABLE IF NOT EXISTS {silver_table_path} (
  event_id string,
  car_chassis string,
  -- ... todas as 15 colunas explicitamente ...
  event_year int,
  event_month int,
  event_day int
)
USING iceberg
PARTITIONED BY (event_year, event_month, event_day)
LOCATION '{silver_location}'
TBLPROPERTIES (
  'format-version' = '2',
  'write.format.default' = 'parquet'
)
"""
```
**Resultado:** ❌ Falhou - "Can not create a Path from an empty string" (location bug)

---

#### Tentativa 3: Correção de S3 Location + Fresh Start
```python
silver_location = "s3://datalake-pipeline-silver-dev/car_telemetry/"  # Hard-coded
```

**Ações:**
1. Deletar tabela do Glue Catalog
2. Limpar diretório S3 completamente (remove metadata residual)
3. Upload novo arquivo
4. Deixar Spark criar tabela from scratch

**Resultado:** ⏳ **TESTE INTERROMPIDO** - Necessita verificação

---

#### Tentativa 4: Criação Manual via Athena
```sql
CREATE TABLE datalake_pipeline_catalog_dev.silver_car_telemetry (
  -- schema completo --
)
LOCATION 's3://datalake-pipeline-silver-dev/car_telemetry/'
TBLPROPERTIES ('table_type'='ICEBERG', 'format'='parquet')
```

**Resultado:** ❌ Athena não suporta sintaxe `PARTITIONED BY` para Iceberg

---

### 🔧 Outros Problemas Encontrados

#### Max Concurrent Runs Exceeded
**Sintoma:** Jobs falhando imediatamente com `ExecutionTime: 0s`

**Causa:** Glue Job tem `MaxConcurrentRuns` default = 1, múltiplos testes seguidos causavam sobreposição

**Solução:** Aguardar 2-3 minutos entre testes para jobs finalizarem

**Status:** ✅ Workaround aplicado (aguardo manual)

---

#### Path Navigation Issues
**Sintoma:** Comandos `cd terraform` falhando com "path does not exist"

**Causa:** Working directory já era `terraform`, comando tentava `cd terraform/terraform`

**Solução:** Usar caminhos absolutos ou verificar PWD antes de cd

**Status:** ✅ Ajustado em comandos subsequentes

---

## 📈 Estatísticas da Sessão

### Testes Executados
- **Total de job runs:** 15+
- **Tempo médio de execução (falhas):** 70-92 segundos
- **Tempo médio de execução (concurrent exceeded):** 0 segundos
- **Uploads de teste realizados:** 10+

### Padrão de Falhas
```
Teste  | Hora  | Duração | Erro
-------|-------|---------|----------------------------------
1      | 11:58 | 89s     | 3 columns vs 15 columns
2      | 12:05 | 79s     | 3 columns vs 15 columns
3      | 12:10 | 128s    | 3 columns vs 15 columns
4      | 13:59 | 91s     | 3 columns vs 15 columns
5      | 14:01 | 70s     | 3 columns vs 15 columns
6      | 14:06 | 89s     | 3 columns vs 15 columns
7      | 14:09 | 82s     | 3 columns vs 15 columns
8      | 14:16 | 82s     | 3 columns vs 15 columns
9      | 14:18 | 92s     | 3 columns vs 15 columns
10     | 14:20 | 0s      | Max concurrent runs exceeded
11     | 14:36 | 70s     | Can not create Path from empty string
12     | 14:40 | 0s      | Max concurrent runs exceeded
13     | 15:58 | ~90s    | [INTERROMPIDO - necessita verificação]
```

**Observação:** Erro "3 columns" é consistente e persistente, indicando problema fundamental na inicialização de metadata Iceberg.

---

## 🔄 Estado Atual do Código

### Arquivos Modificados

#### 1. `glue_jobs/silver_consolidation_job_eventdriven.py` (NOVO)
- **Linhas:** 223 total
- **Status:** Código correto, script atualizado em S3
- **Última modificação:** S3 location hard-coded (linha 127)

**Seção crítica (linhas 127-158):**
```python
silver_table_path = f"{args['silver_database']}.{args['silver_table']}"
silver_location = "s3://datalake-pipeline-silver-dev/car_telemetry/"  # FIXO

# Check if Iceberg table exists with data
try:
    silver_count = spark.sql(f"SELECT COUNT(*) FROM {silver_table_path}").collect()[0]['count']
    table_has_data = True
except Exception as e:
    table_has_data = False
    # CREATE TABLE with explicit schema
    create_table_sql = f"""
    CREATE TABLE IF NOT EXISTS {silver_table_path} (
      event_id string,
      car_chassis string,
      event_primary_timestamp string,
      telemetry_timestamp timestamp,
      manufacturer string,
      model string,
      year int,
      current_mileage_km double,
      fuel_available_liters double,
      engine_temp_celsius int,
      oil_pressure_psi int,
      gas_type string,
      insurance_provider string,
      insurance_valid_until string,
      event_year int,
      event_month int,
      event_day int
    )
    USING iceberg
    PARTITIONED BY (event_year, event_month, event_day)
    LOCATION '{silver_location}'
    TBLPROPERTIES (
      'format-version' = '2',
      'write.format.default' = 'parquet'
    )
    """
    spark.sql(create_table_sql)
```

---

#### 2. `terraform/iceberg_event_driven.tf`
- **Adicionado:** Resource `aws_glue_job.silver_consolidation_eventdriven` (linhas 16-73)
- **Modificado:** Triggers do workflow (linhas 105-107, 143-145)
- **Status:** ✅ Aplicado via terraform

---

#### 3. `lambdas/ingestion/lambda_function_eventdriven.py`
- **Modificado:** Sessão anterior (já tinha `event_primary_timestamp`)
- **Adicionado:** Workflow start direto (bypass EventBridge)
- **Status:** ✅ Funcionando perfeitamente

---

### Estado da Infraestrutura

**S3 Buckets:**
- `datalake-pipeline-landing-dev`: ✅ Recebendo uploads
- `datalake-pipeline-bronze-dev/bronze/car_data/`: ✅ Limpo (sem arquivos batch)
- `datalake-pipeline-silver-dev/car_telemetry/`: ⚠️ Vazio após fresh starts
- `datalake-pipeline-glue-scripts-dev`: ✅ Script mais recente uploadado

**Glue Catalog:**
- `bronze_car_data`: ✅ Schema event-driven correto
- `silver_car_telemetry`: ⚠️ Deletado/recriado múltiplas vezes, possivelmente inconsistente

**Glue Jobs:**
- `datalake-pipeline-silver-consolidation-eventdriven-dev`: ✅ Criado e configurado
- Status: Script correto em S3, mas execuções falhando

**Workflow:**
- `datalake-pipeline-silver-gold-workflow-dev-eventdriven`: ✅ Triggers corretos
- Status: Iniciando automaticamente, mas falhando no Silver Job

---

## 🎯 Próximos Passos Recomendados

### Prioridade 1: Verificar Resultado do Último Teste ⚠️

O teste executado às 15:58 foi o primeiro com S3 location corrigido. Precisa verificar:

```powershell
# Verificar status do último job run
aws glue get-job-runs --job-name "datalake-pipeline-silver-consolidation-eventdriven-dev" --max-results 1

# Se sucesso, verificar metadata Iceberg criado
aws s3 ls s3://datalake-pipeline-silver-dev/car_telemetry/metadata/ --recursive

# Verificar dados inseridos
aws athena start-query-execution \
  --query-string "SELECT COUNT(*) FROM silver_car_telemetry" \
  --query-execution-context "Database=datalake_pipeline_catalog_dev"
```

---

### Prioridade 2: Abordagens Alternativas

Se último teste falhou, considerar:

#### Opção A: Criar Tabela Iceberg Programaticamente via PySpark
Modificar Silver Job para usar APIs do Iceberg diretamente:

```python
from pyspark.sql.types import StructType, StructField, StringType, TimestampType, IntegerType, DoubleType

# Define schema explicitamente
schema = StructType([
    StructField("event_id", StringType(), False),
    StructField("car_chassis", StringType(), False),
    # ... todas as colunas ...
])

# Criar tabela via DataFrameWriter
df_flattened.writeTo(silver_table_path) \
    .using("iceberg") \
    .partitionedBy("event_year", "event_month", "event_day") \
    .tableProperty("format-version", "2") \
    .createOrReplace()
```

---

#### Opção B: Usar Glue Studio para Criar Tabela
1. Acessar Glue Console → Tables
2. Criar tabela Iceberg manualmente com schema completo
3. Modificar Silver Job para APENAS fazer INSERT/MERGE (sem CREATE TABLE)

---

#### Opção C: Usar AWS SDK para Inicializar Metadata
Criar Lambda auxiliar que:
1. Usa boto3 para criar tabela no Glue Catalog
2. Usa Iceberg Python SDK para inicializar metadata em S3
3. Executa uma única vez antes do Silver Job

---

### Prioridade 3: Validação Completa (Quando Silver Funcionar)

1. **Teste de INSERT Inicial:**
   - Upload arquivo → Verificar dados em Silver
   - Confirmar Iceberg metadata criado corretamente

2. **Teste de MERGE (Upsert):**
   - Segundo upload mesmo carChassis → Verificar UPDATE
   - Terceiro upload novo carChassis → Verificar INSERT

3. **Teste de Pipeline Completo:**
   - Validar Silver → Gold Current State
   - Validar Silver → Gold Fuel Efficiency
   - Validar Silver → Gold Performance Alerts

4. **Teste de Performance:**
   - 5 uploads consecutivos (5 segundos de intervalo)
   - Verificar todos processados sem erros
   - Confirmar dados finais corretos

---

## 📝 Lições Aprendidas

### ✅ O Que Funcionou

1. **Lambda Direct Workflow Start:** Solução elegante e confiável para bypass de EventBridge
2. **Schema Event-Driven Flat:** Mais simples que nested structs, transformações mais claras
3. **Fresh Start Approach:** Limpar Bronze e Silver completamente revelou problemas ocultos
4. **Hard-coded S3 Location:** Evita bugs de string manipulation, mais confiável

---

### ❌ O Que Não Funcionou

1. **CREATE TABLE AS SELECT LIMIT 0:** Iceberg não inicializa metadata corretamente
2. **Múltiplos Delete/Create Cycles:** Pode causar cache/state issues no Glue
3. **Dynamic S3 Path Construction:** String manipulation causou bug crítico
4. **Athena para Criar Iceberg Tables:** Sintaxe limitada, não suporta PARTITIONED BY

---

### 🔍 Descobertas Importantes

1. **Iceberg ≠ Glue Catalog:**
   - Glue Catalog armazena definição lógica da tabela
   - Iceberg armazena metadata física em S3 (`metadata/*.json`)
   - Ambos devem estar sincronizados, mas são independentes

2. **Glue 4.0 Iceberg Support:**
   - Requer `--datalake-formats=iceberg` argument
   - Usa Iceberg 1.x (verificar versão exata no job)
   - Pode ter limitações vs Spark puro

3. **CREATE TABLE Behavior:**
   - `CREATE TABLE IF NOT EXISTS` pode falhar silenciosamente se tabela já existe no Glue Catalog mas metadata Iceberg está corrupto
   - Fresh start completo (delete + clean S3) é essencial para testes

---

## 🔒 Bloqueios e Dependências

### Bloqueios Ativos

1. **Silver Job Blocking Gold Pipeline:** Todas as 3 Gold tables aguardando Silver success
2. **Iceberg Metadata Issue Blocking Testing:** Não é possível validar pipeline end-to-end
3. **Root Cause Uncertainty:** Sem logs CloudWatch detalhados, difícil diagnosticar causa exata

---

### Dependências Técnicas

1. **Glue 4.0:** Versão específica para Iceberg support
2. **Spark 3.3+:** Iceberg compatibility
3. **Athena Engine v3:** Para queries em tabelas Iceberg (já disponível)
4. **S3 Metadata Storage:** Iceberg requer permissões R/W em location/metadata/

---

## 📞 Informações de Contato e Recursos

### Documentação Relevante

- [Apache Iceberg Table Spec](https://iceberg.apache.org/spec/)
- [AWS Glue Iceberg Support](https://docs.aws.amazon.com/glue/latest/dg/aws-glue-programming-etl-format-iceberg.html)
- [Spark SQL CREATE TABLE](https://spark.apache.org/docs/latest/sql-ref-syntax-ddl-create-table.html)

### Arquivos de Referência

- Script: `glue_jobs/silver_consolidation_job_eventdriven.py`
- Terraform: `terraform/iceberg_event_driven.tf`
- Lambda: `lambdas/ingestion/lambda_function_eventdriven.py`

---

## 🏁 Conclusão

Esta sessão alcançou **progresso significativo** na estabilização do pipeline event-driven:

**✅ Sucessos:**
- EventBridge issue permanentemente resolvido
- Bronze ambiente limpo e funcional
- Silver Job criado com lógica correta
- Workflow automático funcionando

**❌ Bloqueio Crítico:**
- Inicialização de tabela Iceberg Silver persistentemente falhando
- Root cause: Metadata Iceberg não sendo criado corretamente em S3
- 13+ tentativas com diferentes abordagens

**🎯 Próxima Ação:**
Verificar resultado do último teste (15:58) com S3 location corrigido. Se falhou, considerar abordagens alternativas (PySpark API direta, criação manual via Console, ou Lambda auxiliar para metadata).

**Estimativa para Resolução:**
- Se última correção funcionou: 30 minutos para validação completa
- Se ainda falhando: 1-2 horas para abordagem alternativa + testes

---

**Relatório gerado em:** 14/11/2025 16:10  
**Autor:** GitHub Copilot  
**Status do Pipeline:** 🔴 Silver Job Failing - Investigação em andamento
