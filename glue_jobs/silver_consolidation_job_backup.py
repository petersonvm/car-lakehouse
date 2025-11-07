"""
AWS Glue ETL Job - Silver Layer Consolidation (COMPATÍVEL)
==========================================================

Objetivo:
- Ler dados novos do Bronze (Parquet com estrutura atual)
- Aplicar achatamento (flatten) de structs existentes
- Consolidar estado atual por veículo (current state)
- Enriquecer com KPIs de seguro
- Escrever apenas partições afetadas (Dynamic Partition Overwrite)

Estrutura Bronze Atual:
- Campos principais: carChassis, Model, year, etc.
- Estruturas aninhadas: metrics, carInsurance, market
- Campos de telemetria em metrics.* e metrics.trip.*

Lógica de Consolidação:
- Chave de negócio: carChassis 
- Regra de precedência: currentMileage DESC (estado mais atual)
- Resultado: 1 registro único por carChassis (estado atual)

Autor: Sistema de Data Lakehouse
Data: 2025-11-04 (Compatibilidade Bronze Atual)
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
print(f" Job iniciado: {args['JOB_NAME']}")
print(f" Timestamp: {datetime.now().isoformat()}")
print("=" * 80)

# ============================================================================
# 2. LEITURA DOS DADOS NOVOS DO BRONZE (ESTRUTURA ATUAL)
# ============================================================================

print("\n ETAPA 1: Leitura de dados novos do Bronze (Estrutura Atual)...")
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
df_bronze_current = bronze_dynamic_frame.toDF()

# Contar registros novos
new_records_count = df_bronze_current.count()
print(f"    Registros novos encontrados: {new_records_count}")

# Mostrar schema do Bronze (estrutura atual)
print("\n    Schema Bronze (estrutura atual):")
df_bronze_current.printSchema()

if new_records_count == 0:
    print("   ℹ  Nenhum registro novo para processar. Job continuará para manter bookmarks atualizados.")
else:
    print(f"    Exemplo de dados Bronze:")
    df_bronze_current.select("carChassis", "Model", "currentMileage").show(2, truncate=False)

# ============================================================================
# 3. ACHATAMENTO (FLATTENING) DA ESTRUTURA ATUAL
# ============================================================================

print("\n ETAPA 2: Achatamento de estruturas aninhadas (estrutura atual)...")

if new_records_count > 0:
    
    # ----------------------------------------------------------------------------
    # 3.1 ACHATAMENTO PRINCIPAL - Extrair dados dos structs existentes
    # ----------------------------------------------------------------------------
    
    print("    1/4: Achatando structs da estrutura atual...")
    
    # Achatar struct 'metrics'
    df_flattened = df_bronze_current.select(
        # Campos principais 
        F.col("carChassis"),
        F.col("Model"),
        F.col("year"),
        F.col("ModelYear"),
        F.col("Manufacturer"),
        F.col("horsePower"),
        F.col("gasType"),
        F.col("currentMileage"),
        F.col("color"),
        F.col("fuelCapacityLiters"),
        
        # Achatar struct 'metrics'
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
        F.col("metrics.trip.tripStartTimestamp").alias("metrics_trip_tripStartTimestamp"),
        
        # Achatar struct 'carInsurance'
        F.col("carInsurance.number").alias("carInsurance_number"),
        F.col("carInsurance.provider").alias("carInsurance_provider"),
        F.col("carInsurance.validUntil").alias("carInsurance_validUntil"),
        
        # Achatar struct 'market'
        F.col("market.currentPrice").alias("market_currentPrice"),
        F.col("market.currency").alias("market_currency"),
        F.col("market.location").alias("market_location"),
        F.col("market.dealer").alias("market_dealer"),
        F.col("market.warrantyYears").alias("market_warrantyYears"),
        F.col("market.evaluator").alias("market_evaluator"),
        
        # Partições originais (mantemos para compatibilidade)
        F.col("ingest_month"),
        F.col("ingest_day")
    )
    
    print(f"       {len(df_flattened.columns)} colunas após achatamento")
    
    # ----------------------------------------------------------------------------
    # 3.2 LIMPEZA E PADRONIZAÇÃO
    # ----------------------------------------------------------------------------
    
    print("    2/4: Aplicando limpeza e padronização...")
    
    df_clean = df_flattened.withColumn(
        "Manufacturer",
        F.initcap(F.col("Manufacturer"))  # Title Case
    ).withColumn(
        "color",
        F.lower(F.col("color"))  # lowercase
    ).withColumn(
        "carInsurance_provider",
        F.initcap(F.col("carInsurance_provider"))  # Title Case
    )
    
    print("       Padronização aplicada: Manufacturer/provider → Title Case, color → lowercase")
    
    # ----------------------------------------------------------------------------
    # 3.3 CONVERSÃO DE TIPOS E TIMESTAMPS
    # ----------------------------------------------------------------------------
    
    print("    3/4: Convertendo tipos e timestamps...")
    
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
    
    print("       Timestamps e datas convertidos")
    
    # ----------------------------------------------------------------------------
    # 3.4 ENRIQUECIMENTO - KPIs Calculados
    # ----------------------------------------------------------------------------
    
    print("    4/4: Calculando KPIs enriquecidos...")
    
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
    
    # KPIs DE SEGURO (INSURANCE KPIs) - MANTIDOS E ADAPTADOS
    df_with_insurance_kpis = df_enriched.withColumn(
        "insurance_days_to_expiry",
        F.datediff(F.col("carInsurance_validUntil"), F.current_date())
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
    
    print("       KPIs calculados: fuel_level_percentage, km_per_liter, insurance_status, insurance_days_expired")
    
    # Criar colunas de partição por data do evento
    df_silver_transformed = df_with_insurance_kpis.withColumn(
        "event_year",
        F.year(F.col("metrics_metricTimestamp")).cast("string")
    ).withColumn(
        "event_month",
        F.lpad(F.month(F.col("metrics_metricTimestamp")).cast("string"), 2, "0")
    ).withColumn(
        "event_day",
        F.lpad(F.dayofmonth(F.col("metrics_metricTimestamp")).cast("string"), 2, "0")
    )
    
    print(f"    Transformação completa! {df_silver_transformed.count()} registros transformados")
    
else:
    # Criar DataFrame vazio com schema esperado para casos sem dados novos
    print("   ℹ  Criando DataFrame vazio com schema esperado...")
    df_silver_transformed = spark.createDataFrame([], schema=None)  # Schema será inferido na próxima execução


# ============================================================================
# 4. CONSOLIDAÇÃO - CURRENT STATE (Estado Atual por Quilometragem)
# ============================================================================

print("\n ETAPA 3: Consolidando para estado atual por quilometragem...")

if new_records_count > 0:
    
    # Ler dados existentes na camada Silver
    print("    1/3: Lendo dados existentes da camada Silver...")
    
    try:
        df_silver_existing = glueContext.create_dynamic_frame.from_catalog(
            database=args['silver_database'],
            table_name=args['silver_table']
        ).toDF()
        
        print(f"       {df_silver_existing.count()} registros existentes encontrados")
    except Exception as e:
        print(f"        Tabela não existe ainda. Será criada: {str(e)}")
        # Criar DataFrame vazio com schema igual aos novos dados
        df_silver_existing = spark.createDataFrame([], schema=None)  # Schema será inferido
    
    # Unir dados novos + existentes
    print("    2/3: Combinando dados novos e existentes...")
    
    print(f"   Registros existentes: {df_silver_existing.count()}")
    print(f"   Registros novos: {df_silver_transformed.count()}")
    
    # União dos dados (allowMissingColumns para compatibilidade de schema)
    if df_silver_existing.count() > 0:
        df_union = df_silver_transformed.unionByName(df_silver_existing, allowMissingColumns=True)
    else:
        df_union = df_silver_transformed
    
    print(f"   Total após união: {df_union.count()}")
    
    # Aplicar lógica de consolidação: MAIOR QUILOMETRAGEM por chassis (estado mais atual)
    print("    3/3: Aplicando consolidação de estado atual por quilometragem...")
    
    # Determinar o registro com maior quilometragem para cada carChassis
    # currentMileage como critério principal + metrics_metricTimestamp como desempate
    
    window_spec = Window.partitionBy("carChassis").orderBy(
        F.col("currentMileage").desc(),
        F.col("metrics_metricTimestamp").desc()
    )
    
    df_current_state = df_union.withColumn(
        "row_number",
        F.row_number().over(window_spec)
    ).filter(
        F.col("row_number") == 1
    ).drop("row_number")
    
    print(f"    Estado atual consolidado: {df_current_state.count()} veículos únicos")
    
    # Estatísticas de consolidação
    total_records_before = df_union.count()
    unique_chassis_after = df_current_state.count()
    
    print(f"    Consolidação: {total_records_before} registros → {unique_chassis_after} veículos únicos")
    
    # Mostrar exemplo de consolidação
    print("\n    Exemplo de registros consolidados:")
    df_current_state.select(
        "carChassis",
        "currentMileage",
        "metrics_metricTimestamp",
        "Manufacturer",
        "Model",
        "insurance_status",
        "insurance_days_expired"
    ).show(5, truncate=False)
    
else:
    print("   ℹ  Nenhum registro novo para consolidar")
    df_current_state = spark.createDataFrame([], schema=None)

# ============================================================================
# 5. ESCRITA NO SILVER (DYNAMIC PARTITION OVERWRITE)
# ============================================================================

print("\n ETAPA 4: Escrevendo dados consolidados no Silver...")

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
    
    print(f"    Dados escritos com sucesso!")
    print(f"    Registros finais: {df_current_state.count()}")
    
    # Mostrar partições escritas
    partitions_written = df_current_state.select(
        "event_year", "event_month", "event_day"
    ).distinct().collect()
    
    print(f"\n    Partições escritas ({len(partitions_written)}):")
    for partition in partitions_written:
        print(f"      - event_year={partition.event_year}/event_month={partition.event_month}/event_day={partition.event_day}")

else:
    print("   ℹ  Nenhum registro novo para processar - Escrita pulada")

# ============================================================================
# 6. FINALIZAÇÃO DO JOB
# ============================================================================

print("\n" + "=" * 80)
print(" JOB CONCLUÍDO COM SUCESSO!")
print("=" * 80)
print(f" Resumo:")
print(f"   - Registros Bronze processados: {new_records_count}")
if new_records_count > 0:
    print(f"   - Registros Silver consolidados: {df_current_state.count()}")
    print(f"   - Veículos únicos processados: {df_current_state.count()}")
    print(f"   - Taxa de consolidação: {df_current_state.count()}/{new_records_count} = {round(df_current_state.count()/new_records_count*100, 1)}%")
print(f"   - Timestamp final: {datetime.now().isoformat()}")
print("=" * 80)

# Commit do Job (atualiza bookmarks)
job.commit()

print("\n Próximos passos:")
print("   1. Executar Glue Crawler no Silver para atualizar catálogo")
print("   2. Consultar dados consolidados no Athena") 
print("   3. Verificar que Insurance KPIs estão funcionando")
print("   4. Validar consolidação por current_mileage DESC")
