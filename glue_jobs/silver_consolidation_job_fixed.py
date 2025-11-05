"""
AWS Glue Job: Silver Layer Consolidation (REFATORADO para car_silver)
====================================================================

Este job consolida dados da camada Bronze estruturada para Silver,
aplicando as transformações necessárias para análise.

Versão: Refatorada
Tabela Destino: car_silver (anteriormente: silver_car_telemetry_new)
Fonte: car_bronze_structured (dados já flattened)

Mudanças principais:
- Lê da tabela Bronze estruturada (via Glue Catalog)
- Grava em s3://{silver_bucket}/{silver_path} (car_silver)
- Remove lógica de flattening (já feito na Bronze)
- Mantém transformações e validações

"""

import sys
from datetime import datetime
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
import pyspark.sql.functions as F
from pyspark.sql.types import *

print("\n" + "=" * 80)
print("🥈 AWS GLUE JOB - SILVER LAYER CONSOLIDATION (REFATORADO)")
print("📝 Tabela Destino: car_silver (anteriormente: silver_car_telemetry_new)")
print("📊 Fonte: car_bronze_structured (dados já flattened)")
print("=" * 80)

# Obter parâmetros do Job
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
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
print(f"   📊 Fonte: {args['database_name']}.car_bronze_structured")
print(f"   📤 Silver: s3://{args['silver_bucket']}/{args['silver_path']}")  # NOVO CAMINHO
print(f"   🔧 Job Name: {args['JOB_NAME']}")

# ============================================================================
# 2. LEITURA DOS DADOS BRONZE ESTRUTURADA
# ============================================================================

print("\n📖 ETAPA 1: Leitura dos dados Bronze estruturada...")

try:
    # Ler dados da tabela Bronze estruturada (já flattened)
    bronze_dynamic_frame = glueContext.create_dynamic_frame.from_catalog(
        database=args['database_name'],
        table_name="car_bronze_structured"
    )
    
    # Converter para DataFrame
    df_bronze = bronze_dynamic_frame.toDF()
    
    # Mostrar estatísticas
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
# 3. TRANSFORMAÇÃO E MAPEAMENTO BRONZE → SILVER
# ============================================================================

print("\n🔄 ETAPA 2: Mapeamento dos campos Bronze estruturada → Silver...")

# Mapear campos da tabela Bronze estruturada para Silver
# (Não precisa de flattening pois Bronze já tem os dados estruturados)
df_silver = df_bronze.select(
    # Campos de identificação principal
    F.col("event_id").alias("event_id"),
    F.to_timestamp(F.col("event_primary_timestamp")).alias("event_timestamp"),
    F.col("car_chassis").alias("car_chassis"),
    
    # Vehicle Static Info - já flattened na Bronze
    F.col("manufacturer").alias("manufacturer"),
    F.col("model").alias("model"),
    F.col("year").cast("int").alias("year"),
    F.col("model_year").cast("int").alias("model_year"),
    F.col("gas_type").alias("gas_type"),
    F.col("fuel_capacity_liters").cast("int").alias("fuel_capacity_liters"),
    F.col("color").alias("color"),
    
    # Insurance Info - já flattened na Bronze
    F.col("insurance_provider").alias("insurance_provider"),
    F.col("insurance_policy_number").alias("insurance_policy_number"),
    F.col("insurance_valid_until").alias("insurance_valid_until"),
    
    # Maintenance Info - já flattened na Bronze
    F.col("last_service_date").alias("last_service_date"),
    F.col("last_service_mileage").cast("int").alias("last_service_mileage_km"),
    F.col("oil_life_percentage").cast("double").alias("oil_life_percentage"),
    
    # Rental Info - já flattened na Bronze
    F.col("rental_agreement_id").alias("rental_agreement_id"),
    F.col("rental_customer_id").alias("rental_customer_id"),
    F.col("rental_start_date").alias("rental_start_date"),
    
    # Trip Summary - já flattened na Bronze
    F.col("trip_start_timestamp").alias("trip_start_timestamp"),
    F.col("trip_end_timestamp").alias("trip_end_timestamp"),
    F.col("trip_mileage").cast("double").alias("trip_mileage_km"),
    F.col("trip_time_minutes").cast("int").alias("trip_time_minutes"),
    F.col("trip_fuel_liters").cast("double").alias("trip_fuel_liters"),
    F.col("trip_max_speed_km").cast("int").alias("trip_max_speed_kmh"),
    
    # Telemetry Info - já flattened na Bronze
    F.col("current_mileage").cast("int").alias("current_mileage_km"),
    F.col("fuel_available_liters").cast("double").alias("fuel_available_liters"),
    F.col("engine_temp_celsius").cast("int").alias("engine_temp_celsius"),
    F.col("oil_temp_celsius").cast("int").alias("oil_temp_celsius"),
    F.col("battery_charge_percentage").cast("int").alias("battery_charge_percentage"),
    F.col("tire_pressure_front_left").cast("double").alias("tire_pressure_front_left_psi"),
    F.col("tire_pressure_front_right").cast("double").alias("tire_pressure_front_right_psi"),
    F.col("tire_pressure_rear_left").cast("double").alias("tire_pressure_rear_left_psi"),
    F.col("tire_pressure_rear_right").cast("double").alias("tire_pressure_rear_right_psi")
)

print(f"   ✅ Campos mapeados Silver: {len(df_silver.columns)}")

# ============================================================================
# 4. ADIÇÃO DE PARTIÇÕES TEMPORAIS
# ============================================================================

print("\n📅 ETAPA 3: Adicionando partições temporais...")

# Adicionar partições baseadas no timestamp do evento
df_silver_partitioned = df_silver.withColumn(
    "event_year", F.year(F.col("event_timestamp")).cast("string")
).withColumn(
    "event_month", F.format_string("%02d", F.month(F.col("event_timestamp")))
).withColumn(
    "event_day", F.format_string("%02d", F.dayofmonth(F.col("event_timestamp")))
)

print(f"   ✅ Partições adicionadas: event_year, event_month, event_day")

# ============================================================================
# 5. VALIDAÇÕES E TRANSFORMAÇÕES FINAIS
# ============================================================================

print("\n✅ ETAPA 4: Validações finais...")

# Filtrar registros com dados válidos
df_silver_clean = df_silver_partitioned.filter(
    F.col("event_id").isNotNull() &
    F.col("car_chassis").isNotNull() &
    F.col("event_timestamp").isNotNull()
)

valid_records_count = df_silver_clean.count()
print(f"   ✅ Registros válidos: {valid_records_count}")

if valid_records_count == 0:
    print("   ⚠️  AVISO: Nenhum registro válido após filtros!")
    print("   🔄 Encerrando job (dados não válidos)")
    job.commit()
    sys.exit(0)

# ============================================================================
# 6. GRAVAÇÃO NA CAMADA SILVER (NOVO CAMINHO)
# ============================================================================

print("\n💾 ETAPA 5: Gravando dados na camada Silver...")

# Caminho destino (REFATORADO: car_silver)
silver_path = f"s3://{args['silver_bucket']}/{args['silver_path']}"
print(f"   📍 Destino: {silver_path}")

try:
    # Gravar dados particionados
    df_silver_clean.write \
        .mode("append") \
        .partitionBy("event_year", "event_month", "event_day") \
        .option("compression", "snappy") \
        .parquet(silver_path)
    
    print(f"   ✅ Dados gravados com sucesso!")
    print(f"   📊 Registros processados: {valid_records_count}")
    print(f"   📁 Localização: {silver_path}")
    
except Exception as e:
    print(f"   ❌ ERRO na gravação Silver: {str(e)}")
    raise e

# ============================================================================
# 7. FINALIZAÇÃO
# ============================================================================

print("\n🎉 ETAPA FINAL: Job concluído com sucesso!")

# Estatísticas finais
print(f"\n📈 ESTATÍSTICAS DO PROCESSAMENTO:")
print(f"   📥 Registros Bronze lidos: {new_records_count}")
print(f"   ✅ Registros Silver válidos: {valid_records_count}")
print(f"   📊 Taxa de aproveitamento: {(valid_records_count/new_records_count)*100:.1f}%")
print(f"   🗃️  Destino: car_silver (REFATORADO)")

# Commit do job
job.commit()

print("\n" + "=" * 80)
print("✅ JOB SILVER CONSOLIDATION (REFATORADO) - FINALIZADO COM SUCESSO!")
print("=" * 80)