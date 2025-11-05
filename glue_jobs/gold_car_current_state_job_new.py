"""
AWS Glue ETL Job - Gold Layer: Car Current State (NOVA ESTRUTURA car_raw.json)
============================================================================

Objetivo:
- Ler dados processados da Camada Silver (nova estrutura flattened)
- Aplicar lógica de "Estado Atual" por carChassis
- Enriquecer com KPIs e métricas Gold
- Escrever snapshot consolidado no Gold Bucket

Lógica de Negócio:
- Chave de negócio: car_chassis (carChassis)
- Regra de seleção: current_mileage_km DESC + event_timestamp DESC
- Resultado: 1 registro único por veículo (estado atual)

Nova Estrutura:
- Campos do car_raw.json processados pelo Silver
- KPIs de seguro: insurance_status, insurance_days_expired
- Métricas de eficiência: fuel_efficiency_l_per_100km
- Status de manutenção: oil_status

Características:
- Leitura: Dados Silver flattened 
- Transformação: Window Function + enriquecimento Gold
- Escrita: Overwrite completo (snapshot Gold)
- Saída: Parquet consolidado

Autor: Sistema de Data Lakehouse - Camada Gold
Data: 2025-11-04 (Nova Estrutura car_raw.json)
"""

import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job

from pyspark.sql import functions as F
from pyspark.sql.window import Window
from pyspark.sql.functions import col, to_date, current_date, datediff, when, lit
from datetime import datetime

# ============================================================================
# 1. INICIALIZAÇÃO DO JOB
# ============================================================================

print("\n" + "=" * 80)
print("🥇 AWS GLUE JOB - GOLD LAYER: CAR CURRENT STATE (NOVA ESTRUTURA)")
print("=" * 80)

# Obter parâmetros do Job
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'silver_bucket',
    'silver_path',
    'gold_bucket',
    'gold_path'
])

# Inicializar contextos Spark e Glue
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

print(f"🚀 Job iniciado: {args['JOB_NAME']}")
print(f"📅 Timestamp: {datetime.now().isoformat()}")

# ============================================================================
# 2. LEITURA DOS DADOS SILVER (NOVA ESTRUTURA FLATTENED)
# ============================================================================

print("\n📥 ETAPA 1: Leitura dos dados Silver processados...")

# Definir caminho Silver
silver_path = f"s3://{args['silver_bucket']}/{args['silver_path']}"
print(f"   📍 Origem Silver: {silver_path}")

# Ler dados Silver diretamente do S3 (Parquet)
df_silver = spark.read.parquet(silver_path)

# Contar registros Silver
silver_count = df_silver.count()
print(f"   ✅ Registros encontrados: {silver_count}")

if silver_count == 0:
    print("   ℹ️  Nenhum dado na camada Silver. Finalizando job.")
    job.commit()
    sys.exit(0)

# Mostrar schema Silver
print("\n   📊 Schema Silver (flattened):")
df_silver.printSchema()

# Mostrar exemplo de dados Silver
print(f"\n   🔍 Exemplo de dados Silver:")
df_silver.select(
    "event_id", "car_chassis", "current_mileage_km", 
    "insurance_status", "manufacturer", "model"
).show(3, truncate=False)

# ============================================================================
# 3. CONSOLIDAÇÃO POR VEÍCULO (ESTADO ATUAL)
# ============================================================================

print("\n🎯 ETAPA 2: Consolidação por veículo (estado atual)...")

# Window function para ranking por quilometragem e timestamp
window_spec = Window.partitionBy("car_chassis").orderBy(
    F.desc("current_mileage_km"), 
    F.desc("event_timestamp")
)

# Aplicar ranking
df_ranked = df_silver.withColumn(
    "rank_current_state",
    F.row_number().over(window_spec)
)

# Filtrar apenas o estado mais atual (rank = 1)
df_current_state = df_ranked.filter(F.col("rank_current_state") == 1).drop("rank_current_state")

# Verificar consolidação
unique_vehicles = df_current_state.select("car_chassis").distinct().count()
total_records = df_current_state.count()

print(f"   📊 Veículos únicos: {unique_vehicles}")
print(f"   📊 Total de registros: {total_records}")

if unique_vehicles == total_records:
    print("   ✅ Consolidação OK: 1 registro por veículo")
else:
    print("   ⚠️  Atenção: Múltiplos registros detectados")

# ============================================================================
# 4. ENRIQUECIMENTO GOLD LAYER (KPIS E MÉTRICAS AVANÇADAS)
# ============================================================================

print("\n📈 ETAPA 3: Aplicando enriquecimento Gold Layer...")

# Enriquecer com KPIs Gold
df_gold_enriched = df_current_state.select(
    # Campos de identificação
    F.col("event_id").alias("latest_event_id"),
    F.col("car_chassis"),
    F.col("event_timestamp").alias("last_update_timestamp"),
    F.col("processing_timestamp"),
    
    # Informações do veículo
    F.col("manufacturer"),
    F.col("model"), 
    F.col("year"),
    F.col("model_year"),
    F.col("fuel_type"),
    F.col("fuel_capacity_liters"),
    F.col("color"),
    
    # Estado atual de telemetria
    F.col("current_mileage_km"),
    F.col("fuel_available_liters"),
    F.col("engine_temp_celsius"),
    F.col("oil_temp_celsius"),
    F.col("battery_charge_percentage"),
    F.col("oil_life_percentage"),
    F.col("oil_status"),
    
    # Pressão dos pneus
    F.col("tire_pressure_front_left_psi"),
    F.col("tire_pressure_front_right_psi"),
    F.col("tire_pressure_rear_left_psi"),
    F.col("tire_pressure_rear_right_psi"),
    
    # KPIs de seguro (mantendo compatibilidade)
    F.col("insurance_provider"),
    F.col("insurance_policy_number"),
    F.col("insurance_valid_until"),
    F.col("insurance_status"),
    F.col("insurance_days_expired"),
    
    # Informações de manutenção
    F.col("last_service_date"),
    F.col("last_service_mileage"),
    
    # Informações de aluguel
    F.col("rental_agreement_id"),
    F.col("rental_customer_id"),
    F.col("rental_start_date"),
    
    # Dados da última viagem
    F.col("trip_start_timestamp"),
    F.col("trip_end_timestamp"),
    F.col("trip_distance_km"),
    F.col("trip_duration_minutes"),
    F.col("trip_fuel_consumed_liters"),
    F.col("trip_max_speed_kmh"),
    F.col("fuel_efficiency_l_per_100km"),
    F.col("average_speed_calculated_kmh"),
    
    # === NOVOS KPIS GOLD LAYER ===
    
    # KPI de nível de combustível
    F.round((F.col("fuel_available_liters") / F.col("fuel_capacity_liters")) * 100, 1).alias("fuel_level_percentage"),
    
    F.when(F.col("fuel_available_liters") / F.col("fuel_capacity_liters") < 0.15, "CRITICAL")
     .when(F.col("fuel_available_liters") / F.col("fuel_capacity_liters") < 0.30, "LOW")
     .otherwise("OK").alias("fuel_status"),
    
    # KPI de manutenção preventiva
    F.when(F.col("current_mileage_km") - F.col("last_service_mileage") > 10000, "OVERDUE")
     .when(F.col("current_mileage_km") - F.col("last_service_mileage") > 8000, "DUE_SOON")
     .otherwise("OK").alias("maintenance_status"),
    
    F.col("current_mileage_km") - F.col("last_service_mileage").alias("km_since_last_service"),
    
    # KPI de eficiência de bateria
    F.when(F.col("battery_charge_percentage") < 20, "CRITICAL")
     .when(F.col("battery_charge_percentage") < 40, "LOW")
     .otherwise("OK").alias("battery_status"),
    
    # KPI de temperatura do motor
    F.when(F.col("engine_temp_celsius") > 100, "OVERHEATING")
     .when(F.col("engine_temp_celsius") > 95, "HIGH")
     .otherwise("NORMAL").alias("engine_temp_status"),
    
    # KPI médio de pressão dos pneus
    F.round((F.col("tire_pressure_front_left_psi") + F.col("tire_pressure_front_right_psi") + 
             F.col("tire_pressure_rear_left_psi") + F.col("tire_pressure_rear_right_psi")) / 4, 1).alias("avg_tire_pressure_psi"),
    
    # KPI de status geral do veículo
    F.when((F.col("insurance_status") == "VENCIDO") | 
           (F.col("fuel_available_liters") / F.col("fuel_capacity_liters") < 0.15) |
           (F.col("oil_life_percentage") < 20) |
           (F.col("battery_charge_percentage") < 20), "ATTENTION_REQUIRED")
     .otherwise("OPERATIONAL").alias("vehicle_overall_status"),
    
    # Timestamp do processamento Gold
    F.current_timestamp().alias("gold_processing_timestamp")
)

print(f"   ✅ Registros após enriquecimento Gold: {df_gold_enriched.count()}")

# Mostrar KPIs Gold calculados
print("\n   🔍 KPIs Gold Layer calculados:")
df_gold_enriched.select(
    "car_chassis", "manufacturer", "model",
    "fuel_status", "maintenance_status", "battery_status", 
    "vehicle_overall_status", "insurance_status"
).show(3, truncate=False)

# ============================================================================
# 5. GRAVAÇÃO NO GOLD LAYER (OVERWRITE COMPLETO)
# ============================================================================

print("\n💾 ETAPA 4: Gravação no Gold Layer...")

# Preparar dados finais
df_gold_final = df_gold_enriched

gold_path = f"s3://{args['gold_bucket']}/{args['gold_path']}"
print(f"   📍 Destino Gold: {gold_path}")
print(f"   📊 Total de registros a gravar: {df_gold_final.count()}")

# Gravar no Gold Layer (overwrite completo)
df_gold_final.write.mode("overwrite").parquet(gold_path)

print("   ✅ Dados gravados no Gold Layer com sucesso!")

# ============================================================================
# 6. ESTATÍSTICAS FINAIS E RELATÓRIO
# ============================================================================

print("\n📊 RELATÓRIO FINAL GOLD LAYER:")
print("=" * 60)

# Estatísticas finais
final_records = df_gold_final.count()
total_columns = len(df_gold_final.columns)

print(f"📥 Registros Silver (entrada): {silver_count}")
print(f"📤 Registros Gold (saída): {final_records}")
print(f"🎯 Taxa de consolidação: {silver_count}:{final_records}")
print(f"🏗️  Total de campos Gold: {total_columns}")

# Análise de KPIs por status
print(f"\n📈 ANÁLISE DE KPIs GOLD:")
print("=" * 40)

# Status do seguro
print("🛡️  Status de Seguro:")
df_gold_final.groupBy("insurance_status").count().show(truncate=False)

# Status geral do veículo  
print("🚗 Status Geral dos Veículos:")
df_gold_final.groupBy("vehicle_overall_status").count().show(truncate=False)

# Status de combustível
print("⛽ Status de Combustível:")
df_gold_final.groupBy("fuel_status").count().show(truncate=False)

# Mostrar lista de campos Gold
print(f"\n📋 CAMPOS GOLD CRIADOS ({total_columns}):")
print("=" * 50)
for i, col_name in enumerate(df_gold_final.columns, 1):
    print(f"{i:2d}. {col_name}")

# Exemplo final
print(f"\n🔍 EXEMPLO DE DADOS GOLD (ESTADO ATUAL):")
print("=" * 60)
df_gold_final.select(
    "car_chassis", "manufacturer", "model", "current_mileage_km",
    "insurance_status", "insurance_days_expired", 
    "fuel_status", "vehicle_overall_status"
).show(3, truncate=False)

print("\n" + "=" * 80)
print("🎉 GOLD LAYER JOB - CONCLUÍDO COM SUCESSO!")
print(f"🕒 Timestamp de conclusão: {datetime.now().isoformat()}")
print("   Estado atual dos veículos consolidado e enriquecido!")
print("=" * 80)

# Commit do job
job.commit()