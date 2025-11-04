"""
AWS Glue ETL Job - Silver Layer Consolidation (REFATORADO)
===========================================================

Objetivo:
- Ler dados novos do Bronze (Parquet com múltiplas estruturas aninhadas)
- Aplicar achatamento (flatten) de structs complexos
- Consolidar estado atual por veículo (current state)
- Enriquecer com KPIs de seguro
- Escrever apenas partições afetadas (Dynamic Partition Overwrite)

Nova Estrutura Bronze:
- Múltiplos timestamps de extração
- Estruturas aninhadas (vehicle_static_info, vehicle_dynamic_state, trip_data)
- Dados distribuídos em data.* de cada struct

Lógica de Consolidação:
- Chave de negócio: carChassis 
- Regra de precedência: current_mileage DESC (estado mais atual)
- Resultado: 1 registro único por carChassis (estado atual)

Autor: Sistema de Data Lakehouse
Data: 2025-11-04 (Refatoração)
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
from pyspark.sql.types import TimestampType, DateType, DoubleType
from datetime import datetime

# ============================================================================
# 1. INICIALIZAÇÃO DO JOB
# ============================================================================

# Obter parâmetros do Job
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'bronze_database',
    'bronze_table',
    'silver_database',
    'silver_table',
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

# Configurar Spark para usar parser de datas LEGACY (compatível com Spark 2.x)
# Necessário para reconhecer formato 'EEE, dd MMM yyyy HH:mm:ss'
spark.conf.set("spark.sql.legacy.timeParserPolicy", "LEGACY")

print("=" * 80)
print(f"🚀 Job iniciado: {args['JOB_NAME']}")
print(f"📅 Timestamp: {datetime.now().isoformat()}")
print("=" * 80)

# ============================================================================
# 2. LEITURA DOS DADOS NOVOS DO BRONZE (ESTRUTURA ANINHADA)
# ============================================================================

print("\n📥 ETAPA 1: Leitura de dados novos do Bronze (Estrutura Aninhada)...")
print(f"   Database: {args['bronze_database']}")
print(f"   Table: {args['bronze_table']}")

# Ler dados do Bronze usando Glue Data Catalog com Bookmarks
# transformation_ctx é CRUCIAL para rastrear o que já foi processado
bronze_dynamic_frame = glueContext.create_dynamic_frame.from_catalog(
    database=args['bronze_database'],
    table_name=args['bronze_table'],
    transformation_ctx="bronze_source"  # Bookmark tracking
)

# Converter para Spark DataFrame
df_bronze_nested = bronze_dynamic_frame.toDF()

# Contar registros novos
new_records_count = df_bronze_nested.count()
print(f"   ✅ Registros novos encontrados: {new_records_count}")

# Mostrar schema do Bronze (aninhado complexo)
print("\n   📊 Schema Bronze (com múltiplos structs aninhados):")
df_bronze_nested.printSchema()

if new_records_count == 0:
    print("   ℹ️  Nenhum registro novo para processar. Job continuará para manter bookmarks atualizados.")
else:
    print(f"   🔍 Exemplo de dados Bronze aninhados:")
    df_bronze_nested.select("event_id", "carChassis", "event_primary_timestamp").show(2, truncate=False)

# ============================================================================
# 3. ACHATAMENTO (FLATTENING) DA ESTRUTURA ANINHADA COMPLEXA
# ============================================================================

print("\n🔄 ETAPA 2: Achatamento de estruturas aninhadas complexas...")

if new_records_count > 0:
    
    # ----------------------------------------------------------------------------
    # 3.1 ACHATAMENTO PRINCIPAL - Extrair dados dos structs aninhados
    # ----------------------------------------------------------------------------
    
    print("   🔹 1/4: Achatando múltiplos structs aninhados...")
    
    # Achatamento completo: extrair campos 'data' de cada struct
    df_flattened = df_bronze_nested.select(
        # Campos principais do evento
        F.col("event_id"),
        F.col("carChassis"),
        F.to_timestamp(F.col("event_primary_timestamp")).alias("event_timestamp"),
        F.col("processing_timestamp"),
        
        # Vehicle Static Info - achatar data.*
        F.col("vehicle_static_info.data.Model").alias("vehicle_model"),
        F.col("vehicle_static_info.data.year").alias("vehicle_year"),
        F.col("vehicle_static_info.data.ModelYear").alias("vehicle_model_year"),
        F.col("vehicle_static_info.data.Manufacturer").alias("vehicle_manufacturer"),
        F.col("vehicle_static_info.data.gasType").alias("vehicle_gas_type"),
        F.col("vehicle_static_info.data.fuelCapacityLiters").alias("vehicle_fuel_capacity_liters"),
        F.col("vehicle_static_info.data.color").alias("vehicle_color"),
        
        # Vehicle Dynamic State - Insurance Info
        F.col("vehicle_dynamic_state.insurance_info.data.provider").alias("insurance_provider"),
        F.col("vehicle_dynamic_state.insurance_info.data.policy_number").alias("insurance_policy_number"),
        F.to_date(F.col("vehicle_dynamic_state.insurance_info.data.validUntil"), "yyyy-MM-dd").alias("insurance_valid_until"),
        
        # Vehicle Dynamic State - Maintenance Info
        F.to_date(F.col("vehicle_dynamic_state.maintenance_info.data.last_service_date"), "yyyy-MM-dd").alias("maintenance_last_service_date"),
        F.col("vehicle_dynamic_state.maintenance_info.data.last_service_mileage").alias("maintenance_last_service_mileage"),
        F.col("vehicle_dynamic_state.maintenance_info.data.oil_life_percentage").alias("maintenance_oil_life_percentage"),
        
        # Current Rental Agreement
        F.col("current_rental_agreement.data.agreement_id").alias("rental_agreement_id"),
        F.col("current_rental_agreement.data.customer_id").alias("rental_customer_id"),
        F.to_timestamp(F.col("current_rental_agreement.data.rental_start_date")).alias("rental_start_date"),
        
        # Trip Data - Trip Summary
        F.to_timestamp(F.col("trip_data.trip_summary.data.tripStartTimestamp")).alias("trip_start_timestamp"),
        F.to_timestamp(F.col("trip_data.trip_summary.data.tripEndTimestamp")).alias("trip_end_timestamp"),
        F.col("trip_data.trip_summary.data.tripMileage").alias("trip_mileage"),
        F.col("trip_data.trip_summary.data.tripTimeMinutes").alias("trip_time_minutes"),
        F.col("trip_data.trip_summary.data.tripFuelLiters").alias("trip_fuel_liters"),
        F.col("trip_data.trip_summary.data.tripMaxSpeedKm").alias("trip_max_speed_km"),
        
        # Trip Data - Vehicle Telemetry Snapshot
        F.col("trip_data.vehicle_telemetry_snapshot.data.currentMileage").alias("current_mileage"),
        F.col("trip_data.vehicle_telemetry_snapshot.data.fuelAvailableLiters").alias("fuel_available_liters"),
        F.col("trip_data.vehicle_telemetry_snapshot.data.engineTempCelsius").alias("engine_temp_celsius"),
        F.col("trip_data.vehicle_telemetry_snapshot.data.oilTempCelsius").alias("oil_temp_celsius"),
        F.col("trip_data.vehicle_telemetry_snapshot.data.batteryChargePerc").alias("battery_charge_percentage"),
        F.col("trip_data.vehicle_telemetry_snapshot.data.tire_pressures_psi.front_left").alias("tire_pressure_front_left"),
        F.col("trip_data.vehicle_telemetry_snapshot.data.tire_pressures_psi.front_right").alias("tire_pressure_front_right"),
        F.col("trip_data.vehicle_telemetry_snapshot.data.tire_pressures_psi.rear_left").alias("tire_pressure_rear_left"),
        F.col("trip_data.vehicle_telemetry_snapshot.data.tire_pressures_psi.rear_right").alias("tire_pressure_rear_right"),
        
        # Partições originais (mantemos para compatibilidade)
        F.col("ingest_year"),
        F.col("ingest_month"),
        F.col("ingest_day")
    )
    
    print(f"      ✅ {len(df_flattened.columns)} colunas após achatamento")
    
    # ----------------------------------------------------------------------------
    # 3.2 LIMPEZA E PADRONIZAÇÃO
    # ----------------------------------------------------------------------------
    
    print("   🔹 2/4: Aplicando limpeza e padronização...")
    
    df_clean = df_flattened.withColumn(
        "vehicle_manufacturer",
        F.initcap(F.col("vehicle_manufacturer"))  # Title Case
    ).withColumn(
        "vehicle_color",
        F.lower(F.col("vehicle_color"))  # lowercase
    ).withColumn(
        "insurance_provider",
        F.initcap(F.col("insurance_provider"))  # Title Case
    )
    
    print("      ✅ Padronização aplicada: manufacturer/provider → Title Case, color → lowercase")
    
    # ----------------------------------------------------------------------------
    # 3.3 ENRIQUECIMENTO - KPIs Calculados
    # ----------------------------------------------------------------------------
    
    print("   🔹 3/4: Calculando KPIs enriquecidos...")
    
    df_enriched = df_clean.withColumn(
        "fuel_level_percentage",
        F.round((F.col("fuel_available_liters") / F.col("vehicle_fuel_capacity_liters")) * 100, 2)
    ).withColumn(
        "trip_avg_speed_km",
        F.when(
            F.col("trip_time_minutes") > 0,
            F.round((F.col("trip_mileage") / F.col("trip_time_minutes")) * 60, 2)
        ).otherwise(0.0)
    ).withColumn(
        "trip_fuel_efficiency_km_per_liter",
        F.when(
            F.col("trip_fuel_liters") > 0,
            F.round(F.col("trip_mileage") / F.col("trip_fuel_liters"), 2)
        ).otherwise(0.0)
    )
    
    print("      ✅ KPIs calculados: fuel_level_percentage, trip_avg_speed_km, fuel_efficiency")
    
    # ----------------------------------------------------------------------------
    # 3.4 KPIs DE SEGURO (INSURANCE KPIs) - MANTIDOS DA VERSÃO ANTERIOR
    # ----------------------------------------------------------------------------
    
    print("   🔹 4/4: Calculando KPIs de Seguro...")
    
    # Calcular dias até vencimento do seguro
    df_with_insurance_kpis = df_enriched.withColumn(
        "insurance_days_to_expiry",
        F.datediff(F.col("insurance_valid_until"), F.current_date())
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
    
    print("      ✅ Insurance KPIs calculados: insurance_status, insurance_days_expired")
    
    # Criar colunas de partição por data do evento
    df_silver_transformed = df_with_insurance_kpis.withColumn(
        "event_year",
        F.year(F.col("event_timestamp")).cast("string")
    ).withColumn(
        "event_month",
        F.lpad(F.month(F.col("event_timestamp")).cast("string"), 2, "0")
    ).withColumn(
        "event_day",
        F.lpad(F.dayofmonth(F.col("event_timestamp")).cast("string"), 2, "0")
    )
    
    print(f"   ✅ Transformação completa! {df_silver_transformed.count()} registros transformados")
    
else:
    # Criar DataFrame vazio com schema esperado para casos sem dados novos
    print("   ℹ️  Criando DataFrame vazio com schema esperado...")
    df_silver_transformed = spark.createDataFrame([], schema=None)  # Schema será inferido na próxima execução


# ============================================================================
# 4. CONSOLIDAÇÃO - CURRENT STATE (Estado Atual por Quilometragem)
# ============================================================================

print("\n� ETAPA 3: Consolidando para estado atual por quilometragem...")

if new_records_count > 0:
    
    # Ler dados existentes na camada Silver
    print("   📖 1/3: Lendo dados existentes da camada Silver...")
    
    try:
        df_silver_existing = glueContext.create_dynamic_frame.from_catalog(
            database=args['silver_database'],
            table_name=args['silver_table']
        ).toDF()
        
        print(f"      ✅ {df_silver_existing.count()} registros existentes encontrados")
    except Exception as e:
        print(f"      ⚠️  Tabela não existe ainda. Será criada: {str(e)}")
        # Criar DataFrame vazio com schema igual aos novos dados
        df_silver_existing = spark.createDataFrame([], schema=None)  # Schema será inferido
    
    # Unir dados novos + existentes
    print("   🔄 2/3: Combinando dados novos e existentes...")
    
    print(f"   Registros existentes: {df_silver_existing.count()}")
    print(f"   Registros novos: {df_silver_transformed.count()}")
    
    # União dos dados (allowMissingColumns para compatibilidade de schema)
    if df_silver_existing.count() > 0:
        df_union = df_silver_transformed.unionByName(df_silver_existing, allowMissingColumns=True)
    else:
        df_union = df_silver_transformed
    
    print(f"   Total após união: {df_union.count()}")
    
    # Aplicar lógica de consolidação: MAIOR QUILOMETRAGEM por chassis (estado mais atual)
    print("   🎯 3/3: Aplicando consolidação de estado atual por quilometragem...")
    
    # Determinar o registro com maior quilometragem para cada carChassis
    # current_mileage como critério principal + event_timestamp como desempate
    
    window_spec = Window.partitionBy("carChassis").orderBy(
        F.col("current_mileage").desc(),
        F.col("event_timestamp").desc()
    )
    
    df_current_state = df_union.withColumn(
        "row_number",
        F.row_number().over(window_spec)
    ).filter(
        F.col("row_number") == 1
    ).drop("row_number")
    
    print(f"   ✅ Estado atual consolidado: {df_current_state.count()} veículos únicos")
    
    # Estatísticas de consolidação
    total_records_before = df_union.count()
    unique_chassis_after = df_current_state.count()
    
    print(f"   📊 Consolidação: {total_records_before} registros → {unique_chassis_after} veículos únicos")
    
    # Mostrar exemplo de consolidação
    print("\n   📋 Exemplo de registros consolidados:")
    df_current_state.select(
        "carChassis",
        "current_mileage",
        "event_timestamp",
        "vehicle_manufacturer",
        "vehicle_model",
        "insurance_status",
        "insurance_days_expired"
    ).show(5, truncate=False)
    
else:
    print("   ℹ️  Nenhum registro novo para consolidar")
    df_current_state = spark.createDataFrame([], schema=None)

# ============================================================================
# 5. ESCRITA NO SILVER (DYNAMIC PARTITION OVERWRITE)
# ============================================================================

print("\n💾 ETAPA 4: Escrevendo dados consolidados no Silver...")

if new_records_count > 0:
    
    print(f"   Bucket: {args['silver_bucket']}")
    print(f"   Path: {args['silver_path']}")
    
    # Escrever no S3 usando Spark DataFrame Writer (suporta Dynamic Partition Overwrite)
    # IMPORTANTE: Usar .write.mode("overwrite") com partitionOverwriteMode=dynamic
    # garante que apenas as partições afetadas sejam sobrescritas (não todo o diretório)
    silver_output_path = f"s3://{args['silver_bucket']}/{args['silver_path']}"
    
    df_current_state.write \
        .mode("overwrite") \
        .partitionBy("event_year", "event_month", "event_day") \
        .format("parquet") \
        .option("compression", "snappy") \
        .save(silver_output_path)
    
    print(f"   ✅ Dados escritos com sucesso!")
    print(f"   📦 Registros finais: {df_current_state.count()}")
    
    # Mostrar partições escritas
    partitions_written = df_current_state.select(
        "event_year", "event_month", "event_day"
    ).distinct().collect()
    
    print(f"\n   📂 Partições escritas ({len(partitions_written)}):")
    for partition in partitions_written:
        print(f"      - event_year={partition.event_year}/event_month={partition.event_month}/event_day={partition.event_day}")

else:
    print("   ℹ️  Nenhum registro novo para processar - Escrita pulada")

# ============================================================================
# 6. FINALIZAÇÃO DO JOB
# ============================================================================

print("\n" + "=" * 80)
print("✅ JOB CONCLUÍDO COM SUCESSO!")
print("=" * 80)
print(f"📊 Resumo:")
print(f"   - Registros Bronze processados: {new_records_count}")
if new_records_count > 0:
    print(f"   - Registros Silver consolidados: {df_current_state.count()}")
    print(f"   - Veículos únicos processados: {df_current_state.count()}")
    print(f"   - Taxa de consolidação: {df_current_state.count()}/{new_records_count} = {round(df_current_state.count()/new_records_count*100, 1)}%")
print(f"   - Timestamp final: {datetime.now().isoformat()}")
print("=" * 80)

# Commit do Job (atualiza bookmarks)
job.commit()

print("\n🎯 Próximos passos:")
print("   1. Executar Glue Crawler no Silver para atualizar catálogo")
print("   2. Consultar dados consolidados no Athena") 
print("   3. Verificar que Insurance KPIs estão funcionando")
print("   4. Validar consolidação por current_mileage DESC")
