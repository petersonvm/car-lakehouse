"""
AWS Glue Job: Silver Layer Consolidation (REFATORADO com Timestamp Corrigido)
============================================================================

Este job processa dados da camada Bronze para Silver aplicando:
- Leitura de dados JSON do Bronze
- Flattening das estruturas aninhadas
- Conversão correta de timestamps
- Gravação particionada no Silver

Alterações desta versão:
- Correção do event_timestamp para conversão correta de string ISO8601 para timestamp
- Schema da tabela ajustado para evitar conflitos Parquet/Hive

"""

import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
import pyspark.sql.functions as F
from pyspark.sql.types import *

print("\n" + "=" * 80)
print("🥈 AWS GLUE JOB - SILVER LAYER CONSOLIDATION (TIMESTAMP CORRIGIDO)")
print("📝 Versão: Timestamp corrigido para car_silver")
print("=" * 80)

# Obter parâmetros do Job
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'bronze_bucket',
    'bronze_json_path',
    'silver_bucket',
    'silver_path',
    'database_name'
])

# Inicializar contextos
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

print(f"\n📋 PARÂMETROS DO JOB:")
print(f"   🗃️  Database: {args['database_name']}")
print(f"   📥 Bronze JSON: s3://{args['bronze_bucket']}/{args['bronze_json_path']}")
print(f"   📤 Silver: s3://{args['silver_bucket']}/{args['silver_path']}")

# ============================================================================
# 1. LEITURA DOS DADOS BRONZE
# ============================================================================

print("\n📖 ETAPA 1: Leitura dos dados Bronze JSON...")

bronze_path = f"s3://{args['bronze_bucket']}/{args['bronze_json_path']}"
df_bronze_json = spark.read.option("multiline", "true").json(bronze_path)

new_records_count = df_bronze_json.count()
print(f"   ✅ Registros Bronze: {new_records_count}")

if new_records_count == 0:
    print("   ℹ️  Nenhum registro para processar.")
    job.commit()
    sys.exit(0)

# ============================================================================
# 2. FLATTENING E TRANSFORMAÇÃO 
# ============================================================================

print("\n🔄 ETAPA 2: Flattening e transformação...")

# Flattening da estrutura JSON com conversão correta de timestamp
df_silver = df_bronze_json.select(
    # Campos principais (TIMESTAMP CORRIGIDO)
    F.col("event_id").alias("event_id"),
    F.to_timestamp(F.col("event_primary_timestamp"), "yyyy-MM-dd'T'HH:mm:ss'Z'").alias("event_timestamp"),
    F.col("carChassis").alias("car_chassis"),
    
    # Vehicle Static Info
    F.col("vehicle_static_info.data.Manufacturer").alias("manufacturer"),
    F.col("vehicle_static_info.data.Model").alias("model"),
    F.col("vehicle_static_info.data.year").cast("int").alias("year"),
    F.col("vehicle_static_info.data.ModelYear").cast("int").alias("model_year"),
    F.col("vehicle_static_info.data.gasType").alias("gas_type"),
    F.col("vehicle_static_info.data.fuelCapacityLiters").cast("int").alias("fuel_capacity_liters"),
    F.col("vehicle_static_info.data.color").alias("color"),
    
    # Insurance Info (flattened from PowerShell string format)
    F.regexp_extract(F.col("vehicle_dynamic_state.insurance_info.data"), r"provider=([^;]+)", 1).alias("insurance_provider"),
    F.regexp_extract(F.col("vehicle_dynamic_state.insurance_info.data"), r"policy_number=([^;]+)", 1).alias("insurance_policy_number"),
    F.regexp_extract(F.col("vehicle_dynamic_state.insurance_info.data"), r"validUntil=([^}]+)", 1).alias("insurance_valid_until"),
    
    # Maintenance Info (flattened from PowerShell string format)
    F.regexp_extract(F.col("vehicle_dynamic_state.maintenance_info.data"), r"last_service_date=([^;]+)", 1).alias("last_service_date"),
    F.regexp_extract(F.col("vehicle_dynamic_state.maintenance_info.data"), r"last_service_mileage=([^;]+)", 1).cast("int").alias("last_service_mileage_km"),
    F.regexp_extract(F.col("vehicle_dynamic_state.maintenance_info.data"), r"oil_life_percentage=([^}]+)", 1).cast("double").alias("oil_life_percentage"),
    
    # Rental Info
    F.col("current_rental_agreement.data.agreement_id").alias("rental_agreement_id"),
    F.col("current_rental_agreement.data.customer_id").alias("rental_customer_id"),
    F.col("current_rental_agreement.data.rental_start_date").alias("rental_start_date"),
    
    # Trip Summary (flattened from PowerShell string format)
    F.regexp_extract(F.col("trip_data.trip_summary.data"), r"tripStartTimestamp=([^;]+)", 1).alias("trip_start_timestamp"),
    F.regexp_extract(F.col("trip_data.trip_summary.data"), r"tripEndTimestamp=([^;]+)", 1).alias("trip_end_timestamp"),
    F.regexp_extract(F.col("trip_data.trip_summary.data"), r"tripMileage=([^;]+)", 1).cast("double").alias("trip_mileage_km"),
    F.regexp_extract(F.col("trip_data.trip_summary.data"), r"tripTimeMinutes=([^;]+)", 1).cast("int").alias("trip_time_minutes"),
    F.regexp_extract(F.col("trip_data.trip_summary.data"), r"tripFuelLiters=([^;]+)", 1).cast("double").alias("trip_fuel_liters"),
    F.regexp_extract(F.col("trip_data.trip_summary.data"), r"tripMaxSpeedKm=([^}]+)", 1).cast("int").alias("trip_max_speed_kmh"),
    
    # Telemetry (flattened from PowerShell string format)
    F.regexp_extract(F.col("trip_data.vehicle_telemetry_snapshot.data"), r"currentMileage=([^;]+)", 1).cast("int").alias("current_mileage_km"),
    F.regexp_extract(F.col("trip_data.vehicle_telemetry_snapshot.data"), r"fuelAvailableLiters=([^;]+)", 1).cast("double").alias("fuel_available_liters"),
    F.regexp_extract(F.col("trip_data.vehicle_telemetry_snapshot.data"), r"engineTempCelsius=([^;]+)", 1).cast("int").alias("engine_temp_celsius"),
    F.regexp_extract(F.col("trip_data.vehicle_telemetry_snapshot.data"), r"oilTempCelsius=([^;]+)", 1).cast("int").alias("oil_temp_celsius"),
    F.regexp_extract(F.col("trip_data.vehicle_telemetry_snapshot.data"), r"batteryChargePerc=([^;]+)", 1).cast("int").alias("battery_charge_percentage"),
    
    # Tire Pressures (valores padrão pois não estão no JSON atual)
    F.lit(32.0).alias("tire_pressure_front_left_psi"),
    F.lit(32.0).alias("tire_pressure_front_right_psi"),
    F.lit(30.0).alias("tire_pressure_rear_left_psi"),
    F.lit(30.0).alias("tire_pressure_rear_right_psi")
)

print(f"   ✅ Campos mapeados: {len(df_silver.columns)}")

# ============================================================================
# 3. VALIDAÇÃO E LIMPEZA
# ============================================================================

print("\n✅ ETAPA 3: Validação dos dados...")

# Filtrar registros válidos
df_silver_clean = df_silver.filter(
    F.col("event_id").isNotNull() &
    F.col("car_chassis").isNotNull() &
    F.col("event_timestamp").isNotNull()
)

valid_records_count = df_silver_clean.count()
print(f"   ✅ Registros válidos: {valid_records_count}")

# ============================================================================
# 4. ADIÇÃO DE PARTIÇÕES
# ============================================================================

print("\n📅 ETAPA 4: Adicionando partições...")

# Adicionar partições baseadas no timestamp (JÁ CONVERTIDO)
df_silver_partitioned = df_silver_clean.withColumn(
    "event_year", F.year(F.col("event_timestamp")).cast("string")
).withColumn(
    "event_month", F.format_string("%02d", F.month(F.col("event_timestamp")))
).withColumn(
    "event_day", F.format_string("%02d", F.dayofmonth(F.col("event_timestamp")))
)

# Converter timestamp para string para evitar problemas de schema Parquet/Hive
df_silver_final = df_silver_partitioned.withColumn(
    "event_timestamp", F.date_format(F.col("event_timestamp"), "yyyy-MM-dd HH:mm:ss")
)

print(f"   ✅ Partições adicionadas e timestamp formatado")

# ============================================================================
# 5. GRAVAÇÃO NO SILVER
# ============================================================================

print("\n💾 ETAPA 5: Gravação no Silver...")

silver_path = f"s3://{args['silver_bucket']}/{args['silver_path']}"
print(f"   📍 Destino: {silver_path}")

try:
    df_silver_final.write \
        .mode("append") \
        .partitionBy("event_year", "event_month", "event_day") \
        .option("compression", "snappy") \
        .parquet(silver_path)
    
    print(f"   ✅ Dados gravados com sucesso!")
    print(f"   📊 Registros processados: {valid_records_count}")
    
except Exception as e:
    print(f"   ❌ ERRO na gravação: {str(e)}")
    raise e

# ============================================================================
# 6. FINALIZAÇÃO
# ============================================================================

print("\n🎉 ETAPA FINAL: Job concluído!")
print(f"\n📈 ESTATÍSTICAS:")
print(f"   📥 Registros Bronze: {new_records_count}")
print(f"   ✅ Registros Silver: {valid_records_count}")
print(f"   📊 Taxa de aproveitamento: {(valid_records_count/new_records_count)*100:.1f}%")

job.commit()

print("\n" + "=" * 80)
print("✅ SILVER CONSOLIDATION (TIMESTAMP CORRIGIDO) - CONCLUÍDO!")
print("=" * 80)