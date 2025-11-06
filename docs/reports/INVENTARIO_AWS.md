# 📊 Inventário Completo - Componentes AWS
## Data Lakehouse - Telemetria de Veículos

**Data:** 05/11/2025  
**Ambiente:** DEV  
**Arquitetura:** Medallion (Bronze → Silver → Gold)

---

## 📦 1. AMAZON S3 (STORAGE)

### Buckets Configurados: 5

#### 🪣 datalake-pipeline-raw-dev
- **Papel:** Ingestão de dados brutos (Raw Zone)
- **Conteúdo:** JSON original do EventBridge
- **Formato:** JSON não estruturado
- **Retenção:** Dados históricos completos

#### 🪣 datalake-pipeline-bronze-dev
- **Papel:** Camada Bronze (dados estruturados iniciais)
- **Conteúdo:** Parquet com schema básico
- **Tabelas:**
  - `car_bronze` (JSON parseado)
  - `car_bronze_structured` (colunas explodidas)
- **Particionamento:** `event_year/event_month/event_day`

#### 🪣 datalake-pipeline-silver-dev
- **Papel:** Camada Silver (dados limpos e enriquecidos)
- **Conteúdo:** Parquet otimizado com KPIs calculados
- **Tabelas:**
  - `car_silver` (consolidado com snake_case)
- **Transformações:**
  - Normalização de colunas (snake_case)
  - Cálculo de KPIs (insurance_days_to_expiry)
  - Deduplicação por event_id
- **Particionamento:** `event_year/event_month/event_day`

#### 🪣 datalake-pipeline-gold-dev
- **Papel:** Camada Gold (dados analíticos agregados)
- **Conteúdo:** Datasets prontos para consumo (BI/Analytics)
- **Tabelas:**
  - `gold_car_current_state` (estado atual dos veículos)
  - `fuel_efficiency_monthly` (eficiência mensal)
  - `performance_alerts_log_slim` (alertas críticos)
- **Agregações:**
  - Window functions (última posição por veículo)
  - Agregações mensais (consumo combustível)
  - Filtros de criticidade (alertas >100°C, <20% bateria)

#### 🪣 datalake-pipeline-athena-results-dev
- **Papel:** Armazenamento de resultados de queries Athena
- **Conteúdo:** Outputs de queries executadas
- **Gestão:** Lifecycle policies para limpeza automática

---

## ⚙️ 2. AWS GLUE (ETL & DATA CATALOG)

### 📊 Glue Data Catalog

**Database:** `datalake-pipeline-catalog-dev`  
**Tabelas Ativas:** 5

#### Bronze Layer
- **car_bronze**
  - Schema: event_id, event_timestamp, car_data (struct)
  - Papel: Primeira estruturação dos dados JSON
  
- **car_bronze_structured**
  - Schema: 45+ colunas explodidas
  - Papel: Dados bronze com todas colunas acessíveis

#### Silver Layer
- **car_silver**
  - Schema: 45 colunas (snake_case normalizadas)
  - Papel: Fonte única para camada Gold
  - Colunas-chave: car_chassis, event_timestamp, engine_temp_celsius, fuel_available_liters

#### Gold Layer
- **gold_car_current_state**
  - Schema: 45 colunas + insurance_status (KPI)
  - Papel: Snapshot do estado atual de cada veículo
  - Partições: processing_date
  
- **fuel_efficiency_monthly**
  - Schema: Agregações por manufacturer/model/ano/mês
  - Papel: Análise de eficiência energética
  - KPIs: avg_fuel_efficiency_l_per_100km, efficiency_category
  - Partições: processing_year/processing_month

### 🔄 Glue ETL Jobs

**Total:** 6 jobs (4 ativos + 2 legados)

#### 1. datalake-pipeline-silver-consolidation-dev
- **Fonte:** car_bronze_structured (Bronze)
- **Destino:** car_silver (Silver)
- **Papel:** Consolidação e normalização
- **Transformações:**
  - Renomeia colunas para snake_case
  - Calcula insurance_days_to_expiry
  - Deduplica por event_id
- **Job Bookmark:** Habilitado

#### 2. datalake-pipeline-gold-car-current-state-dev
- **Fonte:** car_silver (Silver)
- **Destino:** gold_car_current_state (Gold)
- **Papel:** Estado atual dos veículos
- **Transformações:**
  - Window function (último evento por car_chassis)
  - Calcula insurance_status (VALID/EXPIRED/EXPIRING)
- **Partições:** processing_date
- **Job Bookmark:** Habilitado

#### 3. datalake-pipeline-gold-fuel-efficiency-dev
- **Fonte:** car_silver (Silver)
- **Destino:** fuel_efficiency_monthly (Gold)
- **Papel:** Análise de eficiência energética
- **Transformações:**
  - Agregação mensal por manufacturer/model
  - Calcula avg_fuel_efficiency_l_per_100km
  - Categoriza eficiência (EXCELLENT/GOOD/AVERAGE/POOR)
- **Partições:** processing_year/processing_month
- **Job Bookmark:** Habilitado

#### 4. datalake-pipeline-gold-performance-alerts-slim-dev
- **Fonte:** car_silver (Silver)
- **Destino:** performance_alerts_log_slim (Gold)
- **Papel:** Detecção de alertas críticos
- **Transformações:**
  - Filtra eventos críticos:
    - Temperatura motor >100°C
    - Bateria <20%
    - Combustível <10% capacidade
    - Vida do óleo <25%
  - Classifica severidade (CRITICAL)
- **Partições:** alert_type/event_year/event_month/event_day
- **Job Bookmark:** Habilitado

#### 5. datalake-pipeline-gold-performance-alerts-dev
- **Status:** Job legado (mantido para compatibilidade)

#### 6. silver-test-job
- **Papel:** Job de teste/desenvolvimento

### 🕷️ Glue Crawlers

**Total:** 7 crawlers

| Crawler | Target S3 | Papel |
|---------|-----------|-------|
| datalake-pipeline-bronze-car-crawler-dev | s3://datalake-pipeline-bronze-dev/car/ | Descobre schema da tabela car_bronze |
| datalake-pipeline-bronze-car-structured-crawler-dev | s3://datalake-pipeline-bronze-dev/car_structured/ | Descobre schema da tabela car_bronze_structured |
| datalake-pipeline-silver-car-crawler-dev | s3://datalake-pipeline-silver-dev/car/ | Descobre schema da tabela car_silver |
| datalake-pipeline-gold-car-current-state-crawler-dev | s3://datalake-pipeline-gold-dev/car_current_state/ | Atualiza schema da tabela gold_car_current_state |
| datalake-pipeline-gold-fuel-efficiency-crawler-dev | s3://datalake-pipeline-gold-dev/fuel_efficiency_monthly/ | Atualiza schema da tabela fuel_efficiency_monthly |
| datalake-pipeline-gold-performance-alerts-crawler-dev | s3://datalake-pipeline-gold-dev/performance_alerts_log/ | Crawler legado (tabela deletada) |
| datalake-pipeline-gold-performance-alerts-slim-crawler-dev | s3://datalake-pipeline-gold-dev/performance_alerts_log_slim/ | Atualiza schema da tabela performance_alerts_log_slim |

---

## 🔍 3. AMAZON ATHENA (QUERY ENGINE)

### Workgroup: datalake-pipeline-workgroup-dev

- **Papel:** Engine de queries SQL serverless
- **Uso:**
  - Análises ad-hoc sobre as tabelas do Data Catalog
  - Validação de dados e QA
  - Queries para BI e relatórios
- **Output Location:** s3://datalake-pipeline-athena-results-dev/
- **Integração:** Glue Data Catalog para descoberta de schemas

---

## 🔐 4. AWS IAM (SECURITY & PERMISSIONS)

### Roles Configuradas: 2

#### datalake-pipeline-glue-role-dev
- **Papel:** Execução de Glue Jobs e Crawlers
- **Permissões:**
  - S3: Read/Write em todos os buckets do pipeline
  - Glue: Acesso ao Data Catalog
  - CloudWatch: Escrita de logs

#### datalake-pipeline-athena-role-dev
- **Papel:** Execução de queries Athena
- **Permissões:**
  - S3: Read em buckets de dados, Write em results
  - Glue: Read no Data Catalog

---

## 📊 5. FLUXO DE DADOS (DATA PIPELINE)

### Arquitetura Medallion (4 camadas)

```
┌─────────────────────────────────────────────┐
│  🚗 EventBridge (Eventos de Veículos)       │
└───────────────────┬─────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│  📁 RAW ZONE (S3)                           │
│  datalake-pipeline-raw-dev                  │
│  Formato: JSON bruto                        │
└───────────────────┬─────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│  🥉 BRONZE LAYER                            │
│  ├─ Glue Crawler (Schema Discovery)        │
│  ├─ car_bronze (JSON parseado)             │
│  └─ car_bronze_structured (45+ colunas)    │
│  📦 Parquet particionado                    │
└───────────────────┬─────────────────────────┘
                    ↓
      ⚙️ Glue Job: silver-consolidation
                    ↓
┌─────────────────────────────────────────────┐
│  🥈 SILVER LAYER                            │
│  └─ car_silver (fonte única normalizada)   │
│     • Snake_case columns                    │
│     • KPIs calculados                       │
│     • Deduplicado                           │
└───────────────────┬─────────────────────────┘
                    │
      ┌─────────────┼─────────────┐
      ↓             ↓             ↓
┌──────────┐  ┌──────────┐  ┌──────────┐
│ Car      │  │ Fuel     │  │ Alerts   │
│ State    │  │ Effic.   │  │ Slim     │
│ Job      │  │ Job      │  │ Job      │
└──────────┘  └──────────┘  └──────────┘
      │             │             │
      └─────────────┼─────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│  🥇 GOLD LAYER (Analytics-Ready)            │
│  ├─ gold_car_current_state                  │
│  │  (Snapshot de frota)                     │
│  ├─ fuel_efficiency_monthly                 │
│  │  (Agregações mensais)                    │
│  └─ performance_alerts_log_slim             │
│     (Alertas críticos)                      │
└───────────────────┬─────────────────────────┘
                    ↓
      🔍 Amazon Athena (Query Engine)
                    ↓
      📊 BI Tools / Dashboards / APIs
```

---

## 🔑 6. PRINCIPAIS CASOS DE USO

### 📊 Análise de Estado de Frota
- **Tabela:** gold_car_current_state
- **Use Case:** Dashboard de monitoramento em tempo real
- **Métricas:** Quilometragem, temperatura, status seguro

### ⚡ Análise de Eficiência Energética
- **Tabela:** fuel_efficiency_monthly
- **Use Case:** Otimização de consumo de combustível
- **Métricas:** L/100km, categorização de eficiência

### 🚨 Sistema de Alertas Críticos
- **Tabela:** performance_alerts_log_slim
- **Use Case:** Manutenção preventiva e segurança
- **Alertas:** Superaquecimento, bateria baixa, combustível

---

## 💡 7. CARACTERÍSTICAS TÉCNICAS

✅ **Serverless:** Todos os componentes escaláveis automaticamente  
✅ **Schema Evolution:** Crawlers mantêm schemas atualizados  
✅ **Job Bookmarks:** Processamento incremental (sem reprocessamento)  
✅ **Particionamento:** Queries otimizadas por data  
✅ **Formato Parquet:** Compressão e performance em colunas  
✅ **Data Quality:** KPIs calculados com regras de negócio  
✅ **Auditoria:** CloudWatch Logs para todos os jobs

---

## 📈 8. ESTATÍSTICAS DO AMBIENTE

| Componente | Quantidade |
|------------|------------|
| Buckets S3 | 5 |
| Tabelas Glue Catalog | 5 ativas |
| Glue ETL Jobs | 6 (4 ativos + 2 legados) |
| Glue Crawlers | 7 |
| IAM Roles | 2 |
| Athena Workgroups | 1 |

---

## 📝 9. HISTÓRICO DE MUDANÇAS

### 2025-11-05 - Refatoração Silver → Gold
- ✅ Migração de `silver_car_telemetry` → `car_silver`
- ✅ Atualização de schemas (camelCase → snake_case)
- ✅ Limpeza de tabelas legadas:
  - Deletada: `silver_car_telemetry_new` (12.5 KiB)
  - Deletada: `performance_alerts_log` (850.2 KiB)
  - Deletada: `silver_car_telemetry` (0 Bytes)
- ✅ Validação QA completa das 3 tabelas Gold
- ✅ Correção de schemas via DELETE TABLE → CRAWLER → MSCK REPAIR

---

## ✅ STATUS FINAL

**🎯 Ambiente Validado e Pronto para Produção**

Data Lakehouse com arquitetura Medallion completa (RAW→BRONZE→SILVER→GOLD), schemas normalizados, KPIs calculados e datasets prontos para consumo por ferramentas de BI e APIs.

**Última atualização:** 05/11/2025 12:30
