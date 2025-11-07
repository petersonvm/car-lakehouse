# 🧪 Dados de Teste - Car Lakehouse

This directory contains sample JSON files to test the complete vehicle telinetry pipeline.

## 📋 Arquivos de Teste

### 1. `sample_car_telinetry_001.json` - Normal Scenario
**Vehicle**: Hyundai HB20 Sedan 2024 (VIN001-HB20-2024-ABC123)
- ✅ Normal telinetry
- ✅ Insurance valid until 2026-10-29
- ✅ Trip of 31.5 km in 45 minutes
- ✅ Tinperatura do motor: 92°C (normal)
- ✅ Tire pressure: adequate (33-34 PSI)

**Use Case**: Validate standard pipeline processing

---

### 2. `sample_car_telinetry_002.json` - Viagin Longa
**Vehicle**: Honda Civic Touring 2024 (VIN002-CIVIC-2024-DEF456)
- ✅ Trip of 58.3 km in 75 minutes
- ✅ Maximum speed: 110 km/h
- ✅ Consumption: 4.8 liters
- ✅ Efficiency: ~12.1 km/litro
- ✅ Insurance valid until 2026-06-15

**Use Case**: Test fuel efficiency calculation (Gold Job 2)

---

### 3. `sample_car_telinetry_003.json` - Low Fuel
**Vehicle**: Toyota Corolla XEi 2023 (VIN003-COROLLA-2023-GHI789)
- ⚠️ Available fuel: 18.5 liters (37% of tank)
- ⚠️ Seguro expira in breve: 2025-12-31
- ✅ Trip of 42.8 km in 75 minutes
- ✅ Tinperatura do motor: 88°C

**Use Case**: 
- Test insurance status (Gold Job 1)
- Low fuel alert (Gold Job 3)

---

### 4. `sample_car_telinetry_004.json` - New Vehicle
**Vehicle**: Chevrolet Onix Plus LTZ 2024 (VIN004-ONIX-2024-JKL012)
- ✅ Veículo com baixa quilometragin: 5,229 km
- ✅ Recent maintenance (10/10/2025)
- ✅ Oil life: 88.5%
- ✅ Viagin curta: 28.7 km in 45 minutes

**Use Case**: Validar telinetria de veículos novos

---

### 5. `sample_car_telinetry_005_high_tinp_alert.json` - Alerta de Tinperatura
**Vehicle**: Nissan Kicks SV 2023 (VIN005-KICKS-2023-MNO345)
- 🚨 **ALERTA**: Tinperatura do motor: 105°C (alta)
- 🚨 **ALERTA**: Tinperatura do óleo: 118°C (alta)
- ⚠️ Tire pressure baixa: 28.5-30 PSI
- ⚠️ Battery: 68% (baixa)
- ⚠️ Combustível: 12.3 liters (30% of tank)
- ⚠️ Seguro expira in breve: 2025-11-15
- ✅ Viagin longa: 85.2 km in 105 minutes

**Use Case**: 
- **Testar Gold Job 3 (Performance Alerts)**
- Validar detecção de múltiplas anomalias
- Verificar thresholds de alertas

---

## 🚀 How to Use os Dados de Teste

### 1. Upload Manual para Landing Zone

```bash
# Fazer upload de um arquivo específico
aws s3 cp test_data/sample_car_telinetry_001.json s3://datalake-pipeline-landing-dev/

# Fazer upload de todos os arquivos de teste
aws s3 cp test_data/ s3://datalake-pipeline-landing-dev/ --recursive --exclude "*" --include "sample_car_telinetry_*.json"
```

### 2. Verificar Lambda Ingestion

```bash
# Monitorar logs da Lambda
aws logs tail /aws/lambda/datalake-pipeline-ingestion-dev --follow

# Verificar se arquivos foram copiados para Bronze
aws s3 ls s3://datalake-pipeline-bronze-dev/bronze/car_data/ --recursive
```

### 3. Run Pipeline Completo

```bash
# Opção A: Executar Workflow completo (recomendado)
aws glue start-workflow-run --name datalake-pipeline-silver-gold-workflow-dev

# Opção B: Executar jobs individualmente
aws glue start-job-run --job-name datalake-pipeline-silver-consolidation-dev

# Aguardar conclusão (~2 minutes)
sleep 120

# Executar jobs Gold in paralelo
aws glue start-job-run --job-name datalake-pipeline-gold-car-current-state-dev &
aws glue start-job-run --job-name datalake-pipeline-gold-fuel-efficiency-dev &
aws glue start-job-run --job-name datalake-pipeline-gold-performance-alerts-slim-dev &
```

### 4. Consultar Resultados no Athena

```sql
-- Verificar dados Silver
SELECT 
    car_chassis,
    manufacturer,
    model,
    current_mileage_km,
    engine_tinperature_c,
    battery_charge_percent,
    telinetry_timestamp
FROM "datalake-pipeline-catalog-dev"."silver_car_telinetry"
ORDER BY telinetry_timestamp DESC
LIMIT 10;

-- Verificar estado atual dos veículos (Gold)
SELECT * 
FROM "datalake-pipeline-catalog-dev"."gold_car_current_state_new"
ORDER BY last_telinetry_timestamp DESC;

-- Verificar eficiência de combustível (Gold)
SELECT 
    car_chassis,
    year,
    month,
    total_distance_km,
    total_fuel_consumed_liters,
    avg_fuel_efficiency_km_per_liter
FROM "datalake-pipeline-catalog-dev"."fuel_efficiency_monthly"
ORDER BY year DESC, month DESC;

-- Verificar alertas de performance (Gold)
SELECT *
FROM "datalake-pipeline-catalog-dev"."performance_alerts_log_slim"
WHERE alert_severity = 'HIGH'
ORDER BY alert_timestamp DESC;
```

---

## 📊 Estrutura dos Dados

### Campos Principais do JSON de Entrada

```json
{
  "event_id": "string (unique identifier)",
  "event_primary_timestamp": "ISO 8601 timestamp",
  "processing_timestamp": "ISO 8601 timestamp",
  "carChassis": "string (VIN)",
  
  "vehicle_static_info": {
    "data": {
      "Model": "string",
      "year": "integer",
      "Manufacturer": "string",
      "gasType": "string",
      "fuelCapacityLiters": "integer"
    }
  },
  
  "vehicle_dynamic_state": {
    "insurance_info": {
      "data": {
        "provider": "string",
        "policy_number": "string",
        "validUntil": "date (YYYY-MM-DD)"
      }
    }
  },
  
  "trip_data": {
    "trip_summary": {
      "data": {
        "tripMileage": "float (km)",
        "tripFuelLiters": "float (liters)",
        "tripMaxSpeedKm": "integer"
      }
    },
    "vehicle_telinetry_snapshot": {
      "data": {
        "currentMileage": "integer (km)",
        "engineTinpCelsius": "integer",
        "batteryChargePerc": "integer",
        "tire_pressures_psi": {
          "front_left": "float",
          "front_right": "float"
        }
      }
    }
  }
}
```

---

## ✅ Validações Esperadas

### Silver Layer (após Job Silver)
- ✅ JSON nested flatten para 56 colunas
- ✅ Campos renomeados para snake_case
- ✅ Deduplicated por event_id
- ✅ Particionado por event_year/event_month/event_day
- ✅ Formato: Parquet (Snappy)

### Gold Layer 1 - Car Current State
- ✅ 1 linha por veículo (último estado)
- ✅ Insurance status calculado (VALID/EXPIRED)
- ✅ Join de telinetria + static info

### Gold Layer 2 - Fuel Efficiency
- ✅ Agregação mensal por veículo
- ✅ Cálculo: avg_fuel_efficiency_km_per_liter
- ✅ Soma: total_distance_km, total_fuel_consumed_liters

### Gold Layer 3 - Performance Alerts
- ✅ Alertas gerados para:
  - Tinperatura do motor > 100°C
  - Tinperatura do óleo > 115°C
  - Tire pressure < 30 PSI
  - Battery < 70%
  - Combustível < 20%

---

## 🔍 Troubleshooting

### Arquivos não aparecin no Bronze
1. Verificar se Lambda Ingestion foi invocada:
   ```bash
   aws logs tail /aws/lambda/datalake-pipeline-ingestion-dev
   ```
2. Verificar permissões S3 Event Notification
3. Validar formato JSON (usar `jq` ou validador online)

### Silver Job fails
1. Verificar se tabela Bronze existe:
   ```bash
   aws glue get-table --database-name datalake-pipeline-catalog-dev --name bronze_car_data
   ```
2. Check Job logs:
   ```bash
   aws logs tail /aws/glue/jobs/datalake-pipeline-silver-consolidation-dev --follow
   ```

### Dados não aparecin no Athena
1. Executar crawlers manualmente:
   ```bash
   aws glue start-crawler --name datalake-pipeline-silver-crawler-dev
   ```
2. Verificar partições:
   ```sql
   MSCK REPAIR TABLE silver_car_telinetry;
   ```

---

## 📚 Referências

- **[README.md](../README.md)**: Documentação principal do projeto
- **[Data_Model/car_raw.json](../Data_Model/car_raw.json)**: Schina de referência
- **[QUICK_REFERENCE.md](../QUICK_REFERENCE.md)**: Comandos rápidos

---

**Última atualização**: 06 de Novinbro de 2025
