# Infraestrutura AWS - Data Lakehouse para Dados de Veículos

**Projeto:** car-lakehouse  
**Ambiente:** Development (dev)  
**Última Atualização:** 2025-11-05  
**Região AWS:** us-east-1

---

## 📋 Índice

1. [Visão Geral](#visão-geral)
2. [Arquitetura de Camadas](#arquitetura-de-camadas)
3. [Componentes AWS](#componentes-aws)
4. [Fluxo de Dados](#fluxo-de-dados)
5. [Diagrama de Comunicação](#diagrama-de-comunicação)
6. [Tabelas do Glue Catalog](#tabelas-do-glue-catalog)

---

## 🎯 Visão Geral

O projeto implementa uma arquitetura Data Lakehouse em AWS seguindo o padrão Medallion Architecture (RAW → BRONZE → SILVER → GOLD), processando dados de telemetria e eventos de veículos de uma frota de aluguel.

### Tecnologias Principais
- **Armazenamento**: Amazon S3
- **Processamento**: AWS Glue (ETL Jobs + Crawlers)
- **Catálogo de Metadados**: AWS Glue Data Catalog
- **Ingestão**: AWS Lambda
- **Orquestração**: AWS Glue Workflows
- **Consultas**: Amazon Athena
- **IaC**: Terraform

---

## 🏗️ Arquitetura de Camadas

```
┌─────────────┐
│   RAW       │ ← JSON bruto de sistemas fonte
├─────────────┤
│   BRONZE    │ ← Parquet particionado (ingestão)
├─────────────┤
│   SILVER    │ ← Dados consolidados e flattened
├─────────────┤
│   GOLD      │ ← Agregações e KPIs de negócio
└─────────────┘
```

---

## 🔧 Componentes AWS

### 1. Amazon S3 Buckets

#### 1.1 RAW Layer
**Nome:** `datalake-pipeline-raw-dev`  
**Papel:** Armazenar dados JSON brutos de sistemas fonte  
**Estrutura:**
```
s3://datalake-pipeline-raw-dev/
└── raw/
    └── car_raw_data_*.json
```
**Comunicação:**
- ➡️ **Recebe de:** Sistemas externos (APIs, IoT devices)
- ➡️ **Lê por:** Lambda `datalake-pipeline-raw-to-bronze-dev`

---

#### 1.2 BRONZE Layer
**Nome:** `datalake-pipeline-bronze-dev`  
**Papel:** Armazenar dados convertidos para Parquet com particionamento Hive-style  
**Estrutura:**
```
s3://datalake-pipeline-bronze-dev/
└── bronze/
    └── car_data/
        └── ingest_year=YYYY/
            └── ingest_month=MM/
                └── ingest_day=DD/
                    └── car_data_*.parquet
```
**Comunicação:**
- ⬅️ **Recebe de:** Lambda `datalake-pipeline-raw-to-bronze-dev`
- ➡️ **Lê por:** Glue Job `datalake-pipeline-silver-consolidation-dev`
- ➡️ **Catalogado por:** Glue Crawler `datalake-pipeline-bronze-car-data-crawler-dev`

---

#### 1.3 SILVER Layer
**Nome:** `datalake-pipeline-silver-dev`  
**Papel:** Armazenar dados processados, flattened e consolidados  
**Estrutura:**
```
s3://datalake-pipeline-silver-dev/
└── car_telemetry/
    └── event_year=YYYY/
        └── event_month=MM/
            └── event_day=DD/
                └── *.parquet
```
**Comunicação:**
- ⬅️ **Recebe de:** Glue Job `datalake-pipeline-silver-consolidation-dev`
- ➡️ **Lê por:** 3 Glue Jobs Gold
- ➡️ **Catalogado por:** Glue Crawler `datalake-pipeline-silver-car-telemetry-crawler-dev`

---

#### 1.4 GOLD Layer
**Nome:** `datalake-pipeline-gold-dev`  
**Papel:** Armazenar agregações e KPIs de negócio  
**Estrutura:**
```
s3://datalake-pipeline-gold-dev/
├── car_current_state/          # Estado atual por veículo
├── fuel_efficiency_metrics/     # Métricas de eficiência
└── performance_alerts/          # Alertas de manutenção
```
**Comunicação:**
- ⬅️ **Recebe de:** 3 Glue Jobs Gold
- ➡️ **Lê por:** Amazon Athena, BI Tools
- ➡️ **Catalogado por:** 3 Glue Crawlers Gold

---

#### 1.5 Buckets Auxiliares

**Glue Scripts:** `datalake-pipeline-glue-scripts-dev`  
**Papel:** Armazenar scripts PySpark dos Glue Jobs  
**Conteúdo:**
- `glue_jobs/silver_consolidation_job.py`
- `glue_jobs/gold_car_current_state_job.py`
- `glue_jobs/gold_fuel_efficiency_job.py`
- `glue_jobs/gold_performance_alerts_job.py`

**Glue Temp:** `datalake-pipeline-glue-temp-dev`  
**Papel:** Armazenar dados temporários de processamento Spark/Glue  

---

### 2. AWS Lambda Functions

#### 2.1 Lambda: Ingestão RAW → BRONZE
**Nome:** `datalake-pipeline-raw-to-bronze-dev`  
**Runtime:** Python 3.11  
**Timeout:** 300s  
**Memória:** 512 MB  

**Papel:**
- Monitora bucket RAW via S3 Event Notification
- Converte JSON → Parquet com compressão Snappy
- Preserva estruturas nested (structs)
- Aplica particionamento Hive-style (ingest_year/month/day)
- Adiciona metadados (ingestion_timestamp, source_file, source_bucket)

**Trigger:**
- Event: `s3:ObjectCreated:*`
- Prefix: `raw/`
- Suffix: `.json`

**Comunicação:**
```
S3 RAW → [Lambda] → S3 BRONZE
```

**Dependências:**
- pandas
- pyarrow
- boto3

---

### 3. AWS Glue Data Catalog

#### 3.1 Database
**Nome:** `datalake-pipeline-catalog-dev`  
**Descrição:** Catálogo central de metadados para todas as camadas (Bronze, Silver, Gold)

**Tabelas Catalogadas:**
- `car_bronze` (Bronze Layer)
- `car_silver` (Silver Layer)
- `car_current_state` (Gold Layer)
- `fuel_efficiency_metrics` (Gold Layer)
- `performance_alerts` (Gold Layer)

---

### 4. AWS Glue Crawlers

#### 4.1 Crawler: Bronze Layer
**Nome:** `datalake-pipeline-bronze-car-data-crawler-dev`  
**Database:** `datalake-pipeline-catalog-dev`  
**Target:** `s3://datalake-pipeline-bronze-dev/bronze/car_data/`  

**Papel:**
- Descobre novas partições Parquet (ingest_year/month/day)
- **Atualiza** tabela `car_bronze` existente (não cria nova)
- Detecta mudanças de schema automaticamente

**Configuração:**
- **Behavior:** `UPDATE_IN_DATABASE` (atualiza tabela existente)
- **Recrawl Policy:** `CRAWL_EVERYTHING`
- **Table Prefix:** *(none)* - tabela pré-criada manualmente
- **Schedule:** Diário (midnight UTC) ou on-demand

**Comunicação:**
```
S3 BRONZE → [Crawler] → Glue Catalog (tabela car_bronze)
```

**Importante:**
- A tabela `car_bronze` deve ser criada manualmente antes da primeira execução
- Crawler não cria tabela nova, apenas atualiza metadados

---

#### 4.2 Crawler: Silver Layer
**Nome:** `datalake-pipeline-silver-car-telemetry-crawler-dev`  
**Database:** `datalake-pipeline-catalog-dev`  
**Target:** `s3://datalake-pipeline-silver-dev/car_telemetry/`  

**Papel:**
- Descobre novas partições (event_year/month/day)
- Atualiza tabela `car_silver`
- Mantém schema atualizado com colunas flattened

**Schedule:** Após execução do Job Silver (via Workflow)

---

#### 4.3 Crawlers: Gold Layer

**Crawler 1:** `datalake-pipeline-gold-car-current-state-crawler-dev`  
**Target:** `s3://datalake-pipeline-gold-dev/car_current_state/`  
**Tabela:** `car_current_state`

**Crawler 2:** `datalake-pipeline-gold-fuel-efficiency-crawler-dev`  
**Target:** `s3://datalake-pipeline-gold-dev/fuel_efficiency_metrics/`  
**Tabela:** `fuel_efficiency_metrics`

**Crawler 3:** `datalake-pipeline-gold-performance-alerts-crawler-dev`  
**Target:** `s3://datalake-pipeline-gold-dev/performance_alerts/`  
**Tabela:** `performance_alerts`

**Schedule:** Após execução dos respectivos Jobs Gold (via Workflow)

---

### 5. AWS Glue ETL Jobs

#### 5.1 Job: Silver Consolidation
**Nome:** `datalake-pipeline-silver-consolidation-dev`  
**Script:** `s3://datalake-pipeline-glue-scripts-dev/glue_jobs/silver_consolidation_job.py`  
**Glue Version:** 4.0  
**Worker Type:** G.1X  
**Workers:** 2  
**Timeout:** 60 min  

**Papel:**
- Lê dados da tabela `car_bronze` via Glue Catalog
- Aplica flattening de estruturas nested (structs)
- Calcula KPIs derivados:
  - `insurance_status` (ATIVO/VENCIDO)
  - `insurance_days_expired`
  - `fuel_efficiency_l_per_100km`
  - `average_speed_calculated_kmh`
- Particiona por `event_year`, `event_month`, `event_day`
- Escreve em `s3://datalake-pipeline-silver-dev/car_telemetry/`

**Parâmetros:**
```json
{
  "--bronze_database": "datalake-pipeline-catalog-dev",
  "--bronze_table": "car_bronze",
  "--silver_bucket": "datalake-pipeline-silver-dev",
  "--silver_path": "car_telemetry/",
  "--job-bookmark-option": "job-bookmark-enable"
}
```

**Comunicação:**
```
Glue Catalog (car_bronze) → [Job Silver] → S3 SILVER
                                   ↓
                         Glue Catalog (metadados)
```

**Job Bookmark:** Habilitado (processa apenas novas partições)

---

#### 5.2 Job: Gold - Car Current State
**Nome:** `datalake-pipeline-gold-car-current-state-dev`  
**Script:** `gold_car_current_state_job.py`  
**Workers:** 2

**Papel:**
- Lê tabela `car_silver`
- Consolida **último estado** de cada veículo (por `car_chassis`)
- Usa window function: `row_number() OVER (PARTITION BY car_chassis ORDER BY event_timestamp DESC)`
- Gera snapshot do estado atual da frota

**Saída:**
- Bucket: `s3://datalake-pipeline-gold-dev/car_current_state/`
- Formato: Parquet (compressão Snappy)
- Particionamento: Por data de processamento

**Comunicação:**
```
Glue Catalog (car_silver) → [Job Gold] → S3 GOLD/car_current_state/
```

---

#### 5.3 Job: Gold - Fuel Efficiency Metrics
**Nome:** `datalake-pipeline-gold-fuel-efficiency-dev`  
**Script:** `gold_fuel_efficiency_job.py`  
**Workers:** 2

**Papel:**
- Lê tabela `car_silver`
- Calcula métricas de eficiência por veículo:
  - Consumo médio (L/100km)
  - Total de km rodados
  - Total de combustível consumido
  - Eficiência por modelo/fabricante
- Agrupa por `car_chassis`, `manufacturer`, `model`

**Saída:**
- Bucket: `s3://datalake-pipeline-gold-dev/fuel_efficiency_metrics/`
- Formato: Parquet

**Comunicação:**
```
Glue Catalog (car_silver) → [Job Gold] → S3 GOLD/fuel_efficiency_metrics/
```

---

#### 5.4 Job: Gold - Performance Alerts
**Nome:** `datalake-pipeline-gold-performance-alerts-dev`  
**Script:** `gold_performance_alerts_job.py`  
**Workers:** 2

**Papel:**
- Lê tabela `car_silver`
- Identifica alertas de manutenção:
  - **CRITICAL:** oil_life_percentage < 20%
  - **LOW:** oil_life_percentage < 50%
  - Temperatura do motor alta
  - Pressão dos pneus fora do padrão
  - Seguro vencido
- Filtra apenas veículos com alertas ativos

**Saída:**
- Bucket: `s3://datalake-pipeline-gold-dev/performance_alerts/`
- Formato: Parquet
- Filtro: Somente registros com `alert_status != 'OK'`

**Comunicação:**
```
Glue Catalog (car_silver) → [Job Gold] → S3 GOLD/performance_alerts/
```

---

### 6. AWS Glue Workflows

#### 6.1 Workflow: Pipeline Completo
**Nome:** `datalake-pipeline-workflow-dev`  

**Papel:**
Orquestra a execução sequencial de todo o pipeline ETL

**Fluxo:**
```
START
  ↓
Crawler Bronze (car_bronze)
  ↓
Job Silver Consolidation
  ↓
Crawler Silver (car_silver)
  ↓
┌─────────────┬─────────────────────┬──────────────────────┐
│             │                     │                      │
Job Gold:     Job Gold:            Job Gold:
Current State Fuel Efficiency      Performance Alerts
│             │                     │
Crawler Gold  Crawler Gold         Crawler Gold
│             │                     │
└─────────────┴─────────────────────┴──────────────────────┘
  ↓
END
```

**Triggers:**
- Manual (on-demand)
- Scheduled (diário)
- Event-driven (após upload RAW → BRONZE)

---

### 7. AWS IAM Roles

#### 7.1 Lambda Execution Role
**Nome:** `datalake-pipeline-lambda-role-dev`  

**Permissões:**
- `s3:GetObject` (bucket RAW)
- `s3:PutObject` (bucket BRONZE)
- `s3:ListBucket`
- `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`

---

#### 7.2 Glue Job Role
**Nome:** `datalake-pipeline-glue-job-role-dev`  

**Permissões:**
- `s3:GetObject`, `s3:PutObject` (todos os buckets)
- `glue:GetDatabase`, `glue:GetTable`, `glue:GetPartitions`
- `glue:CreateTable`, `glue:UpdateTable`, `glue:BatchCreatePartition`
- `logs:*` (CloudWatch Logs)

---

#### 7.3 Glue Crawler Role
**Nome:** `datalake-pipeline-glue-crawler-role-dev`  

**Permissões:**
- `s3:GetObject`, `s3:ListBucket` (buckets Bronze, Silver, Gold)
- `glue:GetDatabase`, `glue:GetTable`
- `glue:CreateTable`, `glue:UpdateTable`, `glue:CreatePartition`

---

## 📊 Tabelas do Glue Catalog

### Tabela 1: car_bronze

**Database:** `datalake-pipeline-catalog-dev`  
**Location:** `s3://datalake-pipeline-bronze-dev/bronze/car_data/`  
**Format:** Parquet (Snappy)  
**Table Type:** EXTERNAL_TABLE

**Schema:**
```sql
CREATE EXTERNAL TABLE car_bronze (
  event_id STRING,
  event_primary_timestamp STRING,
  processing_timestamp STRING,
  carChassis STRING,
  
  -- Nested struct: Informações estáticas do veículo
  vehicle_static_info STRUCT<
    data: STRUCT<
      Manufacturer: STRING,
      Model: STRING,
      ModelYear: BIGINT,
      color: STRING,
      fuelCapacityLiters: BIGINT,
      gasType: STRING,
      year: BIGINT
    >,
    extraction_timestamp: STRING,
    source_system: STRING
  >,
  
  -- Nested struct: Estado dinâmico (seguro + manutenção)
  vehicle_dynamic_state STRUCT<
    insurance_info: STRUCT<
      data: STRUCT<
        policy_number: STRING,
        provider: STRING,
        validUntil: STRING
      >,
      extraction_timestamp: STRING,
      source_system: STRING
    >,
    maintenance_info: STRUCT<
      data: STRUCT<
        last_service_date: STRING,
        last_service_mileage: BIGINT,
        oil_life_percentage: DOUBLE
      >,
      extraction_timestamp: STRING,
      source_system: STRING
    >
  >,
  
  -- Nested struct: Contrato de aluguel
  current_rental_agreement STRUCT<
    data: STRUCT<
      agreement_id: STRING,
      customer_id: STRING,
      rental_start_date: STRING
    >,
    extraction_timestamp: STRING,
    source_system: STRING
  >,
  
  -- Nested struct: Dados de viagem + telemetria
  trip_data STRUCT<
    trip_summary: STRUCT<
      data: STRUCT<
        tripEndTimestamp: STRING,
        tripFuelLiters: DOUBLE,
        tripMaxSpeedKm: BIGINT,
        tripMileage: DOUBLE,
        tripStartTimestamp: STRING,
        tripTimeMinutes: BIGINT
      >,
      extraction_timestamp: STRING,
      source_system: STRING
    >,
    vehicle_telemetry_snapshot: STRUCT<
      data: STRUCT<
        batteryChargePerc: BIGINT,
        currentMileage: BIGINT,
        engineTempCelsius: BIGINT,
        fuelAvailableLiters: DOUBLE,
        oilTempCelsius: BIGINT,
        tire_pressures_psi: STRUCT<
          front_left: DOUBLE,
          front_right: DOUBLE,
          rear_left: DOUBLE,
          rear_right: DOUBLE
        >
      >,
      extraction_timestamp: STRING,
      source_system: STRING
    >
  >,
  
  -- Metadados de ingestão
  ingestion_timestamp STRING,
  source_file STRING,
  source_bucket STRING
)
PARTITIONED BY (
  ingest_year STRING,
  ingest_month STRING,
  ingest_day STRING
)
STORED AS PARQUET
LOCATION 's3://datalake-pipeline-bronze-dev/bronze/car_data/';
```

**Partições Atuais:**
- `ingest_year=2025/ingest_month=11/ingest_day=05/` (1 registro)

**Criação:**
- ✅ Tabela criada **manualmente** via script Python
- ✅ Crawler apenas atualiza metadados (não recria tabela)

---

### Tabela 2: car_silver

**Database:** `datalake-pipeline-catalog-dev`  
**Location:** `s3://datalake-pipeline-silver-dev/car_telemetry/`  
**Format:** Parquet (Snappy)  
**Table Type:** EXTERNAL_TABLE

**Schema (Flattened):**
```sql
CREATE EXTERNAL TABLE car_silver (
  -- Identificadores
  event_id STRING,
  event_timestamp TIMESTAMP,
  processing_timestamp STRING,
  car_chassis STRING,
  
  -- Informações estáticas (flattened)
  static_info_timestamp STRING,
  static_info_source STRING,
  model STRING,
  year BIGINT,
  model_year BIGINT,
  manufacturer STRING,
  fuel_type STRING,
  fuel_capacity_liters BIGINT,
  color STRING,
  
  -- Seguro (flattened)
  insurance_timestamp STRING,
  insurance_source STRING,
  insurance_provider STRING,
  insurance_policy_number STRING,
  insurance_valid_until STRING,
  insurance_status STRING,           -- KPI calculado: ATIVO/VENCIDO
  insurance_days_expired BIGINT,     -- KPI calculado
  
  -- Manutenção (flattened)
  maintenance_timestamp STRING,
  maintenance_source STRING,
  last_service_date STRING,
  last_service_mileage BIGINT,
  oil_life_percentage DOUBLE,
  
  -- Contrato de aluguel (flattened)
  rental_timestamp STRING,
  rental_source STRING,
  rental_agreement_id STRING,
  rental_customer_id STRING,
  rental_start_date STRING,
  
  -- Viagem (flattened)
  trip_summary_timestamp STRING,
  trip_summary_source STRING,
  trip_start_timestamp STRING,
  trip_end_timestamp STRING,
  trip_distance_km DOUBLE,
  trip_duration_minutes BIGINT,
  trip_fuel_consumed_liters DOUBLE,
  trip_max_speed_kmh BIGINT,
  
  -- KPIs calculados
  fuel_efficiency_l_per_100km DOUBLE,        -- trip_fuel / trip_distance * 100
  average_speed_calculated_kmh DOUBLE,       -- trip_distance / (trip_duration / 60)
  
  -- Telemetria (flattened)
  telemetry_timestamp STRING,
  telemetry_source STRING,
  current_mileage_km BIGINT,
  fuel_available_liters DOUBLE,
  engine_temp_celsius BIGINT,
  oil_temp_celsius BIGINT,
  battery_charge_percentage BIGINT,
  tire_pressure_front_left_psi DOUBLE,
  tire_pressure_front_right_psi DOUBLE,
  tire_pressure_rear_left_psi DOUBLE,
  tire_pressure_rear_right_psi DOUBLE
)
PARTITIONED BY (
  event_year STRING,
  event_month STRING,
  event_day STRING
)
STORED AS PARQUET
LOCATION 's3://datalake-pipeline-silver-dev/car_telemetry/';
```

**Características:**
- Estrutura completamente flattened (sem nested structs)
- KPIs de seguro e eficiência calculados
- Particionamento por data do evento (não ingestão)

---

### Tabelas 3-5: Gold Layer

#### car_current_state
**Papel:** Snapshot do estado atual de cada veículo (último registro por car_chassis)

**Colunas principais:**
- `car_chassis` (PK)
- `last_event_timestamp`
- `current_mileage_km`
- `fuel_available_liters`
- `insurance_status`
- `oil_life_percentage`
- `rental_agreement_id`

---

#### fuel_efficiency_metrics
**Papel:** Métricas agregadas de eficiência por veículo

**Colunas principais:**
- `car_chassis`
- `manufacturer`
- `model`
- `total_trips`
- `total_distance_km`
- `total_fuel_liters`
- `avg_fuel_efficiency_l_per_100km`

---

#### performance_alerts
**Papel:** Alertas de manutenção e performance

**Colunas principais:**
- `car_chassis`
- `alert_type` (OIL_CRITICAL, ENGINE_TEMP, TIRE_PRESSURE, INSURANCE_EXPIRED)
- `alert_status` (CRITICAL, LOW, OK)
- `alert_timestamp`
- `oil_life_percentage`
- `insurance_days_expired`

---

## 🔄 Fluxo de Dados Completo

### Fluxo End-to-End

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 1. INGESTÃO (RAW → BRONZE)                                              │
└─────────────────────────────────────────────────────────────────────────┘

Sistema Fonte → S3 RAW (JSON)
                   ↓ (S3 Event)
              Lambda Function
                   ↓ (Converte JSON → Parquet)
              S3 BRONZE (Parquet particionado)
                   ↓
         Glue Crawler Bronze
                   ↓
    Glue Catalog: Tabela car_bronze (atualizada)


┌─────────────────────────────────────────────────────────────────────────┐
│ 2. PROCESSAMENTO (BRONZE → SILVER)                                      │
└─────────────────────────────────────────────────────────────────────────┘

Glue Catalog: car_bronze
         ↓ (lê via from_catalog)
    Glue Job Silver
         ↓ (flattening + KPIs)
    S3 SILVER (Parquet particionado)
         ↓
   Glue Crawler Silver
         ↓
Glue Catalog: Tabela car_silver (atualizada)


┌─────────────────────────────────────────────────────────────────────────┐
│ 3. AGREGAÇÕES (SILVER → GOLD)                                           │
└─────────────────────────────────────────────────────────────────────────┘

                Glue Catalog: car_silver
                         ↓
        ┌────────────────┼────────────────┐
        ↓                ↓                ↓
   Job Gold 1       Job Gold 2       Job Gold 3
   (Current State)  (Fuel Eff.)      (Alerts)
        ↓                ↓                ↓
   S3 GOLD/         S3 GOLD/         S3 GOLD/
   current_state    fuel_eff         alerts
        ↓                ↓                ↓
   Crawler Gold 1   Crawler Gold 2   Crawler Gold 3
        ↓                ↓                ↓
   Tabela Gold 1    Tabela Gold 2    Tabela Gold 3


┌─────────────────────────────────────────────────────────────────────────┐
│ 4. CONSUMO (GOLD → Analytics)                                           │
└─────────────────────────────────────────────────────────────────────────┘

Glue Catalog: Tabelas Gold
         ↓
   Amazon Athena (queries SQL)
         ↓
   ┌─────┴─────┬─────────┬──────────┐
   ↓           ↓         ↓          ↓
QuickSight  Tableau  Python/R   APIs
```

---

## 📡 Diagrama de Comunicação entre Componentes

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        AWS ACCOUNT: 901207488135                         │
│                          REGION: us-east-1                               │
└──────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                         STORAGE LAYER (S3)                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  [RAW Bucket] ──────────────┐                                           │
│       │                     │                                           │
│       │ S3 Event            │                                           │
│       ↓                     │                                           │
│  [Lambda Function]          │                                           │
│       │                     │                                           │
│       │ Writes Parquet      │                                           │
│       ↓                     │                                           │
│  [BRONZE Bucket] ←──────────┘                                           │
│       │                                                                  │
│       │ Crawled by                                                      │
│       ↓                                                                  │
│  [SILVER Bucket] ←────── (Job Silver writes)                            │
│       │                                                                  │
│       │ Crawled by                                                      │
│       ↓                                                                  │
│  [GOLD Bucket] ←─────── (3 Jobs Gold write)                             │
│       │                                                                  │
│       ├─ car_current_state/                                             │
│       ├─ fuel_efficiency_metrics/                                       │
│       └─ performance_alerts/                                            │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                      METADATA LAYER (Glue Catalog)                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  [Database: datalake-pipeline-catalog-dev]                              │
│       │                                                                  │
│       ├─ car_bronze (updated by Crawler)                                │
│       │     ↑                                                            │
│       │     │ read by Job Silver                                        │
│       │                                                                  │
│       ├─ car_silver (updated by Crawler)                                │
│       │     ↑                                                            │
│       │     │ read by 3 Jobs Gold                                       │
│       │                                                                  │
│       ├─ car_current_state (updated by Crawler)                         │
│       ├─ fuel_efficiency_metrics (updated by Crawler)                   │
│       └─ performance_alerts (updated by Crawler)                        │
│             ↑                                                            │
│             │ queried by Athena/BI Tools                                │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                    PROCESSING LAYER (Glue ETL)                           │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  [Glue Workflow]                                                         │
│       │                                                                  │
│       ├─ Step 1: Crawler Bronze                                         │
│       │            ↓                                                     │
│       ├─ Step 2: Job Silver                                             │
│       │            ↓                                                     │
│       ├─ Step 3: Crawler Silver                                         │
│       │            ↓                                                     │
│       ├─ Step 4: Jobs Gold (parallel)                                   │
│       │            ├─ Job Gold 1 (Current State)                        │
│       │            ├─ Job Gold 2 (Fuel Efficiency)                      │
│       │            └─ Job Gold 3 (Performance Alerts)                   │
│       │            ↓                                                     │
│       └─ Step 5: Crawlers Gold (parallel)                               │
│                    ├─ Crawler Gold 1                                    │
│                    ├─ Crawler Gold 2                                    │
│                    └─ Crawler Gold 3                                    │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                       SECURITY LAYER (IAM)                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  [Lambda Role]                                                           │
│    → Permissions: S3 (RAW read, BRONZE write)                           │
│                                                                          │
│  [Glue Job Role]                                                         │
│    → Permissions: S3 (all buckets), Glue Catalog (read/write)           │
│                                                                          │
│  [Glue Crawler Role]                                                     │
│    → Permissions: S3 (read), Glue Catalog (read/write tables)           │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 📈 Métricas e Monitoramento

### CloudWatch Metrics

**Lambda Function:**
- Invocations
- Duration
- Errors
- Concurrent Executions

**Glue Jobs:**
- Job Run Status
- Data Processed (MB)
- Execution Time
- DPU Hours

**Glue Crawlers:**
- Crawler Run Status
- Tables Created/Updated
- Partitions Added

### CloudWatch Logs

**Log Groups:**
- `/aws/lambda/datalake-pipeline-raw-to-bronze-dev`
- `/aws-glue/jobs/datalake-pipeline-silver-consolidation-dev`
- `/aws-glue/jobs/datalake-pipeline-gold-*-dev`
- `/aws-glue/crawlers/datalake-pipeline-*-crawler-dev`

---

## 🔐 Segurança

### Encryption

**S3 Buckets:**
- Server-side encryption: AES-256 (SSE-S3)
- Bucket policies: Block public access

**Glue Data Catalog:**
- Encryption at rest
- IAM-based access control

### Network

**VPC Configuration:**
- Glue Jobs executam em VPC AWS Managed
- Lambda functions: Public subnet (acesso S3 via Gateway Endpoint)

---

## 📝 Convenções de Nomenclatura

### Padrão de Nomes

```
{project_name}-{component}-{resource_type}-{environment}
```

**Exemplo:**
- `datalake-pipeline-silver-consolidation-dev`
- `datalake-pipeline-bronze-car-data-crawler-dev`

### Particionamento

**Bronze:** `ingest_year=YYYY/ingest_month=MM/ingest_day=DD/`  
**Silver:** `event_year=YYYY/event_month=MM/event_day=DD/`  
**Gold:** Varia por tabela (alguns não particionados)

---

## 🔧 Ferramentas de Gerenciamento

### Infrastructure as Code
**Ferramenta:** Terraform  
**Módulos:**
- `terraform/s3.tf` - Buckets
- `terraform/lambda.tf` - Lambda functions
- `terraform/glue.tf` - Crawlers
- `terraform/glue_jobs.tf` - ETL Jobs
- `terraform/glue_workflow.tf` - Workflows
- `terraform/iam.tf` - Roles e Policies

### Scripts Python
- `scripts/create_car_bronze_table.py` - Criação manual da tabela Bronze
- `glue_jobs/*.py` - Jobs ETL PySpark

---

## 📊 Resumo de Recursos

| Componente | Quantidade | Nomes |
|------------|------------|-------|
| **S3 Buckets** | 6 | RAW, BRONZE, SILVER, GOLD, Scripts, Temp |
| **Lambda Functions** | 1 | raw-to-bronze-dev |
| **Glue Databases** | 1 | datalake-pipeline-catalog-dev |
| **Glue Tables** | 5 | car_bronze, car_silver, 3 Gold tables |
| **Glue Crawlers** | 5 | 1 Bronze, 1 Silver, 3 Gold |
| **Glue Jobs** | 4 | 1 Silver, 3 Gold |
| **Glue Workflows** | 1 | datalake-pipeline-workflow-dev |
| **IAM Roles** | 3 | Lambda, Glue Job, Glue Crawler |

---

## 🚀 Status Atual do Pipeline

### Componentes Deployados

| Componente | Status | Última Atualização |
|------------|--------|-------------------|
| S3 Buckets | ✅ Ativo | 2025-11-05 |
| Lambda raw-to-bronze | ✅ Ativo | 2025-11-05 |
| Tabela car_bronze | ✅ Criada | 2025-11-05 |
| Crawler Bronze | ✅ Configurado | 2025-11-05 |
| Job Silver | ✅ Atualizado | 2025-11-05 |
| Glue Catalog | ✅ Ativo | 2025-11-05 |

### Dados Atuais

- **RAW:** 1 arquivo JSON (car_raw_data_001.json)
- **BRONZE:** 1 arquivo Parquet (29 KB, 1 registro)
- **SILVER:** Aguardando execução do Job
- **GOLD:** Aguardando execução dos Jobs

---

## 📞 Contatos e Referências

**Projeto:** car-lakehouse  
**Repositório:** https://github.com/petersonvm/car-lakehouse  
**Branch Atual:** gold  
**AWS Account:** 901207488135  
**Região:** us-east-1  

---

**Documento gerado em:** 2025-11-05  
**Versão:** 1.0  
**Autor:** Sistema de Data Lakehouse
