# 🚗 Car Lakehouse - Data Pipeline

**Vehicle telemetry data pipeline** implemented on AWS using Medallion architecture (Landing → Bronze → Silver → Gold) with orchestration via AWS Glue Workflow.

**Status**: ✅ **PRODUCTION** - 100% functional and validated pipeline  
**Environment**: Development (dev)  
**Last Update**: November 6, 2025

---

## 📋 Overview

### Medallion Architecture

This project implements a complete Data Lakehouse for vehicle telemetry processing, following the Medallion architecture:

- **🛬 Landing Zone**: Receives raw data (JSON/CSV) from APIs, IoT devices, or manual upload
- **🥉 Bronze Layer**: Stores data copied from Landing in original format (minimal validation)
- **🥈 Silver Layer**: Clean, standardized data (snake_case), deduplicated and partitioned (Parquet)
- **🥇 Gold Layer**: Business aggregations ready for consumption (dashboards, BI, APIs)

### Main Components

| Component | Quantity | Description |
|-----------|----------|-------------|
| **S3 Buckets** | 8 | Landing, Bronze, Silver, Gold, Scripts, Temp, Athena, Layers |
| **Lambda Functions** | 1 active | Ingestion (Landing → Bronze) with automatic S3 trigger |
| **Glue Jobs** | 4 active | 1 Silver + 3 Gold (car state, fuel efficiency, alerts) |
| **Glue Crawlers** | 6 active | Bronze, Silver, 3 Gold + schema discovery |
| **Glue Workflow** | 1 | Silver→Gold orchestration (scheduled daily 02:00 UTC) |
| **Catalog Tables** | 5 | 1 Bronze + 1 Silver + 3 Gold |
| **IAM Roles** | 4 | Lambda, Glue Jobs Silver, Gold, Crawlers |

---

## 🏗️ Complete Architecture

### End-to-End Data Flow

```mermaid
graph TB
    A[APIs/IoT/Manual] -->|PUT *.json,*.csv| B[S3 Landing Zone]
    B -->|S3 Event| C[Lambda Ingestion]
    C -->|COPY| D[S3 Bronze Layer]
    D -->|READ| E[Glue Job Silver]
    E -->|Flatten JSON<br/>Deduplicate<br/>Partition| F[S3 Silver Layer]
    F -->|CRAWL| G[Crawler Silver]
    G -->|UPDATE| H[Glue Catalog]
    H -->|TRIGGER Fan-Out| I{3 Jobs Gold}
    I -->|Parallel| J[Job Gold 1:<br/>Car Current State]
    I -->|Parallel| K[Job Gold 2:<br/>Fuel Efficiency]
    I -->|Parallel| L[Job Gold 3:<br/>Performance Alerts]
    J --> M[S3 Gold Layer]
    K --> M
    L --> M
    M --> N[Crawlers Gold]
    N --> H
    H --> O[Athena/BI Tools]
```

### Data Layers

#### 📂 Landing Zone
```
s3://datalake-pipeline-landing-dev/
├── *.json (raw telemetry data)
└── *.csv (batch uploads)

Status: TRANSIENT (files removed after ingestion)
Trigger: Lambda Ingestion (automatic via S3 Event)
```

#### 📂 Bronze Layer
```
s3://datalake-pipeline-bronze-dev/
└── bronze/
    └── car_data/
        └── *.json (raw, 1:1 copy from Landing)

Table: car_bronze
Format: JSON (original)
Size: ~29 KB
```

#### 📂 Silver Layer
```
s3://datalake-pipeline-silver-dev/
└── car_telemetry/
    └── event_year=2025/
        └── event_month=11/
            └── event_day=05/
                └── *.parquet (snappy compressed)

Table: silver_car_telemetry
Format: Parquet (56 columns snake_case)
Partitioning: event_year, event_month, event_day
Size: ~13 KB
```

#### 📂 Gold Layer
```
s3://datalake-pipeline-gold-dev/
├── gold_car_current_state_new/
│   └── *.parquet (1 row per vehicle, latest state)
├── fuel_efficiency_monthly/
│   └── *.parquet (aggregated by car+month)
└── gold_performance_alerts_slim/
    └── *.parquet (alert logs)

Tables: gold_car_current_state_new, fuel_efficiency_monthly, performance_alerts_log_slim
Format: Parquet
Total Size: ~19 KB
```

---

## 📦 Component Inventory

### 1. 🗄️ Glue Data Catalog

#### Database
| Name | Catalog ID | Description |
|------|------------|-------------|
| `datalake-pipeline-catalog-dev` | 901207488135 | Main Lakehouse database |

#### Tables (5 active tables)

##### Bronze
- **`bronze_car_data`**: Raw data (JSON) copied from Landing
  - Location: `s3://datalake-pipeline-bronze-dev/bronze/car_data/`
  - Updated by: `datalake-pipeline-bronze-car-data-crawler-dev`

##### Silver
- **`silver_car_telemetry`**: Clean and structured data (56 columns)
  - Location: `s3://datalake-pipeline-silver-dev/car_telemetry/`
  - Format: Partitioned Parquet (event_year/month/day)
  - Updated by: `datalake-pipeline-silver-crawler-dev`

##### Gold
- **`gold_car_current_state_new`**: Current state of each vehicle (12 columns)
  - Join of telemetry + static data + insurance status
- **`fuel_efficiency_monthly`**: Fuel efficiency metrics (7 columns)
  - Monthly aggregation by vehicle (km/liter, distance, consumption)
- **`performance_alerts_log_slim`**: Performance alert log
  - Anomalies based on thresholds (temperature, pressure, battery)

### 2. 🚀 Glue Jobs

#### Job Silver
**`datalake-pipeline-silver-consolidation-dev`**
- **Função**: Bronze → Silver (limpeza e estruturação)
- **Script**: `glue_jobs/silver_consolidation_job.py`
- **Workers**: 2 × G.1X (Glue 4.0)
- **Transformações**:
  - Flatten nested JSON (metrics.trip.* → trip_*)
  - Convert camelCase → snake_case (56 campos)
  - Deduplicate por event_id (Window function)
  - Particionar por data (year/month/day)
  - Adicionar processing_timestamp
- **Duração média**: 78s
- **Status**: ✅ ATIVO (parte do workflow)

#### Jobs Gold (3 paralelos)

**1. `datalake-pipeline-gold-car-current-state-dev`**
- **Função**: Latest state of each vehicle
- **Transformações**:
  - Window: last_value over partition by car_chassis
  - Join telemetry + static info
  - Calcular status de seguro (válido/expirado)
- **Duração média**: 91s

**2. `datalake-pipeline-gold-fuel-efficiency-dev`**
- **Função**: Monthly fuel efficiency
- **Transformações**:
  - Extrair year/month de event_date
  - GroupBy car_chassis + year + month
  - Calcular: avg_fuel_efficiency (km/litro)
  - Somar: trip_distance_km, trip_fuel_consumed_liters
- **Duração média**: 93s

**3. `datalake-pipeline-gold-performance-alerts-slim-dev`**
- **Função**: Performance alerts
- **Transformações**:
  - Check thresholds (temp, pressão, bateria)
  - Flag anomalias
  - Gerar alert records
- **Duração média**: 106s

### 3. 🔍 Glue Crawlers (6 ativos)

| Crawler | Layer | S3 Path | Created Table |
|---------|--------|---------|---------------|
| `datalake-pipeline-bronze-car-data-crawler-dev` | Bronze | `bronze/car_data/` | `bronze_car_data` |
| `datalake-pipeline-silver-crawler-dev` | Silver | `car_telemetry/` | `silver_car_telemetry` |
| `gold_car_current_state_crawler` | Gold | `gold_car_current_state_new/` | `gold_car_current_state_new` |
| `datalake-pipeline-gold-fuel-efficiency-crawler-dev` | Gold | `fuel_efficiency_monthly/` | `fuel_efficiency_monthly` |
| `datalake-pipeline-gold-performance-alerts-slim-crawler-dev` | Gold | `gold_performance_alerts_slim/` | `performance_alerts_log_slim` |
| `gold_alerts_slim_crawler` | Gold | `performance_alerts_log_slim/` | `performance_alerts_log_slim` |

### 4. 🪣 Buckets S3 (8 buckets)

| Bucket | Layer | Purpose | Tamanho |
|--------|--------|-----------|---------|
| `datalake-pipeline-landing-dev` | Landing | Receives uploads (JSON/CSV) | 0 bytes (transient) |
| `datalake-pipeline-bronze-dev` | Bronze | Raw data (1:1 copy) | ~29 KB |
| `datalake-pipeline-silver-dev` | Silver | Cleaned & partitioned | ~13 KB |
| `datalake-pipeline-gold-dev` | Gold | Business aggregations | ~19 KB |
| `datalake-pipeline-glue-scripts-dev` | Operacional | Job scripts (Python) | ~100 KB |
| `datalake-pipeline-glue-temp-dev` | Operacional | Temp files | Temporary |
| `datalake-pipeline-athena-results-dev` | Analytics | Query results | ~50 KB |
| `datalake-pipeline-lambda-layers-dev` | Operacional | Lambda layers | ~20 MB |

### 5. 🔄 Workflow Glue

**`datalake-pipeline-silver-gold-workflow-dev`**
- **Scheduled Start**: Diário às 02:00 UTC (cron: `0 2 * * ? *`)
- **Duração média**: ~12 minutos
- **Actions**: 8 (1 job silver + 1 crawler silver + 3 jobs gold + 3 crawlers gold)
- **Status**: ✅ 100% success rate (última execução)

**Triggers (6 total):**
1. **Scheduled Start** → Silver Job
2. **Silver Job SUCCEEDED** → Silver Crawler
3. **Silver Crawler SUCCEEDED** → Fan-Out (3 Gold Jobs in parallel)
4. **Gold Job 1 SUCCEEDED** → Gold Crawler 1
5. **Gold Job 2 SUCCEEDED** → Gold Crawler 2
6. **Gold Job 3 SUCCEEDED** → Gold Crawler 3

### 6. 🔌 Lambda Functions

**`datalake-pipeline-ingestion-dev`** (ATIVA)
- **Runtime**: Python 3.9 (512 MB, 120s timeout)
- **Trigger**: S3 Event (Landing bucket)
  - Eventos: `s3:ObjectCreated:*` (*.json, *.csv)
- **Função**: Copiar Landing → Bronze + cleanup Landing
- **Role**: `datalake-pipeline-lambda-execution-role-dev`
- **Status**: ✅ ATIVA (últimas execuções: 5 invocations)

> **Nota**: Pipeline completamente migrado para AWS Glue. Processamento Bronze→Silver→Gold é feito por Glue Jobs.

### 7. 🔐 IAM Roles (4 roles)

| Role | Used By | Main Permissions |
|------|-----------|------------------------|
| `datalake-pipeline-lambda-execution-role-dev` | Lambda Ingestion | S3 (Landing read, Bronze write), CloudWatch Logs |
| `datalake-pipeline-glue-job-role-dev` | Job Silver | S3 (Bronze read, Silver write), Glue Catalog, CloudWatch |
| `datalake-pipeline-gold-job-role-dev` | Jobs Gold (3) | S3 (Silver read, Gold write/delete), Glue Catalog |
| `datalake-pipeline-glue-crawler-role-dev` | Crawlers (6) | S3 read (all layers), Glue Catalog write |

---

## 🔗 Communication Matrix

| Origem | Ação | Destino | Data Transferred |
|--------|------|---------|-------------------|
| APIs/IoT/Manual | S3 PUT | Landing Bucket | JSON/CSV raw files |
| Landing Bucket | S3 Event | Lambda Ingestion | ObjectCreated trigger |
| Lambda Ingestion | S3 COPY | Bronze Bucket | JSON raw (1:1 copy) |
| Lambda Ingestion | S3 DELETE | Landing Bucket | Cleanup após sucesso |
| Bronze Bucket | Glue READ | Job Silver | bronze_car_data table |
| Job Silver | S3 WRITE | Silver Bucket | Parquet particionado |
| Silver Bucket | Glue CRAWL | Crawler Silver | car_telemetry/ folders |
| Crawler Silver | Catalog UPDATE | Glue Catalog | silver_car_telemetry + partitions |
| Glue Catalog | Glue READ | Jobs Gold (3×) | silver_car_telemetry (56 cols) |
| Jobs Gold | S3 WRITE | Gold Bucket | gold_* tables (Parquet) |
| Gold Bucket | Glue CRAWL | Crawlers Gold (3×) | gold_*/ folders |
| Crawlers Gold | Catalog UPDATE | Glue Catalog | gold_* tables |
| Glue Catalog | Athena QUERY | Athena | SQL results → Results Bucket |
| Workflow | TRIGGER | Job Silver | Scheduled (cron) |
| Workflow | TRIGGER | Crawler Silver | Conditional (Job SUCCEEDED) |
| Workflow | TRIGGER | Jobs Gold (3×) | Conditional (Crawler SUCCEEDED) |

---

## 📊 Detailed Data Flow

### Stage 1: Ingestion (Landing → Bronze)

```
┌────────────────────────┐
│  External Sources      │
│  • REST APIs           │
│  • IoT Devices         │
│  • Manual Upload       │
└───────────┬────────────┘
            │ PUT *.json, *.csv
            ▼
┌────────────────────────┐
│  S3 Landing Zone       │
│  Status: TRANSIENT     │
└───────────┬────────────┘
            │ S3 ObjectCreated Event
            ▼
┌─────────────────────────────────┐
│  Lambda Ingestion               │
│  • Validate file extension      │
│  • COPY Landing → Bronze         │
│  • DELETE from Landing          │
│  Duration: ~1-5s per file       │
└───────────┬─────────────────────┘
            │ S3 COPY
            ▼
┌────────────────────────┐
│  S3 Bronze Layer       │
│  bronze/car_data/*.json│
│  Status: PERMANENT     │
└────────────────────────┘
```

### Stage 2: Consolidation (Bronze → Silver)

```
┌────────────────────────┐
│  S3 Bronze Layer       │
│  Table: bronze_car_data│
└───────────┬────────────┘
            │ Glue READ (via Catalog)
            ▼
┌──────────────────────────────────────┐
│  Glue Job: Silver Consolidation      │
│  • Flatten JSON (nested → flat)      │
│  • Rename: camelCase → snake_case    │
│  • Deduplicate (Window + row_number) │
│  • Add processing_timestamp          │
│  • Partition by event_date           │
│  • Convert to Parquet (Snappy)       │
│  Duration: ~78s                      │
└───────────┬──────────────────────────┘
            │ S3 WRITE (Parquet)
            ▼
┌────────────────────────────────┐
│  S3 Silver Layer               │
│  car_telemetry/                │
│    event_year=YYYY/            │
│      event_month=MM/           │
│        event_day=DD/           │
│          *.parquet             │
└───────────┬────────────────────┘
            │ Glue CRAWL
            ▼
┌────────────────────────────────┐
│  Glue Catalog                  │
│  Table: silver_car_telemetry   │
│  Schema: 56 cols (snake_case)  │
│  Partitions: registered        │
└────────────────────────────────┘
```

### Stage 3: Aggregations (Silver → Gold)

```
┌────────────────────────────────┐
│  Glue Catalog                  │
│  silver_car_telemetry          │
└───────────┬────────────────────┘
            │ Workflow TRIGGER (Fan-Out)
            ▼
     ┌──────┴──────┬──────────────┐
     ▼             ▼              ▼
┌─────────┐  ┌──────────┐  ┌─────────────┐
│ Gold    │  │ Gold     │  │ Gold        │
│ Job 1   │  │ Job 2    │  │ Job 3       │
│ Current │  │ Fuel     │  │ Alerts      │
│ State   │  │ Effic.   │  │ Slim        │
└────┬────┘  └────┬─────┘  └──────┬──────┘
     │            │                │
     │ WRITE      │ WRITE          │ WRITE
     ▼            ▼                ▼
┌────────────────────────────────────┐
│  S3 Gold Layer                     │
│  ├── gold_car_current_state_new/   │
│  ├── fuel_efficiency_monthly/      │
│  └── performance_alerts_slim/      │
└───────────┬────────────────────────┘
            │ Glue CRAWL (3× parallel)
            ▼
┌────────────────────────────────────┐
│  Glue Catalog (Gold Tables)        │
│  • gold_car_current_state_new      │
│  • fuel_efficiency_monthly         │
│  • performance_alerts_log_slim     │
└───────────┬────────────────────────┘
            │ Athena QUERY
            ▼
┌────────────────────────────────────┐
│  Analytics & BI                    │
│  • Athena SQL Queries              │
│  • PowerBI / QuickSight            │
│  • API Endpoints                   │
└────────────────────────────────────┘
```

---

## 📁 Project Structure

```
.
├── terraform/                           # Infrastructure as Code
│   ├── provider.tf                      # Configuração AWS Provider
│   ├── variables.tf                     # Variable definitions
│   ├── s3.tf                            # Buckets S3 (8 buckets)
│   ├── lambda.tf                        # Lambda Ingestion + Layer
│   ├── iam.tf                           # Roles e Policies IAM (4 roles)
│   ├── glue.tf                          # Crawler Bronze, Database Catalog
│   ├── glue_silver.tf                   # Job Silver + Crawler Silver
│   ├── glue_gold_car_current_state.tf   # Job Gold 1 + Crawler
│   ├── glue_gold_fuel_efficiency.tf     # Job Gold 2 + Crawler
│   ├── glue_gold_alerts_slim.tf         # Job Gold 3 + Crawler
│   ├── glue_workflow.tf                 # Workflow + 6 Triggers
│   └── outputs.tf                       # Outputs Terraform
├── glue_jobs/                           # Scripts Python dos Glue Jobs
│   ├── silver_consolidation_job.py      # Bronze → Silver (56 cols)
│   ├── gold_car_current_state_job.py    # Silver → Gold 1 (12 cols)
│   ├── gold_fuel_efficiency_job.py      # Silver → Gold 2 (7 cols)
│   └── gold_performance_alerts_slim_job.py  # Silver → Gold 3 (alerts)
├── lambdas/                             # Lambda code
│   └── ingestion/
│       ├── lambda_function.py           # Lambda Ingestion (ativa)
│       └── README.md                    # Documentação técnica
├── docs/                                # Project documentation
│   └── reports/                         # Organized reports
│       ├── END_TO_END_TEST_REPORT.md
│       ├── EXECUTIVE_SUMMARY.md
│       ├── GOLD_LAYER_VALIDATION_REPORT.md
│       ├── INVENTARIO_AWS.md
│       ├── INVENTARIO_COMPONENTES_ATUALIZADO.md
│       ├── INVENTARIO_INFRAESTRUTURA.md
│       ├── RECOVERY_README.md
│       ├── REFACTORING_SUMMARY.md
│       ├── Relatorio_Componentes_Lakehouse.md
│       └── WORKFLOW_RECOVERY_GUIDE.md
├── scripts/                             # Utility scripts
├── test_data/                           # Test data
├── Data_Model/                          # Data models
│   └── car_raw.json                     # Schema exemplo
├── assets/                              # Auxiliary files
├── build_lambda.ps1                     # Build Lambda (Windows)
├── build_lambda.sh                      # Build Lambda (Linux/Mac)
├── build_layer_docker.ps1               # Build Layer com Docker
├── terraform.tfvars                     # Variáveis Terraform (privado)
├── .gitignore                           # Git ignore rules
├── QUICK_REFERENCE.md                   # Quick reference
└── README.md                            # This file
```

---

## 🚀 How to Use

### Prerequisites

1. **Terraform** >= 1.0
   ```bash
   terraform version
   ```

2. **AWS CLI** configured
   ```bash
   aws configure
   ```

3. **AWS Credentials** with permissions to create:
   - S3 Buckets, Lambda Functions, Glue (Jobs, Crawlers, Workflow)
   - IAM Roles e Policies, CloudWatch Log Groups

### Installation and Deployment

#### 1. Clone the repository
```bash
git clone https://github.com/petersonvm/car-lakehouse.git
cd car-lakehouse
```

#### 2. Build da Lambda Ingestion (REQUIRED before Terraform)

**Windows (PowerShell):**
```powershell
.\build_lambda.ps1
```

**Linux/Mac:**
```bash
chmod +x build_lambda.sh
./build_lambda.sh
```

This will create:
- `assets/ingestion_package.zip` (Lambda code)
- `assets/pandas_pyarrow_layer.zip` (Lambda Layer)

#### 3. Configure variables

Navigate to Terraform directory:
```bash
cd terraform
```

Copy the example file (if exists) or edit directly `terraform.tfvars`:
```hcl
aws_region   = "us-east-1"
project_name = "datalake-pipeline"
environment  = "dev"

common_tags = {
  Project     = "Car-Lakehouse"
  ManagedBy   = "Terraform"
  Environment = "dev"
}
```

#### 4. Initialize and apply Terraform

```bash
# Initialize backend and providers
terraform init

# Validate configuration
terraform validate

# View execution plan
terraform plan

# Aplicar (criar recursos)
terraform apply
```

Type `yes` when prompted.

#### 5. Verify outputs

```bash
terraform output
```

You will see information about:
- Created S3 Buckets (8)
- Lambda Ingestion ARN
- Glue Database and tables
- Workflow ARN

---

## 🧪 Test the Pipeline

### 1. Upload JSON file to Landing Zone

```bash
# Upload test data
aws s3 cp test_data/sample_car_data.json s3://datalake-pipeline-landing-dev/

# Check Lambda Ingestion logs
aws logs tail /aws/lambda/datalake-pipeline-ingestion-dev --follow
```

The Lambda will be invoked automatically and copy the file to Bronze.

### 2. Verify file in Bronze

```bash
aws s3 ls s3://datalake-pipeline-bronze-dev/bronze/car_data/ --recursive
```

### 3. Manually run Silver Job (optional - or wait for scheduled trigger)

```bash
aws glue start-job-run --job-name datalake-pipeline-silver-consolidation-dev
```

### 4. Run complete Workflow

```bash
# Run workflow manually
aws glue start-workflow-run --name datalake-pipeline-silver-gold-workflow-dev

# Check status
aws glue get-workflow-run --name datalake-pipeline-silver-gold-workflow-dev --run-id <RUN_ID>
```

The workflow will execute:
1. Job Silver (78s)
2. Crawler Silver (update partitions)
3. 3 Jobs Gold in parallel (91s, 93s, 106s)
4. 3 Crawlers Gold (update tables)

**Total duration**: ~12 minutos

### 5. Query data with Athena

```sql
-- Check Silver table
SELECT * FROM "datalake-pipeline-catalog-dev"."silver_car_telemetry"
LIMIT 10;

-- Check current vehicle state
SELECT * FROM "datalake-pipeline-catalog-dev"."gold_car_current_state_new";

-- Check fuel efficiency
SELECT 
    car_chassis,
    year,
    month,
    avg_fuel_efficiency_km_per_liter,
    total_distance_km
FROM "datalake-pipeline-catalog-dev"."fuel_efficiency_monthly"
ORDER BY year DESC, month DESC;

-- Check performance alerts
SELECT * FROM "datalake-pipeline-catalog-dev"."performance_alerts_log_slim"
WHERE alert_type = 'HIGH_TEMPERATURE'
LIMIT 100;
```

---

## 📊 Data Schema

### Silver Layer: `silver_car_telemetry` (56 colunas)

```python
# Vehicle Identification
car_chassis: string
manufacturer: string
model: string
manufacturing_year: bigint
purchase_date: string

# Owner Data
owner_name: string
owner_cpf: string
owner_email: string
owner_phone: string

# Insurance
insurance_company: string
insurance_policy_number: string
insurance_valid_until: string

# General Telemetry
telemetry_timestamp: timestamp
current_mileage_km: bigint
location_latitude: double
location_longitude: double
location_city: string
location_state: string

# Viagem (Trip)
trip_distance_km: double
trip_duration_minutes: bigint
trip_average_speed_km_h: double
trip_fuel_consumed_liters: double

# Engine (Engine)
engine_temperature_c: bigint
engine_rpm: bigint
engine_load_percent: bigint
engine_coolant_temp_c: bigint

# Battery
battery_voltage_v: double
battery_charge_percent: bigint

# Tires (Tires)
tire_pressure_front_left_psi: bigint
tire_pressure_front_right_psi: bigint
tire_pressure_rear_left_psi: bigint
tire_pressure_rear_right_psi: bigint

# Sensors
odometer_reading_km: bigint
fuel_level_percent: bigint
ambient_temperature_c: bigint

# Events and Alerts
event_id: string (PK)
event_date: string
event_year: bigint (partition)
event_month: bigint (partition)
event_day: bigint (partition)

# Metadata
processing_timestamp: timestamp
```

### Gold Layer 1: `gold_car_current_state_new` (12 colunas)

```python
car_chassis: string
manufacturer: string
model: string
manufacturing_year: bigint
owner_name: string
current_mileage_km: bigint
fuel_level_percent: bigint
battery_voltage_v: double
insurance_company: string
insurance_valid_until: string
insurance_status: string  # "VALID" or "EXPIRED"
last_telemetry_timestamp: timestamp
```

### Gold Layer 2: `fuel_efficiency_monthly` (7 colunas)

```python
car_chassis: string
year: bigint
month: bigint
total_distance_km: double
total_fuel_consumed_liters: double
number_of_trips: bigint
avg_fuel_efficiency_km_per_liter: double
```

---

## 🔐 Security

- **✅ Encryption**: All S3 buckets use AES256
- **✅ Public Access**: Blocked by default on all buckets
- **✅ Versioning**: Enabled on main buckets
- **✅ IAM**: Least privilege principle (least privilege)
- **✅ CloudWatch Logs**: Enabled for all executions
- **✅ Job Bookmarks**: Enabled on Silver Job (avoids reprocessing)

---

## 📈 Monitoring and Observability

### CloudWatch Log Groups

```bash
# Lambda Ingestion
/aws/lambda/datalake-pipeline-ingestion-dev

# Glue Jobs
/aws/glue/jobs/datalake-pipeline-silver-consolidation-dev
/aws/glue/jobs/datalake-pipeline-gold-car-current-state-dev
/aws/glue/jobs/datalake-pipeline-gold-fuel-efficiency-dev
/aws/glue/jobs/datalake-pipeline-gold-performance-alerts-slim-dev

# Crawlers
/aws/glue/crawlers
```

### Main Metrics

| Métrica | Namespace | Descrição |
|---------|-----------|-----------|
| `Duration` | Lambda | Lambda Ingestion execution time |
| `Errors` | Lambda | Lambda Ingestion errors |
| `glue.driver.aggregate.numCompletedStages` | Glue | Completed stages in Jobs |
| `glue.driver.aggregate.numFailedTasks` | Glue | Failed tasks in Jobs |

### Query Recent Executions

```bash
# Workflow runs
aws glue get-workflow-runs --name datalake-pipeline-silver-gold-workflow-dev --max-results 5

# Job runs (Silver)
aws glue get-job-runs --job-name datalake-pipeline-silver-consolidation-dev --max-results 5

# Crawler runs
aws glue get-crawler-metrics --crawler-name-list datalake-pipeline-silver-crawler-dev
```

---

## 💰 Cost Estimate (Development)

| Service | Monthly Usage | Estimated Cost |
|---------|------------|----------------|
| **S3 Storage** | ~200 KB | < $0.01 |
| **Lambda Invocations** | ~100 invocations | < $0.01 |
| **Glue Jobs** | 30 runs × 4 jobs × 2 min | ~$1.20 |
| **Glue Crawlers** | 30 runs × 6 crawlers | ~$0.50 |
| **Athena Queries** | ~1 TB scanned | ~$5.00 |
| **CloudWatch Logs** | 1 GB | ~$0.50 |
| **Estimated Total** | | **~$7.21/mês** |

> **Nota**: Actual costs vary according to data volume and execution frequency.

---

## 🧹 Infrastructure Optimization

### Legacy Resources Cleanup

The current pipeline contains ~10 legacy resources (orphans from previous refactoring) that can be removed for cost optimization:

**Identified Resources:**
- 3 unused Lambdas (cleansing, analysis, compliance)
- 2 duplicated Crawlers (gold_alerts_slim, gold_fuel_efficiency)
- 1 orphan IAM Role + 3 associated policies

**Estimated Savings:** ~$0.50/mês + reduction in 7% in Terraform complexity

**How to Execute Cleanup:**

```bash
# 1. Review detailed plan
cat docs/TERRAFORM_CLEANUP_PLAN.md

# 2. Simulate cleanup (DRY RUN - no changes)
.\scripts\cleanup_legacy_resources.ps1 -DryRun

# 3. Execute REAL cleanup (with automatic backup)
.\scripts\cleanup_legacy_resources.ps1

# 4. Validate pipeline after cleanup
aws glue start-workflow-run --name datalake-pipeline-silver-gold-workflow-dev
```

**Complete Documentation:**
- **[docs/TERRAFORM_CLEANUP_PLAN.md](./docs/TERRAFORM_CLEANUP_PLAN.md)**: Detailed cleanup plan
- **[scripts/cleanup_legacy_resources.ps1](./scripts/cleanup_legacy_resources.ps1)**: Automated script

> **✅ Insurance**: Script includes automatic Terraform state backup and DRY RUN mode for simulation.

---

## 🗑️ Destroy Resources (Remove Everything)

To remove **ALL** created resources:

```bash
cd terraform
terraform destroy
```

⚠️ **WARNING**: 
- Backup S3 data before destroying!
- Buckets with versioning require manual removal of all versions

---

## 📚 Additional Documentation

For more detailed information, see:

- **[QUICK_REFERENCE.md](./QUICK_REFERENCE.md)**: Quick commands and references
- **[docs/TERRAFORM_CLEANUP_PLAN.md](./docs/TERRAFORM_CLEANUP_PLAN.md)**: 🧹 Plano de limpeza de legacy resources
- **[docs/reports/INVENTARIO_COMPONENTES_ATUALIZADO.md](./docs/reports/INVENTARIO_COMPONENTES_ATUALIZADO.md)**: Detailed complete inventory
- **[docs/reports/END_TO_END_TEST_REPORT.md](./docs/reports/END_TO_END_TEST_REPORT.md)**: End-to-end test report
- **[docs/reports/WORKFLOW_RECOVERY_GUIDE.md](./docs/reports/WORKFLOW_RECOVERY_GUIDE.md)**: Workflow recovery guide
- **[test_data/README.md](./test_data/README.md)**: 🧪 Test data guide

---

## 🛠️ Troubleshooting

### Lambda Ingestion not invoked

1. Check if S3 Event Notifications are configured:
   ```bash
   aws s3api get-bucket-notification-configuration --bucket datalake-pipeline-landing-dev
   ```

2. Check Lambda permissions:
   ```bash
   aws lambda get-policy --function-name datalake-pipeline-ingestion-dev
   ```

### Job Silver fails

1. Check if Bronze table exists:
   ```bash
   aws glue get-table --database-name datalake-pipeline-catalog-dev --name bronze_car_data
   ```

2. Check Job logs:
   ```bash
   aws logs tail /aws/glue/jobs/datalake-pipeline-silver-consolidation-dev --follow
   ```

### Workflow doesn't start

1. Check if trigger is enabled:
   ```bash
   aws glue get-triggers --query "Triggers[?WorkflowName=='datalake-pipeline-silver-gold-workflow-dev']"
   ```

2. Start manually:
   ```bash
   aws glue start-workflow-run --name datalake-pipeline-silver-gold-workflow-dev
   ```

---

## 🤝 Contributing

Contributions are welcome! Please:
1. Fork the project
2. Create a branch for your feature (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

## 📄 License

This project is provided as an educational example to demonstrate Data Lakehouse architecture on AWS.

---

## 👥 Authors

- **Peterson VM** - [GitHub](https://github.com/petersonvm)

---

## 🙏 Acknowledgments

- AWS Glue Documentation
- Databricks Medallion Architecture
- Terraform AWS Provider Community

---

**Developed with ❤️ using Terraform, AWS Glue e Python**
