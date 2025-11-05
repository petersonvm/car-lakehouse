"""
AWS Glue ETL Job - Silver Layer Consolidation (REFATORADO - car_silver)
======================================================================

REFATORAÇÃO: Renomeação da tabela Silver
De: silver_car_telemetry_new → Para: car_silver

Objetivo:
- Ler dados do Bronze (car_raw.json com event_id, vehicle_static_info, etc)
- Aplicar achatamento das estruturas aninhadas
- Consolidar estado atual por veículo
- Manter KPIs de seguro compatíveis
- Escrever resultado Silver particionado no NOVO CAMINHO: s3://bucket/car_silver/

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
- NOVA LOCALIZAÇÃO: s3://datalake-pipeline-silver-dev/car_silver/

Autor: Sistema de Data Lakehouse - Refatoração  
Data: 2025-11-05 (Refatoração: silver_car_telemetry_new → car_silver)
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

print("\n" + "=" * 80)
print("🥈 AWS GLUE JOB - SILVER LAYER CONSOLIDATION (REFATORADO)")
print("📝 Tabela Destino: car_silver (anteriormente: silver_car_telemetry_new)")
print("=" * 80)

# Obter parâmetros do Job
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'bronze_bucket',
    'bronze_path',
    'silver_bucket',
    'silver_path',         # NOVO: Deve ser "car_silver"
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
print(f"   📥 Bronze: s3://{args['bronze_bucket']}/{args['bronze_path']}")
print(f"   📤 Silver: s3://{args['silver_bucket']}/{args['silver_path']}")  # NOVO CAMINHO
print(f"   🔧 Job Name: {args['JOB_NAME']}")

# ============================================================================
# 2. LEITURA DOS DADOS BRONZE (JSON COMPLEXO)
# ============================================================================

print("\n📖 ETAPA 1: Leitura dos dados Bronze...")

# Ler dados Bronze usando JSON SerDe
try:
    # Caminho completo Bronze
    bronze_path = f"s3://{args['bronze_bucket']}/{args['bronze_path']}"
    print(f"   📍 Origem: {bronze_path}")
    
    # Leitura com schema flexível para JSON aninhado
    df_bronze = spark.read.option("multiline", "true").json(bronze_path)
    
    # Mostrar estrutura lida
    new_records_count = df_bronze.count()
    print(f"   ✅ Registros Bronze lidos: {new_records_count}")
    print(f"   📊 Campos Bronze: {len(df_bronze.columns)}")
    
    if new_records_count == 0:
        print("   ⚠️  AVISO: Nenhum registro encontrado no Bronze!")
        print("   🔄 Encerrando job (sem dados para processar)")
        job.commit()
        sys.exit(0)
        
except Exception as e:
    print(f"   ❌ ERRO na leitura Bronze: {str(e)}")
    raise e

# ============================================================================
# 3. TRANSFORMAÇÃO E ACHATAMENTO (FLATTENING)
# ============================================================================

print("\n🔄 ETAPA 2: Achatamento das estruturas aninhadas...")

# Aplicar achatamento da estrutura JSON complexa
df_silver = df_bronze.select(
    # Campos de identificação principal
    F.col("event_id").alias("event_id"),
    F.to_timestamp(F.col("event_primary_timestamp")).alias("event_timestamp"),
    F.col("carChassis").alias("car_chassis"),
    
    # Vehicle Static Info - Flattened
    F.col("vehicle_static_info.data.Model").alias("model"),
    F.col("vehicle_static_info.data.year").cast("int").alias("year"),
    F.col("vehicle_static_info.data.ModelYear").cast("int").alias("model_year"),
    F.col("vehicle_static_info.data.Manufacturer").alias("manufacturer"),
    F.col("vehicle_static_info.data.gasType").alias("gas_type"),
    F.col("vehicle_static_info.data.fuelCapacityLiters").cast("int").alias("fuel_capacity_liters"),
    F.col("vehicle_static_info.data.color").alias("color"),
    
    # Insurance Info - Flattened
    F.col("vehicle_dynamic_state.insurance_info.data.provider").alias("insurance_provider"),
    F.col("vehicle_dynamic_state.insurance_info.data.policy_number").alias("insurance_policy_number"),
    F.col("vehicle_dynamic_state.insurance_info.data.validUntil").alias("insurance_valid_until"),
    
    # Maintenance Info - Flattened
    F.col("vehicle_dynamic_state.maintenance_info.data.last_service_date").alias("last_service_date"),
    F.col("vehicle_dynamic_state.maintenance_info.data.last_service_mileage").cast("int").alias("last_service_mileage_km"),
    F.col("vehicle_dynamic_state.maintenance_info.data.oil_life_percentage").cast("double").alias("oil_life_percentage"),
    
    # Rental Agreement - Flattened
    F.col("current_rental_agreement.data.agreement_id").alias("rental_agreement_id"),
    F.col("current_rental_agreement.data.customer_id").alias("rental_customer_id"),
    F.col("current_rental_agreement.data.rental_start_date").alias("rental_start_date"),
    
    # Trip Summary - Flattened
    F.col("trip_data.trip_summary.data.tripStartTimestamp").alias("trip_start_timestamp"),
    F.col("trip_data.trip_summary.data.tripEndTimestamp").alias("trip_end_timestamp"),
    F.col("trip_data.trip_summary.data.tripMileage").cast("double").alias("trip_mileage_km"),
    F.col("trip_data.trip_summary.data.tripTimeMinutes").cast("int").alias("trip_time_minutes"),
    F.col("trip_data.trip_summary.data.tripFuelLiters").cast("double").alias("trip_fuel_liters"),
    F.col("trip_data.trip_summary.data.tripMaxSpeedKm").cast("int").alias("trip_max_speed_kmh"),
    
    # Vehicle Telemetry - Flattened
    F.col("trip_data.vehicle_telemetry_snapshot.data.currentMileage").cast("int").alias("current_mileage_km"),
    F.col("trip_data.vehicle_telemetry_snapshot.data.fuelAvailableLiters").cast("double").alias("fuel_available_liters"),
    F.col("trip_data.vehicle_telemetry_snapshot.data.engineTempCelsius").cast("int").alias("engine_temp_celsius"),
    F.col("trip_data.vehicle_telemetry_snapshot.data.oilTempCelsius").cast("int").alias("oil_temp_celsius"),
    F.col("trip_data.vehicle_telemetry_snapshot.data.batteryChargePerc").cast("int").alias("battery_charge_percentage"),
    
    # Tire Pressures - Flattened
    F.col("trip_data.vehicle_telemetry_snapshot.data.tire_pressures_psi.front_left").cast("double").alias("tire_pressure_front_left_psi"),
    F.col("trip_data.vehicle_telemetry_snapshot.data.tire_pressures_psi.front_right").cast("double").alias("tire_pressure_front_right_psi"),
    F.col("trip_data.vehicle_telemetry_snapshot.data.tire_pressures_psi.rear_left").cast("double").alias("tire_pressure_rear_left_psi"),
    F.col("trip_data.vehicle_telemetry_snapshot.data.tire_pressures_psi.rear_right").cast("double").alias("tire_pressure_rear_right_psi")
)

print(f"   ✅ Achatamento concluído!")
print(f"   📊 Campos Silver criados: {len(df_silver.columns)}")

# ============================================================================
# 4. ENRIQUECIMENTO E PARTICIONAMENTO
# ============================================================================

print("\n📊 ETAPA 3: Enriquecimento e particionamento...")

# Adicionar campos de particionamento baseados no event_timestamp
df_silver_enriched = df_silver.withColumn(
    "event_year", F.year(F.col("event_timestamp")).cast("string")
).withColumn(
    "event_month", F.format_string("%02d", F.month(F.col("event_timestamp")))
).withColumn(
    "event_day", F.format_string("%02d", F.dayofmonth(F.col("event_timestamp")))
)

print(f"   ✅ Campos de particionamento adicionados!")
print(f"   📊 Total de campos Silver final: {len(df_silver_enriched.columns)}")

# ============================================================================
# 5. GRAVAÇÃO NO SILVER LAYER (NOVO CAMINHO: car_silver)
# ============================================================================

print("\n💾 ETAPA 4: Gravação no Silver Layer (NOVO CAMINHO)...")

# Preparar dados finais
df_silver_final = df_silver_enriched

print(f"   📊 Total de registros a gravar: {df_silver_final.count()}")
print(f"   📍 Destino Silver NOVO: s3://{args['silver_bucket']}/{args['silver_path']}")
print(f"   🔄 MUDANÇA: Anteriormente era 'silver_car_telemetry_new', agora é '{args['silver_path']}'")

# Converter para DynamicFrame para gravação
dynamic_frame_silver = DynamicFrame.fromDF(df_silver_final, glueContext, "dynamic_frame_silver")

# Gravar no Silver (particionado por data do evento) - NOVO CAMINHO
glueContext.write_dynamic_frame.from_options(
    frame=dynamic_frame_silver,
    connection_type="s3",
    connection_options={
        "path": f"s3://{args['silver_bucket']}/{args['silver_path']}",  # CAMINHO ATUALIZADO
        "partitionKeys": ["event_year", "event_month", "event_day"]
    },
    format="glueparquet",
    format_options={
        "compression": "snappy"
    },
    transformation_ctx="datasink_silver_refactored"
)

print("   ✅ Dados gravados no Silver Layer com sucesso!")
print(f"   📁 Nova localização: s3://{args['silver_bucket']}/{args['silver_path']}")

# ============================================================================
# 6. ESTATÍSTICAS FINAIS E ENCERRAMENTO
# ============================================================================

print("\n📊 ESTATÍSTICAS FINAIS:")
print(f"   📥 Registros lidos do Bronze: {new_records_count}")
print(f"   📤 Registros gravados no Silver: {df_silver_final.count()}")
print(f"   🎯 Campos Silver total: {len(df_silver_final.columns)}")
print(f"   📍 Nova localização: s3://{args['silver_bucket']}/{args['silver_path']}")

# Mostrar campos Silver criados
print(f"\n   📋 Campos Silver criados ({len(df_silver_final.columns)}):")
for i, col_name in enumerate(df_silver_final.columns, 1):
    print(f"      {i:2d}. {col_name}")

print("\n" + "=" * 80)
print("🎉 Silver Consolidation Job - REFATORAÇÃO CONCLUÍDA COM SUCESSO!")
print(f"📝 Tabela Silver renomeada para: {args['silver_path']}")
print(f"🕒 Timestamp final: {datetime.now().isoformat()}")
print("=" * 80)

# Commit do job
job.commit()