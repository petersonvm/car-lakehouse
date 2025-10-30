"""
AWS Glue ETL Job - Silver Layer Consolidation with Upsert
==========================================================

Objetivo:
- Ler dados novos do Bronze (Parquet com structs)
- Aplicar transformações (flatten, cleanse, enrich)
- Consolidar com dados existentes no Silver (Upsert/Deduplicação)
- Escrever apenas partições afetadas (Dynamic Partition Overwrite)

Lógica de Deduplicação:
- Chave de negócio: carChassis + event_year + event_month + event_day
- Regra de precedência: currentMileage DESC (o registro mais recente)
- Resultado: 1 registro único por combinação de chave

Autor: Sistema de Data Lakehouse
Data: 2025-10-30
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
# 2. LEITURA DOS DADOS NOVOS DO BRONZE (COM BOOKMARKS)
# ============================================================================

print("\n📥 ETAPA 1: Leitura de dados novos do Bronze...")
print(f"   Database: {args['bronze_database']}")
print(f"   Table: {args['bronze_table']}")

# Ler dados do Bronze usando Glue Data Catalog com Bookmarks
# transformation_ctx é CRUCIAL para rastrear o que já foi processado
bronze_dynamic_frame = glueContext.create_dynamic_frame.from_catalog(
    database=args['bronze_database'],
    table_name=args['bronze_table'],
    transformation_ctx="bronze_source"  # Bookmark tracking
    # Nota: push_down_predicate removido pois ingest_year não está nas partition keys
)

# Converter para Spark DataFrame
df_bronze_new = bronze_dynamic_frame.toDF()

# Contar registros novos
new_records_count = df_bronze_new.count()
print(f"   ✅ Registros novos encontrados: {new_records_count}")

# Mostrar schema do Bronze (aninhado)
print("\n   📊 Schema Bronze (com structs):")
df_bronze_new.printSchema()

# Note: Continuamos o processamento mesmo com 0 registros novos
# Isso permite que o Glue Job seja marcado como SUCCEEDED
# e o Workflow possa prosseguir com o Crawler

# ============================================================================
# 3. TRANSFORMAÇÕES SILVER
# ============================================================================

print("\n🔄 ETAPA 2: Aplicando transformações Silver...")

# ----------------------------------------------------------------------------
# 3.1 ACHATAMENTO (Flattening) - Desnormalizar structs
# ----------------------------------------------------------------------------

print("   🔹 1/5: Achatando estruturas aninhadas (structs)...")

# Achatar struct 'metrics'
df_flattened = df_bronze_new.select(
    "*",
    F.col("metrics.engineTempCelsius").alias("metrics_engineTempCelsius"),
    F.col("metrics.oilTempCelsius").alias("metrics_oilTempCelsius"),
    F.col("metrics.batteryChargePerc").alias("metrics_batteryChargePerc"),
    F.col("metrics.fuelAvailableLiters").alias("metrics_fuelAvailableLiters"),
    F.col("metrics.coolantCelsius").alias("metrics_coolantCelsius"),
    F.col("metrics.metricTimestamp").alias("metrics_metricTimestamp"),
    # Achatar struct aninhado 'metrics.trip'
    F.col("metrics.trip.tripMileage").alias("metrics_trip_tripMileage"),
    F.col("metrics.trip.tripTimeMinutes").alias("metrics_trip_tripTimeMinutes"),
    F.col("metrics.trip.tripFuelLiters").alias("metrics_trip_tripFuelLiters"),
    F.col("metrics.trip.tripMaxSpeedKm").alias("metrics_trip_tripMaxSpeedKm"),
    F.col("metrics.trip.tripAverageSpeedKm").alias("metrics_trip_tripAverageSpeedKm"),
    F.col("metrics.trip.tripStartTimestamp").alias("metrics_trip_tripStartTimestamp")
).drop("metrics")  # Remover struct original

# Achatar struct 'carInsurance'
df_flattened = df_flattened.select(
    "*",
    F.col("carInsurance.number").alias("carInsurance_number"),
    F.col("carInsurance.provider").alias("carInsurance_provider"),
    F.col("carInsurance.validUntil").alias("carInsurance_validUntil")
).drop("carInsurance")

# Achatar struct 'market'
df_flattened = df_flattened.select(
    "*",
    F.col("market.currentPrice").alias("market_currentPrice"),
    F.col("market.currency").alias("market_currency"),
    F.col("market.location").alias("market_location"),
    F.col("market.dealer").alias("market_dealer"),
    F.col("market.warrantyYears").alias("market_warrantyYears"),
    F.col("market.evaluator").alias("market_evaluator")
).drop("market")

print(f"      ✅ {len(df_flattened.columns)} colunas após achatamento")

# ----------------------------------------------------------------------------
# 3.2 LIMPEZA (Cleansing) - Padronização
# ----------------------------------------------------------------------------

print("   🔹 2/5: Aplicando limpeza e padronização...")

df_clean = df_flattened.withColumn(
    "Manufacturer",
    F.initcap(F.col("Manufacturer"))  # Title Case
).withColumn(
    "color",
    F.lower(F.col("color"))  # lowercase
)

print("      ✅ Manufacturer → Title Case, color → lowercase")

# ----------------------------------------------------------------------------
# 3.3 CONVERSÃO DE TIPOS
# ----------------------------------------------------------------------------

print("   🔹 3/5: Convertendo tipos de dados...")

# Converter timestamp strings para timestamp
df_typed = df_clean.withColumn(
    "metrics_metricTimestamp",
    F.to_timestamp(F.col("metrics_metricTimestamp"), "EEE, dd MMM yyyy HH:mm:ss")
).withColumn(
    "metrics_trip_tripStartTimestamp",
    F.to_timestamp(F.col("metrics_trip_tripStartTimestamp"), "EEE, dd MMM yyyy HH:mm:ss")
).withColumn(
    "carInsurance_validUntil",
    F.to_date(F.col("carInsurance_validUntil"), "yyyy-MM-dd")
)

print("      ✅ Timestamps e datas convertidos")

# ----------------------------------------------------------------------------
# 3.4 ENRIQUECIMENTO (Enrichment) - Métricas calculadas
# ----------------------------------------------------------------------------

print("   🔹 4/5: Calculando métricas enriquecidas...")

df_enriched = df_typed.withColumn(
    "metrics_fuel_level_percentage",
    F.round((F.col("metrics_fuelAvailableLiters") / F.col("fuelCapacityLiters")) * 100, 2)
).withColumn(
    "metrics_trip_km_per_liter",
    F.when(
        F.col("metrics_trip_tripFuelLiters") > 0,
        F.round(F.col("metrics_trip_tripMileage") / F.col("metrics_trip_tripFuelLiters"), 2)
    ).otherwise(0.0)
)

print("      ✅ Métricas calculadas: fuel_level_percentage, km_per_liter")

# ----------------------------------------------------------------------------
# 3.5 PARTICIONAMENTO (Event-based partitions)
# ----------------------------------------------------------------------------

print("   🔹 5/5: Criando colunas de partição por data do evento...")

df_partitioned = df_enriched.withColumn(
    "event_year",
    F.year(F.col("metrics_metricTimestamp")).cast("string")
).withColumn(
    "event_month",
    F.lpad(F.month(F.col("metrics_metricTimestamp")).cast("string"), 2, "0")
).withColumn(
    "event_day",
    F.lpad(F.dayofmonth(F.col("metrics_metricTimestamp")).cast("string"), 2, "0")
)

# Remover colunas de metadados da ingestão (não necessárias no Silver)
df_silver_new = df_partitioned.drop("ingestion_timestamp", "source_file", "source_bucket")

print("      ✅ Partições criadas: event_year, event_month, event_day")
print(f"   ✅ Transformação completa! {df_silver_new.count()} registros prontos")

# ============================================================================
# 4. CARREGAR DADOS EXISTENTES DO SILVER (PARA CONSOLIDAÇÃO)
# ============================================================================

print("\n📚 ETAPA 3: Carregando dados existentes do Silver...")
print(f"   Database: {args['silver_database']}")
print(f"   Table: {args['silver_table']}")

try:
    # Tentar ler tabela Silver existente
    silver_existing_dynamic_frame = glueContext.create_dynamic_frame.from_catalog(
        database=args['silver_database'],
        table_name=args['silver_table'],
        transformation_ctx="silver_existing"
    )
    
    df_silver_existing = silver_existing_dynamic_frame.toDF()
    existing_count = df_silver_existing.count()
    print(f"   ✅ Registros existentes: {existing_count}")
    
except Exception as e:
    # Tabela não existe ainda (primeira execução)
    print(f"   ℹ️  Tabela Silver não existe ou está vazia (primeira execução)")
    df_silver_existing = spark.createDataFrame([], df_silver_new.schema)
    existing_count = 0

# ============================================================================
# 5. CONSOLIDAÇÃO (UPSERT) - LÓGICA DE DEDUPLICAÇÃO
# ============================================================================

print("\n🔀 ETAPA 4: Consolidando dados (Upsert/Deduplicação)...")
print(f"   Registros novos: {df_silver_new.count()}")
print(f"   Registros existentes: {existing_count}")

# Passo A: Unir dados novos + dados existentes
df_union = df_silver_new.unionByName(df_silver_existing, allowMissingColumns=True)
total_before_dedup = df_union.count()
print(f"   📊 Total antes da deduplicação: {total_before_dedup}")

# Passo B: Definir Window para deduplicação
# Particionar por: carChassis + partições de evento
# Ordenar por: currentMileage DESC (o mais recente/maior milhagem vence)
window_spec = Window.partitionBy(
    "carChassis",
    "event_year",
    "event_month",
    "event_day"
).orderBy(
    F.col("currentMileage").desc()
)

# Passo C: Aplicar row_number() e manter apenas row_number = 1
df_deduplicated = df_union.withColumn(
    "row_num",
    F.row_number().over(window_spec)
).filter(
    F.col("row_num") == 1
).drop("row_num")

total_after_dedup = df_deduplicated.count()
duplicates_removed = total_before_dedup - total_after_dedup

print(f"   ✅ Total após deduplicação: {total_after_dedup}")
print(f"   🗑️  Duplicatas removidas: {duplicates_removed}")

# Mostrar exemplo de consolidação
print("\n   📋 Exemplo de registros consolidados:")
df_deduplicated.select(
    "carChassis",
    "currentMileage",
    "metrics_metricTimestamp",
    "event_year",
    "event_month",
    "event_day"
).show(5, truncate=False)

# ============================================================================
# 6. ESCRITA NO SILVER (DYNAMIC PARTITION OVERWRITE)
# ============================================================================

print("\n💾 ETAPA 5: Escrevendo dados consolidados no Silver...")
print(f"   Bucket: {args['silver_bucket']}")
print(f"   Path: {args['silver_path']}")

# Escrever no S3 usando Spark DataFrame Writer (suporta Dynamic Partition Overwrite)
# IMPORTANTE: Usar .write.mode("overwrite") com partitionOverwriteMode=dynamic
# garante que apenas as partições afetadas sejam sobrescritas (não todo o diretório)
silver_output_path = f"s3://{args['silver_bucket']}/{args['silver_path']}"

df_deduplicated.write \
    .mode("overwrite") \
    .partitionBy("event_year", "event_month", "event_day") \
    .format("parquet") \
    .option("compression", "snappy") \
    .save(silver_output_path)

print(f"   ✅ Dados escritos com sucesso!")
print(f"   📦 Registros finais: {total_after_dedup}")

# Mostrar partições escritas
partitions_written = df_deduplicated.select(
    "event_year", "event_month", "event_day"
).distinct().collect()

print(f"\n   📂 Partições escritas ({len(partitions_written)}):")
for partition in partitions_written:
    print(f"      - event_year={partition.event_year}/event_month={partition.event_month}/event_day={partition.event_day}")

# ============================================================================
# 7. FINALIZAÇÃO DO JOB
# ============================================================================

print("\n" + "=" * 80)
print("✅ JOB CONCLUÍDO COM SUCESSO!")
print("=" * 80)
print(f"📊 Resumo:")
print(f"   - Registros novos processados: {new_records_count}")
print(f"   - Registros existentes: {existing_count}")
print(f"   - Total antes da deduplicação: {total_before_dedup}")
print(f"   - Duplicatas removidas: {duplicates_removed}")
print(f"   - Total consolidado: {total_after_dedup}")
print(f"   - Partições afetadas: {len(partitions_written)}")
print("=" * 80)

# Commit do Job (atualiza bookmarks)
job.commit()

print("\n🎯 Próximos passos:")
print("   1. Executar Glue Crawler no Silver para atualizar catálogo")
print("   2. Consultar dados consolidados no Athena")
print("   3. Verificar que não há duplicatas por carChassis + data do evento")
