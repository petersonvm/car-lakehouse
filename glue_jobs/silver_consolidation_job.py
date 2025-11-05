"""
AWS Glue ETL Job - Silver Layer Consolidation (NOVA ESTRUTURA car_raw.json)
==========================================================================

Objetivo:
- Ler dados do Bronze (car_raw.json com event_id, vehicle_static_info, etc)
- Aplicar achatamento das estruturas aninhadas
- Consolidar estado atual por veículo
- Manter KPIs de seguro compatíveis
- Escrever resultado Silver particionado

Estrutura Bronze Nova (car_raw.json):
- event_id, event_primary_timestamp, carChassis
- vehicle_static_info.data: Model, year, Manufacturer, gasType, etc
- vehicle_dynamic_state.insurance_info.data: provider, policy_number, validUntil
- vehicle_dynamic_state.maintenance_info.data: last_service_date, oil_life_percentage
- current_rental_agreement.data: agreement_id, customer_id, rental_start_date
- trip_data.trip_summary.data: tripStartTimestamp, tripMileage, tripFuelLiters
- trip_data.vehicle_telemetry_snapshot.data: currentMileage, fuelAvailableLiters, etc

Resultado Silver:
- Campos flattened com nomenclatura padronizada
- 1 registro por event_id (sem consolidação por car nesta versão)
- Particionado por data do evento

Autor: Sistema de Data Lakehouse  
Data: 2025-11-04 (Nova Estrutura car_raw.json)
"""

import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.dynamicframe import DynamicFrame

from pyspark.sql import functions as F
from pyspark.sql.window import Window
from pyspark.sql.types import TimestampType, DateType, DoubleType, StructType
from datetime import datetime

# ============================================================================
# 1. INICIALIZAÇÃO DO JOB
# ============================================================================

# Obter parâmetros do Job
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'bronze_bucket',
    'bronze_json_path', 
    'silver_bucket',
    'silver_path'
])

# Inicializar contextos Spark e Glue
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

# Configurar Spark para Dynamic Partition Overwrite
spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")

print("=" * 80)
print(f"🚀 Job iniciado: {args['JOB_NAME']}")
print(f"📅 Timestamp: {datetime.now().isoformat()}")
print("=" * 80)

# ============================================================================
# 2. LEITURA DOS DADOS NOVOS DO BRONZE (NOVA ESTRUTURA car_raw.json)
# ============================================================================

print("\n📥 ETAPA 1: Leitura de dados novos do Bronze (car_raw.json)...")
print(f"   Bronze Bucket: {args['bronze_bucket']}")
print(f"   Bronze JSON Path: {args['bronze_json_path']}")

# Ler dados JSON diretamente do S3
bronze_path = f"s3://{args['bronze_bucket']}/{args['bronze_json_path']}"
df_bronze_json = spark.read.option("multiline", "true").json(bronze_path)

# Contar registros novos
new_records_count = df_bronze_json.count()
print(f"   ✅ Registros encontrados: {new_records_count}")

# Mostrar schema do Bronze (car_raw.json)
print("\n   📊 Schema Bronze (car_raw.json):")
df_bronze_json.printSchema()

if new_records_count == 0:
    print("   ℹ️  Nenhum registro para processar.")
    job.commit()
    sys.exit(0)
else:
    print(f"   🔍 Exemplo de dados Bronze:")
    df_bronze_json.select("event_id", "carChassis").show(2, truncate=False)

# ============================================================================
# 3. ACHATAMENTO (FLATTENING) DA NOVA ESTRUTURA car_raw.json
# ============================================================================

print("\n🔧 ETAPA 2: Achatamento da estrutura car_raw.json...")

# Aplicar flattening da nova estrutura
df_silver_flattened = df_bronze_json.select(
    # Campos principais
    F.col("event_id").alias("event_id"),
    F.to_timestamp(F.col("event_primary_timestamp"), "yyyy-MM-dd'T'HH:mm:ss'Z'").alias("event_timestamp"),
    F.col("processing_timestamp").alias("processing_timestamp"),
    F.col("carChassis").alias("car_chassis"),
    
    # vehicle_static_info.data.*
    F.col("vehicle_static_info.extraction_timestamp").alias("static_info_timestamp"),
    F.col("vehicle_static_info.source_system").alias("static_info_source"),
    F.col("vehicle_static_info.data.Model").alias("model"),
    F.col("vehicle_static_info.data.year").alias("year"),
    F.col("vehicle_static_info.data.ModelYear").alias("model_year"),
    F.col("vehicle_static_info.data.Manufacturer").alias("manufacturer"),
    F.col("vehicle_static_info.data.gasType").alias("fuel_type"),
    F.col("vehicle_static_info.data.fuelCapacityLiters").alias("fuel_capacity_liters"),
    F.col("vehicle_static_info.data.color").alias("color"),
    
    # vehicle_dynamic_state.insurance_info.data.*
    F.col("vehicle_dynamic_state.insurance_info.extraction_timestamp").alias("insurance_timestamp"),
    F.col("vehicle_dynamic_state.insurance_info.source_system").alias("insurance_source"),
    F.col("vehicle_dynamic_state.insurance_info.data.provider").alias("insurance_provider"),
    F.col("vehicle_dynamic_state.insurance_info.data.policy_number").alias("insurance_policy_number"),
    F.col("vehicle_dynamic_state.insurance_info.data.validUntil").alias("insurance_valid_until"),
    
    # vehicle_dynamic_state.maintenance_info.data.*
    F.col("vehicle_dynamic_state.maintenance_info.extraction_timestamp").alias("maintenance_timestamp"),
    F.col("vehicle_dynamic_state.maintenance_info.source_system").alias("maintenance_source"),
    F.col("vehicle_dynamic_state.maintenance_info.data.last_service_date").alias("last_service_date"),
    F.col("vehicle_dynamic_state.maintenance_info.data.last_service_mileage").alias("last_service_mileage"),
    F.col("vehicle_dynamic_state.maintenance_info.data.oil_life_percentage").alias("oil_life_percentage"),
    
    # current_rental_agreement.data.*
    F.col("current_rental_agreement.extraction_timestamp").alias("rental_timestamp"),
    F.col("current_rental_agreement.source_system").alias("rental_source"),
    F.col("current_rental_agreement.data.agreement_id").alias("rental_agreement_id"),
    F.col("current_rental_agreement.data.customer_id").alias("rental_customer_id"),
    F.col("current_rental_agreement.data.rental_start_date").alias("rental_start_date"),
    
    # trip_data.trip_summary.data.*
    F.col("trip_data.trip_summary.extraction_timestamp").alias("trip_summary_timestamp"),
    F.col("trip_data.trip_summary.source_system").alias("trip_summary_source"),
    F.col("trip_data.trip_summary.data.tripStartTimestamp").alias("trip_start_timestamp"),
    F.col("trip_data.trip_summary.data.tripEndTimestamp").alias("trip_end_timestamp"),
    F.col("trip_data.trip_summary.data.tripMileage").alias("trip_distance_km"),
    F.col("trip_data.trip_summary.data.tripTimeMinutes").alias("trip_duration_minutes"),
    F.col("trip_data.trip_summary.data.tripFuelLiters").alias("trip_fuel_consumed_liters"),
    F.col("trip_data.trip_summary.data.tripMaxSpeedKm").alias("trip_max_speed_kmh"),
    
    # trip_data.vehicle_telemetry_snapshot.data.*
    F.col("trip_data.vehicle_telemetry_snapshot.extraction_timestamp").alias("telemetry_timestamp"),
    F.col("trip_data.vehicle_telemetry_snapshot.source_system").alias("telemetry_source"),
    F.col("trip_data.vehicle_telemetry_snapshot.data.currentMileage").alias("current_mileage_km"),
    F.col("trip_data.vehicle_telemetry_snapshot.data.fuelAvailableLiters").alias("fuel_available_liters"),
    F.col("trip_data.vehicle_telemetry_snapshot.data.engineTempCelsius").alias("engine_temp_celsius"),
    F.col("trip_data.vehicle_telemetry_snapshot.data.oilTempCelsius").alias("oil_temp_celsius"),
    F.col("trip_data.vehicle_telemetry_snapshot.data.batteryChargePerc").alias("battery_charge_percentage"),
    
    # trip_data.vehicle_telemetry_snapshot.data.tire_pressures_psi.*
    F.col("trip_data.vehicle_telemetry_snapshot.data.tire_pressures_psi.front_left").alias("tire_pressure_front_left_psi"),
    F.col("trip_data.vehicle_telemetry_snapshot.data.tire_pressures_psi.front_right").alias("tire_pressure_front_right_psi"),
    F.col("trip_data.vehicle_telemetry_snapshot.data.tire_pressures_psi.rear_left").alias("tire_pressure_rear_left_psi"),
    F.col("trip_data.vehicle_telemetry_snapshot.data.tire_pressures_psi.rear_right").alias("tire_pressure_rear_right_psi")
)

# Contar registros após flattening
flattened_count = df_silver_flattened.count()
print(f"   ✅ Registros após flattening: {flattened_count}")

# Mostrar schema Silver flattened
print("\n   📊 Schema Silver (flattened):")
df_silver_flattened.printSchema()

# ============================================================================
# 4. ENRIQUECIMENTO E KPIS DE SEGURO (COMPATÍVEL COM ESTRUTURA NOVA)
# ============================================================================

print("\n� ETAPA 3: Aplicando enriquecimento e KPIs de seguro...")

# Enriquecer com KPIs de seguro para nova estrutura
df_silver_enriched = df_silver_flattened.select(
    "*",
    # KPIs de seguro baseados em insurance_valid_until 
    F.when(F.to_date(F.col("insurance_valid_until"), "yyyy-MM-dd") < F.current_date(), "VENCIDO")
     .otherwise("ATIVO").alias("insurance_status"),
    
    F.when(F.to_date(F.col("insurance_valid_until"), "yyyy-MM-dd") < F.current_date(),
           F.datediff(F.current_date(), F.to_date(F.col("insurance_valid_until"), "yyyy-MM-dd")))
     .otherwise(F.lit(0)).alias("insurance_days_expired"),
    
    # Enriquecimentos adicionais
    F.round(F.col("trip_fuel_consumed_liters") / F.col("trip_distance_km") * 100, 2).alias("fuel_efficiency_l_per_100km"),
    F.round(F.col("trip_distance_km") / (F.col("trip_duration_minutes") / 60), 2).alias("average_speed_calculated_kmh"),
    F.when(F.col("oil_life_percentage") < 20, "CRITICAL")
     .when(F.col("oil_life_percentage") < 50, "LOW")
     .otherwise("OK").alias("oil_status"),
    
    # Particionamento por data do evento  
    F.year(F.col("event_timestamp")).cast("string").alias("event_year"),
    F.format_string("%02d", F.month(F.col("event_timestamp"))).alias("event_month"),
    F.format_string("%02d", F.dayofmonth(F.col("event_timestamp"))).alias("event_day")
)

print(f"   ✅ Registros após enriquecimento: {df_silver_enriched.count()}")

# Mostrar exemplos de KPIs
print("\n   🔍 KPIs de seguro calculados:")
df_silver_enriched.select(
    "event_id", "car_chassis", 
    "insurance_status", "insurance_days_expired",
    "fuel_efficiency_l_per_100km", "oil_status"
).show(3, truncate=False)

# ============================================================================
# 5. GRAVAÇÃO NO SILVER LAYER (PARTICIONADO POR DATA)
# ============================================================================

print("\n💾 ETAPA 4: Gravação no Silver Layer...")

# Preparar dados finais
df_silver_final = df_silver_enriched

print(f"   📊 Total de registros a gravar: {df_silver_final.count()}")
print(f"   📍 Destino Silver: s3://{args['silver_bucket']}/{args['silver_path']}")

# Converter para DynamicFrame para gravação
dynamic_frame_silver = DynamicFrame.fromDF(df_silver_final, glueContext, "dynamic_frame_silver")

# Gravar no Silver (particionado por data do evento)
glueContext.write_dynamic_frame.from_options(
    frame=dynamic_frame_silver,
    connection_type="s3",
    connection_options={
        "path": f"s3://{args['silver_bucket']}/{args['silver_path']}",
        "partitionKeys": ["event_year", "event_month", "event_day"]
    },
    format="glueparquet",
    format_options={
        "compression": "snappy"
    },
    transformation_ctx="datasink_silver"
)

print("   ✅ Dados gravados no Silver Layer com sucesso!")

# ============================================================================
# 6. ESTATÍSTICAS FINAIS E ENCERRAMENTO
# ============================================================================

print("\n📊 ESTATÍSTICAS FINAIS:")
print(f"   📥 Registros lidos do Bronze: {new_records_count}")
print(f"   📤 Registros gravados no Silver: {df_silver_final.count()}")
print(f"   🎯 Campos Silver total: {len(df_silver_final.columns)}")

# Mostrar campos Silver criados
print(f"\n   📋 Campos Silver criados ({len(df_silver_final.columns)}):")
for i, col_name in enumerate(df_silver_final.columns, 1):
    print(f"      {i:2d}. {col_name}")

print("\n" + "=" * 80)
print("🎉 Silver Consolidation Job - CONCLUÍDO COM SUCESSO!")
print(f"🕒 Timestamp final: {datetime.now().isoformat()}")
print("=" * 80)

# Commit do job
job.commit()

# ============================================================================
# 6. ESTATÍSTICAS FINAIS E ENCERRAMENTO
# ============================================================================

print("\n📊 ESTATÍSTICAS FINAIS:")
print(f"   📥 Registros lidos do Bronze: {new_records_count}")
print(f"   📤 Registros gravados no Silver: {df_silver_final.count()}")
print(f"   🎯 Campos Silver total: {len(df_silver_final.columns)}")

# Mostrar campos Silver criados
print(f"\n   📋 Campos Silver criados ({len(df_silver_final.columns)}):")
for i, col_name in enumerate(df_silver_final.columns, 1):
    print(f"      {i:2d}. {col_name}")

print("\n" + "=" * 80)
print("🎉 Silver Consolidation Job - CONCLUÍDO COM SUCESSO!")
print(f"🕒 Timestamp final: {datetime.now().isoformat()}")
print("=" * 80)

# Commit do job
job.commit()
    F.col("insurance.data.provider").alias("insurance_provider"),
    F.col("insurance.data.is_active").alias("insurance_is_active"),
    
    # vehicle_dynamic_state.engine
    F.col("vehicle_dynamic_state.engine.extraction_timestamp").alias("engine_extraction_timestamp"),
    F.col("vehicle_dynamic_state.engine.source_system").alias("engine_source_system"),
    F.col("vehicle_dynamic_state.engine.data.rpm").alias("engine_rpm"),
    F.col("vehicle_dynamic_state.engine.data.temperature").alias("engine_temperature"),
    F.col("vehicle_dynamic_state.engine.data.oil_pressure").alias("engine_oil_pressure"),
    F.col("vehicle_dynamic_state.engine.data.status").alias("engine_status"),
    
    # vehicle_dynamic_state.transmission
    F.col("vehicle_dynamic_state.transmission.extraction_timestamp").alias("transmission_extraction_timestamp"),
    F.col("vehicle_dynamic_state.transmission.source_system").alias("transmission_source_system"),
    F.col("vehicle_dynamic_state.transmission.data.gear").alias("transmission_gear"),
    F.col("vehicle_dynamic_state.transmission.data.mode").alias("transmission_mode"),
    F.col("vehicle_dynamic_state.transmission.data.fluid_temperature").alias("transmission_fluid_temperature"),
    
    # vehicle_dynamic_state.brakes
    F.col("vehicle_dynamic_state.brakes.extraction_timestamp").alias("brakes_extraction_timestamp"),
    F.col("vehicle_dynamic_state.brakes.source_system").alias("brakes_source_system"),
    F.col("vehicle_dynamic_state.brakes.data.pad_wear_front").alias("brakes_pad_wear_front"),
    F.col("vehicle_dynamic_state.brakes.data.pad_wear_rear").alias("brakes_pad_wear_rear"),
    F.col("vehicle_dynamic_state.brakes.data.fluid_level").alias("brakes_fluid_level"),
    
    # service_history
    F.col("service_history.extraction_timestamp").alias("service_extraction_timestamp"),
    F.col("service_history.source_system").alias("service_source_system"),
    F.col("service_history.data.last_service_date").alias("service_last_date"),
    F.col("service_history.data.next_service_due").alias("service_next_due"),
    F.col("service_history.data.mileage_at_last_service").alias("service_mileage_last"),
    F.col("service_history.data.service_type").alias("service_type"),
    
    # trip_data.current_trip
    F.col("trip_data.current_trip.extraction_timestamp").alias("trip_extraction_timestamp"),
    F.col("trip_data.current_trip.source_system").alias("trip_source_system"),
    F.col("trip_data.current_trip.data.trip_id").alias("trip_id"),
    F.col("trip_data.current_trip.data.start_time").alias("trip_start_time"),
    F.col("trip_data.current_trip.data.duration_minutes").alias("trip_duration_minutes"),
    F.col("trip_data.current_trip.data.distance_km").alias("trip_distance_km"),
    F.col("trip_data.current_trip.data.fuel_consumed_liters").alias("trip_fuel_consumed_liters"),
    
    # trip_data.telemetry
    F.col("trip_data.telemetry.extraction_timestamp").alias("telemetry_extraction_timestamp"),
    F.col("trip_data.telemetry.source_system").alias("telemetry_source_system"),
    F.col("trip_data.telemetry.data.speed_kmh").alias("telemetry_speed_kmh"),
    F.col("trip_data.telemetry.data.fuel_level_percent").alias("telemetry_fuel_level_percent"),
    F.col("trip_data.telemetry.data.battery_voltage").alias("telemetry_battery_voltage"),
    F.col("trip_data.telemetry.data.odometer_km").alias("telemetry_odometer_km"),
    
    # trip_data.telemetry.tire_pressures_psi
    F.col("trip_data.telemetry.data.tire_pressures_psi.front_left").alias("tire_pressure_front_left"),
    F.col("trip_data.telemetry.data.tire_pressures_psi.front_right").alias("tire_pressure_front_right"),
    F.col("trip_data.telemetry.data.tire_pressures_psi.rear_left").alias("tire_pressure_rear_left"),
    F.col("trip_data.telemetry.data.tire_pressures_psi.rear_right").alias("tire_pressure_rear_right"),
    
    # trip_data.telemetry.gps
    F.col("trip_data.telemetry.data.gps.latitude").alias("gps_latitude"),
    F.col("trip_data.telemetry.data.gps.longitude").alias("gps_longitude"),
    F.col("trip_data.telemetry.data.gps.altitude").alias("gps_altitude"),
    F.col("trip_data.telemetry.data.gps.heading").alias("gps_heading")
)

print(f"      ✅ {len(df_flattened.columns)} colunas após achatamento")

# ----------------------------------------------------------------------------
# 3.2 LIMPEZA E PADRONIZAÇÃO
# ----------------------------------------------------------------------------

print("   🔹 2/4: Aplicando limpeza e padronização...")

df_clean = df_flattened.withColumn(
    "manufacturer",
    F.initcap(F.col("manufacturer"))  # Title Case
).withColumn(
    "color",
    F.lower(F.col("color"))  # lowercase
).withColumn(
    "insurance_provider",
    F.initcap(F.col("insurance_provider"))  # Title Case
)

print("      ✅ Padronização aplicada: manufacturer/provider → Title Case, color → lowercase")

# ----------------------------------------------------------------------------
# 3.3 CONVERSÃO DE TIPOS E TIMESTAMPS
# ----------------------------------------------------------------------------

print("   🔹 3/4: Convertendo tipos e timestamps...")

# Converter timestamps ISO para timestamp
df_typed = df_clean.withColumn(
    "timestamp",
    F.to_timestamp(F.col("timestamp"), "yyyy-MM-dd'T'HH:mm:ss'Z'")
).withColumn(
    "static_extraction_timestamp",
    F.to_timestamp(F.col("static_extraction_timestamp"), "yyyy-MM-dd'T'HH:mm:ss'Z'")
).withColumn(
    "insurance_extraction_timestamp",
    F.to_timestamp(F.col("insurance_extraction_timestamp"), "yyyy-MM-dd'T'HH:mm:ss'Z'")
).withColumn(
    "engine_extraction_timestamp",
    F.to_timestamp(F.col("engine_extraction_timestamp"), "yyyy-MM-dd'T'HH:mm:ss'Z'")
).withColumn(
    "transmission_extraction_timestamp",
    F.to_timestamp(F.col("transmission_extraction_timestamp"), "yyyy-MM-dd'T'HH:mm:ss'Z'")
).withColumn(
    "brakes_extraction_timestamp",
    F.to_timestamp(F.col("brakes_extraction_timestamp"), "yyyy-MM-dd'T'HH:mm:ss'Z'")
).withColumn(
    "service_extraction_timestamp",
    F.to_timestamp(F.col("service_extraction_timestamp"), "yyyy-MM-dd'T'HH:mm:ss'Z'")
).withColumn(
    "trip_extraction_timestamp",
    F.to_timestamp(F.col("trip_extraction_timestamp"), "yyyy-MM-dd'T'HH:mm:ss'Z'")
).withColumn(
    "telemetry_extraction_timestamp",
    F.to_timestamp(F.col("telemetry_extraction_timestamp"), "yyyy-MM-dd'T'HH:mm:ss'Z'")
).withColumn(
    "trip_start_time",
    F.to_timestamp(F.col("trip_start_time"), "yyyy-MM-dd'T'HH:mm:ss'Z'")
).withColumn(
    "insurance_expiry_date",
    F.to_date(F.col("insurance_expiry_date"), "yyyy-MM-dd")
).withColumn(
    "service_last_date",
    F.to_date(F.col("service_last_date"), "yyyy-MM-dd")
).withColumn(
    "service_next_due",
    F.to_date(F.col("service_next_due"), "yyyy-MM-dd")
)

print("      ✅ Timestamps e datas convertidos")

# ----------------------------------------------------------------------------
# 3.4 ENRIQUECIMENTO - KPIs Calculados (MANTENDO COMPATIBILIDADE)
# ----------------------------------------------------------------------------

print("   🔹 4/4: Calculando KPIs enriquecidos...")

# KPIs de combustível e eficiência
df_enriched = df_typed.withColumn(
    "trip_km_per_liter",
    F.when(
        F.col("trip_fuel_consumed_liters") > 0,
        F.round(F.col("trip_distance_km") / F.col("trip_fuel_consumed_liters"), 2)
    ).otherwise(0.0)
)

# KPIs DE SEGURO (INSURANCE KPIs) - MANTIDOS PARA COMPATIBILIDADE
df_with_insurance_kpis = df_enriched.withColumn(
    "insurance_days_to_expiry",
    F.datediff(F.col("insurance_expiry_date"), F.current_date())
).withColumn(
    "insurance_status",
    F.when(F.col("insurance_days_to_expiry") < 0, "VENCIDO")
     .when(F.col("insurance_days_to_expiry") <= 90, "VENCENDO_EM_90_DIAS")
     .otherwise("ATIVO")
).withColumn(
    "insurance_days_expired",
    F.when(F.col("insurance_days_to_expiry") < 0, F.abs(F.col("insurance_days_to_expiry")))
     .otherwise(0)
)

print("      ✅ KPIs calculados: km_per_liter, insurance_status, insurance_days_expired")

# Criar colunas de partição por data do evento (usando timestamp principal)
df_silver_transformed = df_with_insurance_kpis.withColumn(
    "event_year",
    F.year(F.col("timestamp")).cast("string")
).withColumn(
    "event_month",
    F.lpad(F.month(F.col("timestamp")).cast("string"), 2, "0")
).withColumn(
    "event_day",
    F.lpad(F.dayofmonth(F.col("timestamp")).cast("string"), 2, "0")
)

print(f"      ✅ Total de colunas finais: {len(df_silver_transformed.columns)}")

# ============================================================================
# 4. CONSOLIDAÇÃO DE ESTADO ATUAL
# ============================================================================

print("\n🔄 ETAPA 3: Consolidação de estado atual por veículo...")

# Window para ranking por odômetro (estado mais atual)
window_current_state = Window.partitionBy("car_id").orderBy(F.desc("telemetry_odometer_km"))

# Aplicar ranking e filtrar apenas o registro mais atual por veículo
df_current_state = df_silver_transformed.withColumn(
    "rank",
    F.row_number().over(window_current_state)
).filter(
    F.col("rank") == 1
).drop("rank")

current_vehicles = df_current_state.count()
print(f"   ✅ Veículos com estado atual consolidado: {current_vehicles}")

# Mostrar estatísticas finais
print("\n   📊 Estatísticas do estado atual:")
df_current_state.select("car_id", "manufacturer", "model", "telemetry_odometer_km", "insurance_status").show(5, truncate=False)

# ============================================================================
# 5. ESCRITA NO BUCKET SILVER (DYNAMIC PARTITION OVERWRITE)
# ============================================================================

print("\n💾 ETAPA 4: Escrita no bucket Silver...")

# Caminho de destino no Silver
silver_output_path = f"s3://{args['silver_bucket']}/{args['silver_path']}"
print(f"   Destino Silver: {silver_output_path}")

# Escrever dados no formato Parquet com particionamento dinâmico
df_current_state.write \
    .mode("overwrite") \
    .option("partitionOverwriteMode", "dynamic") \
    .partitionBy("event_year", "event_month", "event_day") \
    .parquet(silver_output_path)

print(f"   ✅ Dados escritos com sucesso!")
print(f"   📊 Partições: {df_current_state.select('event_year', 'event_month', 'event_day').distinct().count()}")

# ============================================================================
# 6. FINALIZAÇÃO
# ============================================================================

print("\n" + "=" * 80)
print("🎉 JOB CONCLUÍDO COM SUCESSO!")
print(f"   📊 Registros processados: {new_records_count}")
print(f"   🚗 Veículos consolidados: {current_vehicles}")
print(f"   📅 Finalizado em: {datetime.now().isoformat()}")
print("=" * 80)

# Commit do job (atualiza bookmarks se aplicável)
job.commit()