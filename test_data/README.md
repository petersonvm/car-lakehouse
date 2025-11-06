# 🧪 Dados de Teste - Car Lakehouse

Este diretório contém arquivos JSON de exemplo para testar o pipeline completo de telemetria veicular.

## 📋 Arquivos de Teste

### 1. `sample_car_telemetry_001.json` - Cenário Normal
**Veículo**: Hyundai HB20 Sedan 2024 (VIN001-HB20-2024-ABC123)
- ✅ Telemetria normal
- ✅ Seguro válido até 2026-10-29
- ✅ Viagem de 31.5 km em 45 minutos
- ✅ Temperatura do motor: 92°C (normal)
- ✅ Pressão dos pneus: adequada (33-34 PSI)

**Caso de Uso**: Validar processamento padrão do pipeline

---

### 2. `sample_car_telemetry_002.json` - Viagem Longa
**Veículo**: Honda Civic Touring 2024 (VIN002-CIVIC-2024-DEF456)
- ✅ Viagem de 58.3 km em 75 minutos
- ✅ Velocidade máxima: 110 km/h
- ✅ Consumo: 4.8 litros
- ✅ Eficiência: ~12.1 km/litro
- ✅ Seguro válido até 2026-06-15

**Caso de Uso**: Testar cálculo de eficiência de combustível (Gold Job 2)

---

### 3. `sample_car_telemetry_003.json` - Combustível Baixo
**Veículo**: Toyota Corolla XEi 2023 (VIN003-COROLLA-2023-GHI789)
- ⚠️ Combustível disponível: 18.5 litros (37% do tanque)
- ⚠️ Seguro expira em breve: 2025-12-31
- ✅ Viagem de 42.8 km em 75 minutos
- ✅ Temperatura do motor: 88°C

**Caso de Uso**: 
- Testar status de seguro (Gold Job 1)
- Alerta de combustível baixo (Gold Job 3)

---

### 4. `sample_car_telemetry_004.json` - Veículo Novo
**Veículo**: Chevrolet Onix Plus LTZ 2024 (VIN004-ONIX-2024-JKL012)
- ✅ Veículo com baixa quilometragem: 5,229 km
- ✅ Manutenção recente (10/10/2025)
- ✅ Vida do óleo: 88.5%
- ✅ Viagem curta: 28.7 km em 45 minutos

**Caso de Uso**: Validar telemetria de veículos novos

---

### 5. `sample_car_telemetry_005_high_temp_alert.json` - Alerta de Temperatura
**Veículo**: Nissan Kicks SV 2023 (VIN005-KICKS-2023-MNO345)
- 🚨 **ALERTA**: Temperatura do motor: 105°C (alta)
- 🚨 **ALERTA**: Temperatura do óleo: 118°C (alta)
- ⚠️ Pressão dos pneus baixa: 28.5-30 PSI
- ⚠️ Bateria: 68% (baixa)
- ⚠️ Combustível: 12.3 litros (30% do tanque)
- ⚠️ Seguro expira em breve: 2025-11-15
- ✅ Viagem longa: 85.2 km em 105 minutos

**Caso de Uso**: 
- **Testar Gold Job 3 (Performance Alerts)**
- Validar detecção de múltiplas anomalias
- Verificar thresholds de alertas

---

## 🚀 Como Usar os Dados de Teste

### 1. Upload Manual para Landing Zone

```bash
# Fazer upload de um arquivo específico
aws s3 cp test_data/sample_car_telemetry_001.json s3://datalake-pipeline-landing-dev/

# Fazer upload de todos os arquivos de teste
aws s3 cp test_data/ s3://datalake-pipeline-landing-dev/ --recursive --exclude "*" --include "sample_car_telemetry_*.json"
```

### 2. Verificar Lambda Ingestion

```bash
# Monitorar logs da Lambda
aws logs tail /aws/lambda/datalake-pipeline-ingestion-dev --follow

# Verificar se arquivos foram copiados para Bronze
aws s3 ls s3://datalake-pipeline-bronze-dev/bronze/car_data/ --recursive
```

### 3. Executar Pipeline Completo

```bash
# Opção A: Executar Workflow completo (recomendado)
aws glue start-workflow-run --name datalake-pipeline-silver-gold-workflow-dev

# Opção B: Executar jobs individualmente
aws glue start-job-run --job-name datalake-pipeline-silver-consolidation-dev

# Aguardar conclusão (~2 minutos)
sleep 120

# Executar jobs Gold em paralelo
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
    engine_temperature_c,
    battery_charge_percent,
    telemetry_timestamp
FROM "datalake-pipeline-catalog-dev"."silver_car_telemetry"
ORDER BY telemetry_timestamp DESC
LIMIT 10;

-- Verificar estado atual dos veículos (Gold)
SELECT * 
FROM "datalake-pipeline-catalog-dev"."gold_car_current_state_new"
ORDER BY last_telemetry_timestamp DESC;

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
    "vehicle_telemetry_snapshot": {
      "data": {
        "currentMileage": "integer (km)",
        "engineTempCelsius": "integer",
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
- ✅ Join de telemetria + static info

### Gold Layer 2 - Fuel Efficiency
- ✅ Agregação mensal por veículo
- ✅ Cálculo: avg_fuel_efficiency_km_per_liter
- ✅ Soma: total_distance_km, total_fuel_consumed_liters

### Gold Layer 3 - Performance Alerts
- ✅ Alertas gerados para:
  - Temperatura do motor > 100°C
  - Temperatura do óleo > 115°C
  - Pressão dos pneus < 30 PSI
  - Bateria < 70%
  - Combustível < 20%

---

## 🔍 Troubleshooting

### Arquivos não aparecem no Bronze
1. Verificar se Lambda Ingestion foi invocada:
   ```bash
   aws logs tail /aws/lambda/datalake-pipeline-ingestion-dev
   ```
2. Verificar permissões S3 Event Notification
3. Validar formato JSON (usar `jq` ou validador online)

### Job Silver falha
1. Verificar se tabela Bronze existe:
   ```bash
   aws glue get-table --database-name datalake-pipeline-catalog-dev --name bronze_car_data
   ```
2. Verificar logs do Job:
   ```bash
   aws logs tail /aws/glue/jobs/datalake-pipeline-silver-consolidation-dev --follow
   ```

### Dados não aparecem no Athena
1. Executar crawlers manualmente:
   ```bash
   aws glue start-crawler --name datalake-pipeline-silver-crawler-dev
   ```
2. Verificar partições:
   ```sql
   MSCK REPAIR TABLE silver_car_telemetry;
   ```

---

## 📚 Referências

- **[README.md](../README.md)**: Documentação principal do projeto
- **[Data_Model/car_raw.json](../Data_Model/car_raw.json)**: Schema de referência
- **[QUICK_REFERENCE.md](../QUICK_REFERENCE.md)**: Comandos rápidos

---

**Última atualização**: 06 de Novembro de 2025
