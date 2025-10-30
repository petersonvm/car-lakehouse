# Arquitetura: Migração Lambda → Glue Job

## 📊 Diagrama de Arquitetura

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                              AWS DATA LAKEHOUSE ARCHITECTURE                          │
│                              (Medallion: Bronze → Silver)                             │
└──────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────┐
│ FASE 1: INGESTÃO (Landing → Bronze) - SEM ALTERAÇÕES                                │
└─────────────────────────────────────────────────────────────────────────────────────┘

   📁 S3 Landing                    ⚡ Lambda Ingestion              📁 S3 Bronze
   ┌─────────────┐                  ┌──────────────────┐           ┌───────────────┐
   │             │  S3 Event        │                  │           │               │
   │  car_raw    │ ─────────────>   │  • JSON → Parquet│ ────────> │  Parquet      │
   │  .json      │  ObjectCreated   │  • Normalize     │           │  (nested)     │
   │             │                  │    types         │           │               │
   └─────────────┘                  │  • Preserve      │           └───────────────┘
                                    │    structs       │
                                    │                  │
                                    │  Runtime:        │           🗃️ Glue Catalog
                                    │  • Python 3.9    │           ┌───────────────┐
                                    │  • 512 MB        │  Crawled  │ bronze_       │
                                    │  • 120s timeout  │ ────────> │ ingest_       │
                                    │  • Pandas Layer  │           │ year_2025     │
                                    └──────────────────┘           └───────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────┐
│ FASE 2: TRANSFORMAÇÃO (Bronze → Silver) - MIGRAÇÃO REALIZADA                        │
└─────────────────────────────────────────────────────────────────────────────────────┘

════════════════════════════════════════════════════════════════════════════════════════
║ ❌ ARQUITETURA ANTIGA (Lambda Event-Driven)                                         ║
════════════════════════════════════════════════════════════════════════════════════════

   📁 S3 Bronze                     ⚡ Lambda Cleansing             📁 S3 Silver
   ┌─────────────┐                  ┌──────────────────┐           ┌───────────────┐
   │             │  S3 Event        │                  │           │               │
   │  Parquet    │ ─────────────>   │  • Flatten       │ ────────> │  Parquet      │
   │  (nested)   │  ObjectCreated   │  • Cleanse       │  APPEND   │  (flat)       │
   │             │                  │  • Enrich        │           │               │
   └─────────────┘                  │  • Partition     │           └───────────────┘
                                    │                  │
     Arquivo 1 ────> Lambda ────> Silver/file1.parquet
     Arquivo 2 ────> Lambda ────> Silver/file2.parquet
     Arquivo 3 ────> Lambda ────> Silver/file3.parquet
     
     ⚠️ PROBLEMA: Múltiplos arquivos para o mesmo carChassis + event_day
     ⚠️ RESULTADO: Duplicatas no Athena
     
════════════════════════════════════════════════════════════════════════════════════════
║ ✅ ARQUITETURA NOVA (Glue Job Scheduled + Consolidation)                            ║
════════════════════════════════════════════════════════════════════════════════════════

   📁 S3 Bronze                     🔧 AWS Glue Job                📁 S3 Silver
   ┌─────────────┐                  ┌──────────────────┐           ┌───────────────┐
   │             │                  │                  │           │               │
   │  Parquet    │  Job Bookmarks   │  ETAPA 1:        │           │  Parquet      │
   │  (nested)   │ ─────────────>   │  Read NEW files  │           │  (flat)       │
   │             │  (apenas novos)  │  from Bronze     │           │  CONSOLIDATED │
   │  file1.pq   │                  │                  │           │               │
   │  file2.pq   │                  │  ETAPA 2:        │           └───────────────┘
   │  file3.pq   │                  │  Transform       │
   └─────────────┘                  │  • Flatten       │           🗃️ Glue Catalog
                                    │  • Cleanse       │           ┌───────────────┐
                                    │  • Enrich        │  Crawled  │ silver_car_   │
        ⏰ EventBridge               │  • Partition     │ ────────> │ telemetry     │
        ┌─────────────┐             │                  │           └───────────────┘
        │ Cron Trigger│             │  ETAPA 3:        │
        │ (Hourly)    │             │  Read EXISTING   │
        │             │             │  Silver data     │           📊 Athena
        │ 0 */1 * * ? │ ──────────> │                  │           ┌───────────────┐
        └─────────────┘  Start Job  │  ETAPA 4:        │  Queries  │ SELECT *      │
                                    │  Union + Dedup   │ <──────── │ FROM silver_  │
                                    │  (Window func)   │           │ car_telemetry │
        🧠 Deduplication:           │                  │           └───────────────┘
        ┌─────────────────────┐    │  ETAPA 5:        │
        │ Window Function:    │    │  Write with      │
        │                     │    │  Dynamic         │
        │ PARTITION BY:       │    │  Partition       │
        │  • carChassis       │    │  Overwrite       │
        │  • event_year       │    │                  │
        │  • event_month      │    │  Runtime:        │
        │  • event_day        │    │  • Spark 3.3     │
        │                     │    │  • 2×G.1X DPUs   │
        │ ORDER BY:           │    │  • 60min timeout │
        │  • currentMileage   │    │  • PySpark 3     │
        │    DESC             │    └──────────────────┘
        │                     │
        │ KEEP: row_num = 1   │    ✅ RESULTADO: Apenas 1 registro por chave
        └─────────────────────┘    ✅ Partições sobrescritas dinamicamente

┌─────────────────────────────────────────────────────────────────────────────────────┐
│ EXEMPLO DE PROCESSAMENTO                                                            │
└─────────────────────────────────────────────────────────────────────────────────────┘

  Input (Bronze - 3 arquivos):
  ┌────────────────────────────────────────────────────────────┐
  │ carChassis | currentMileage | event_day | arquivo         │
  ├────────────────────────────────────────────────────────────┤
  │ 5ifRW...   | 4321           | 29        | file1.parquet   │  ← Upload 1
  │ 5ifRW...   | 8500           | 29        | file2.parquet   │  ← Upload 2
  │ 5ifRW...   | 12000          | 29        | file3.parquet   │  ← Upload 3
  └────────────────────────────────────────────────────────────┘

  Lambda (Antigo) - APPEND:
  ┌────────────────────────────────────────────────────────────┐
  │ Silver Output: 3 registros (DUPLICATAS ❌)                 │
  ├────────────────────────────────────────────────────────────┤
  │ 5ifRW... | 4321   | 29                                     │
  │ 5ifRW... | 8500   | 29                                     │
  │ 5ifRW... | 12000  | 29                                     │
  └────────────────────────────────────────────────────────────┘

  Glue Job (Novo) - CONSOLIDATION:
  ┌────────────────────────────────────────────────────────────┐
  │ Silver Output: 1 registro (ÚNICO ✅)                       │
  ├────────────────────────────────────────────────────────────┤
  │ 5ifRW... | 12000  | 29    ← Maior milhagem mantida        │
  └────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────┐
│ INFRAESTRUTURA TERRAFORM                                                             │
└─────────────────────────────────────────────────────────────────────────────────────┘

  ✅ RECURSOS CRIADOS (11)
  ┌──────────────────────────────────────────────────────────────────────┐
  │ S3 Buckets                                                           │
  │  • aws_s3_bucket.glue_scripts (scripts PySpark)                      │
  │  • aws_s3_bucket.glue_temp (arquivos temporários)                    │
  │                                                                      │
  │ S3 Objects                                                           │
  │  • aws_s3_object.silver_consolidation_script (upload script)         │
  │                                                                      │
  │ IAM                                                                  │
  │  • aws_iam_role.glue_job (role principal)                            │
  │  • aws_iam_role_policy.glue_s3_access (Bronze read, Silver RWD)     │
  │  • aws_iam_role_policy.glue_catalog_access (Catalog full access)    │
  │  • aws_iam_role_policy.glue_cloudwatch_logs (Logs write)            │
  │                                                                      │
  │ Glue                                                                 │
  │  • aws_glue_job.silver_consolidation (Job ETL)                       │
  │  • aws_glue_trigger.silver_consolidation_schedule (Trigger cron)     │
  │                                                                      │
  │ CloudWatch                                                           │
  │  • aws_cloudwatch_log_group.glue_job_logs (14 dias retenção)        │
  │                                                                      │
  │ Data Sources                                                         │
  │  • data.aws_caller_identity.current (Account ID)                     │
  └──────────────────────────────────────────────────────────────────────┘

  ❌ RECURSOS REMOVIDOS (2)
  ┌──────────────────────────────────────────────────────────────────────┐
  │ • aws_lambda_permission.allow_s3_invoke_cleansing                    │
  │ • aws_s3_bucket_notification.bronze_bucket_notification              │
  └──────────────────────────────────────────────────────────────────────┘

  ⚪ RECURSOS MANTIDOS (sem alterações)
  ┌──────────────────────────────────────────────────────────────────────┐
  │ • aws_lambda_function.ingestion (Landing → Bronze)                   │
  │ • aws_lambda_function.cleansing (mantida, mas não acionada)          │
  │ • aws_s3_bucket.data_lake[*] (todos os buckets)                      │
  │ • aws_glue_crawler.bronze_crawler                                    │
  │ • aws_glue_crawler.silver_crawler                                    │
  │ • aws_athena_workgroup.data_lake                                     │
  └──────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────┐
│ FLUXO DE DADOS DETALHADO - NOVA ARQUITETURA                                         │
└─────────────────────────────────────────────────────────────────────────────────────┘

  1️⃣  Upload JSON
      └─> s3://landing/car_raw.json
  
  2️⃣  Lambda Ingestion (automático, S3 trigger)
      ├─> Lê JSON
      ├─> Normaliza tipos (int → float em structs)
      ├─> Converte para Parquet (mantém nested structs)
      └─> Escreve s3://bronze/ingest_year=2025/.../*.parquet
  
  3️⃣  Crawler Bronze (agendado ou manual)
      ├─> Escaneia s3://bronze/
      ├─> Detecta schema (com structs: metrics.trip.*, etc.)
      └─> Atualiza Glue Catalog: bronze_ingest_year_2025
  
  4️⃣  Glue Job (agendado - horário via EventBridge)
      ├─> [ETAPA 1] Lê NOVOS dados do Bronze (Job Bookmarks)
      │   └─> SELECT * FROM bronze_ingest_year_2025 WHERE [novos arquivos]
      │
      ├─> [ETAPA 2] Aplica transformações Silver (PySpark)
      │   ├─> Flatten: metrics.trip.tripMileage → metrics_trip_tripMileage
      │   ├─> Cleanse: Manufacturer → Title Case, color → lowercase
      │   ├─> Convert: String timestamps → timestamp type
      │   ├─> Enrich: 
      │   │   • fuel_level_percentage = (fuelAvailable / fuelCapacity) × 100
      │   │   • km_per_liter = tripMileage / tripFuelLiters
      │   └─> Partition: event_year, event_month, event_day (from metricTimestamp)
      │
      ├─> [ETAPA 3] Lê dados EXISTENTES do Silver
      │   └─> spark.read.parquet("s3://silver/car_telemetry/")
      │
      ├─> [ETAPA 4] Union + Deduplicação
      │   ├─> df_union = df_new.unionByName(df_existing)
      │   ├─> Window.partitionBy("carChassis", "event_year", "event_month", "event_day")
      │   │         .orderBy(col("currentMileage").desc())
      │   ├─> row_number() OVER (window_spec)
      │   └─> FILTER WHERE row_num = 1  ← Mantém apenas maior milhagem
      │
      └─> [ETAPA 5] Escreve com Dynamic Partition Overwrite
          ├─> spark.conf.set("partitionOverwriteMode", "dynamic")
          └─> df.write.parquet("s3://silver/car_telemetry/", mode="overwrite", partitionBy=[...])
              └─> Sobrescreve APENAS partições afetadas (event_day=29)
  
  5️⃣  Crawler Silver (agendado ou manual)
      ├─> Escaneia s3://silver/car_telemetry/
      ├─> Detecta schema (flat, sem structs)
      └─> Atualiza Glue Catalog: silver_car_telemetry
  
  6️⃣  Athena Query
      └─> SELECT * FROM silver_car_telemetry WHERE event_day = '29'
          └─> Retorna: 1 registro único por carChassis ✅

┌─────────────────────────────────────────────────────────────────────────────────────┐
│ TECNOLOGIAS E VERSÕES                                                                │
└─────────────────────────────────────────────────────────────────────────────────────┘

  Lambda Ingestion:
    • Python 3.9
    • Pandas 2.0.3 (via Layer)
    • PyArrow 13.0.0 (via Layer)
    • Boto3 (built-in)
    • Memory: 512 MB
    • Timeout: 120s

  AWS Glue Job:
    • Glue Version: 4.0
    • Spark: 3.3.0
    • Python: 3.10
    • PySpark: 3.3.0
    • Worker: G.1X (4 vCPU, 16 GB RAM)
    • Workers: 2 (auto-scaling habilitado)
    • Timeout: 60 min

  Terraform:
    • Version: >= 1.0
    • AWS Provider: >= 5.0

  AWS Services:
    • S3 (storage)
    • Lambda (ingestion)
    • Glue (ETL + Catalog)
    • Athena (queries)
    • CloudWatch (logs + metrics)
    • IAM (permissions)
    • EventBridge (scheduling)

┌─────────────────────────────────────────────────────────────────────────────────────┐
│ CUSTOS COMPARATIVOS                                                                  │
└─────────────────────────────────────────────────────────────────────────────────────┘

  ANTES (Lambda Cleansing):
  ┌──────────────────────────────────────────────────────┐
  │ Componente         │ Custo/Mês    │ Observações     │
  ├──────────────────────────────────────────────────────┤
  │ Lambda Requests    │ $0,0006      │ 3.000 requests  │
  │ Lambda Compute     │ $1,50        │ 90.000 GB-s     │
  │ S3 (Silver)        │ $0,50        │ ~20 GB          │
  │ ────────────────────────────────────────────────────│
  │ TOTAL              │ $2,00/mês    │                 │
  └──────────────────────────────────────────────────────┘
  ⚠️ Problema: Duplicatas não resolvidas

  DEPOIS (Glue Job):
  ┌──────────────────────────────────────────────────────┐
  │ Componente         │ Custo/Mês    │ Observações     │
  ├──────────────────────────────────────────────────────┤
  │ Glue Job (DPUs)    │ $52,80       │ 120 DPU-hours   │
  │ S3 Scripts         │ $0,01        │ < 1 MB          │
  │ S3 Temp            │ $0,10        │ Lifecycle 7d    │
  │ S3 (Silver)        │ $0,30        │ ~12 GB (dedup)  │
  │ CloudWatch Logs    │ $0,50        │ 14d retenção    │
  │ ────────────────────────────────────────────────────│
  │ TOTAL              │ $53,70/mês   │                 │
  └──────────────────────────────────────────────────────┘
  ✅ Benefício: Dados consolidados, sem duplicatas

  Diferença: +$51,70/mês (+2585%)
  ROI: Qualidade de dados + Escalabilidade + Consolidação

┌─────────────────────────────────────────────────────────────────────────────────────┐
│ DEPLOY CHECKLIST                                                                     │
└─────────────────────────────────────────────────────────────────────────────────────┘

  PRÉ-DEPLOY:
  ☐ Terraform instalado (>= 1.0)
  ☐ AWS CLI instalado e configurado
  ☐ Credenciais AWS válidas
  ☐ Script PySpark validado (silver_consolidation_job.py)
  ☐ Backup do estado Terraform

  DEPLOY:
  ☐ cd terraform
  ☐ terraform init (se primeira vez)
  ☐ terraform plan (revisar mudanças)
  ☐ terraform apply (confirmar com 'yes')

  PÓS-DEPLOY:
  ☐ Verificar Glue Job criado
  ☐ Verificar Trigger habilitado
  ☐ Verificar Script no S3
  ☐ Verificar IAM Role e políticas
  ☐ Teste manual: aws glue start-job-run
  ☐ Monitorar CloudWatch Logs
  ☐ Upload dados de teste
  ☐ Validar deduplicação no Athena

  PRODUÇÃO:
  ☐ Monitorar execuções agendadas (1 semana)
  ☐ Validar custos (AWS Cost Explorer)
  ☐ Configurar alarmes CloudWatch
  ☐ Ajustar configurações (workers, schedule)
  ☐ (Opcional) Remover Lambda Cleansing

```

---

**Legenda:**
- 📁 = S3 Bucket
- ⚡ = AWS Lambda
- 🔧 = AWS Glue Job
- ⏰ = EventBridge Trigger
- 🗃️ = Glue Data Catalog
- 📊 = Amazon Athena
- ✅ = Recurso criado
- ❌ = Recurso removido
- ⚪ = Sem alterações
- ⚠️ = Problema/Limitação

**Autor**: Sistema de Data Lakehouse  
**Data**: 2025-10-30  
**Versão**: 1.0
