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
print(f" Job iniciado: {args['JOB_NAME']}")
print(f" Timestamp: {datetime.now().isoformat()}")
print("=" * 80)

# ============================================================================
# 2. LEITURA DOS DADOS NOVOS DO BRONZE (NOVA ESTRUTURA car_raw.json)
# ============================================================================

print("\n ETAPA 1: Leitura de dados novos do Bronze (car_raw.json)...")
print(f"   Bronze Bucket: {args['bronze_bucket']}")
print(f"   Bronze JSON Path: {args['bronze_json_path']}")

# Ler dados JSON diretamente do S3
bronze_path = f"s3://{args['bronze_bucket']}/{args['bronze_json_path']}"
df_bronze_json = spark.read.option("multiline", "true").json(bronze_path)

# Contar registros novos
new_records_count = df_bronze_json.count()
print(f"    Registros encontrados: {new_records_count}")

# Mostrar schema do Bronze (car_raw.json)
print("\n    Schema Bronze (car_raw.json):")
df_bronze_json.printSchema()

if new_records_count == 0:
    print("   ℹ  Nenhum registro para processar.")
    job.commit()
    sys.exit(0)
else:
    print(f"    Exemplo de dados Bronze:")
    df_bronze_json.select("event_id", "carChassis").show(2, truncate=False)

# ============================================================================
# 3. ACHATAMENTO (FLATTENING) DA NOVA ESTRUTURA car_raw.json
# ============================================================================

print("\n ETAPA 2: Achatamento da estrutura car_raw.json...")

# Aplicar flattening da nova estrutura
df_silver_flattened = df_bronze_json.select(
    # Campos principais
    F.col("event_id").alias("event_id"),
    F.col("event_primary_timestamp").alias("event_timestamp"),
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
print(f"    Registros após flattening: {flattened_count}")

# Mostrar schema Silver flattened
print("\n    Schema Silver (flattened):")
df_silver_flattened.printSchema()

# ============================================================================
# 4. ENRIQUECIMENTO E KPIS DE SEGURO (COMPATÍVEL COM ESTRUTURA NOVA)
# ============================================================================

print("\n ETAPA 3: Aplicando enriquecimento e KPIs de seguro...")

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
    F.year(F.to_timestamp(F.col("event_timestamp"))).alias("event_year"),
    F.month(F.to_timestamp(F.col("event_timestamp"))).alias("event_month"),
    F.dayofmonth(F.to_timestamp(F.col("event_timestamp"))).alias("event_day")
)

print(f"    Registros após enriquecimento: {df_silver_enriched.count()}")

# Mostrar exemplos de KPIs
print("\n    KPIs de seguro calculados:")
df_silver_enriched.select(
    "event_id", "car_chassis", 
    "insurance_status", "insurance_days_expired",
    "fuel_efficiency_l_per_100km", "oil_status"
).show(3, truncate=False)

# ============================================================================
# 5. GRAVAÇÃO NO SILVER LAYER (PARTICIONADO POR DATA)
# ============================================================================

print("\n ETAPA 4: Gravação no Silver Layer...")

# Preparar dados finais
df_silver_final = df_silver_enriched

print(f"    Total de registros a gravar: {df_silver_final.count()}")
print(f"    Destino Silver: s3://{args['silver_bucket']}/{args['silver_path']}")

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

print("    Dados gravados no Silver Layer com sucesso!")

# ============================================================================
# 6. ESTATÍSTICAS FINAIS E ENCERRAMENTO
# ============================================================================

print("\n ESTATÍSTICAS FINAIS:")
print(f"    Registros lidos do Bronze: {new_records_count}")
print(f"    Registros gravados no Silver: {df_silver_final.count()}")
print(f"    Campos Silver total: {len(df_silver_final.columns)}")

# Mostrar campos Silver criados
print(f"\n    Campos Silver criados ({len(df_silver_final.columns)}):")
for i, col_name in enumerate(df_silver_final.columns, 1):
    print(f"      {i:2d}. {col_name}")

print("\n" + "=" * 80)
print(" Silver Consolidation Job - CONCLUÍDO COM SUCESSO!")
print(f" Timestamp final: {datetime.now().isoformat()}")
print("=" * 80)

# Commit do job
job.commit()