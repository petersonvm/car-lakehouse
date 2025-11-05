"""
AWS Glue ETL Job - Gold Layer: Fuel Efficiency Analysis (REFATORADO - car_silver)
===============================================================================

REFATORAÇÃO: Atualização para ler da nova tabela Silver
De: silver_car_telemetry → Para: car_silver

Objetivo:
- Ler dados da camada Silver (nova tabela car_silver)
- Calcular métricas de eficiência de combustível mensais
- Agregar por manufatura, modelo e período
- Gerar insights para otimização da frota

Características:
- Source: car_silver (via Glue Catalog) - ATUALIZADO
- Aggregation: Monthly efficiency metrics
- Partitioning: year/month
- Output: fuel_efficiency_monthly

Autor: Sistema de Data Lakehouse
Data: 2025-11-05 (Refatoração: silver_car_telemetry → car_silver)
"""

import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.dynamicframe import DynamicFrame

from pyspark.sql import functions as F
from pyspark.sql.functions import col, avg, sum, count, max, min, round
from pyspark.sql.window import Window
from datetime import datetime

# ============================================================================
# 1. CONFIGURAÇÃO E INICIALIZAÇÃO
# ============================================================================

print("\n" + "=" * 80)
print("⛽ AWS GLUE JOB - GOLD FUEL EFFICIENCY ANALYSIS (REFATORADO)")
print("📝 Fonte Silver: car_silver (anteriormente: silver_car_telemetry)")
print("=" * 80)

# Parâmetros do job
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'database_name',        # NOVO: Para usar Glue Catalog
    'silver_table_name',    # NOVO: Nome da tabela Silver (car_silver)
    'gold_bucket',
    'gold_path'
])

# Configuração dos contextos
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

# Configurações
DATABASE_NAME = args['database_name']
SILVER_TABLE = args['silver_table_name']  # ATUALIZADO: car_silver
GOLD_BUCKET = args['gold_bucket']
GOLD_PATH = args['gold_path']

print(f"\n📋 CONFIGURAÇÃO:")
print(f"   🗃️  Database: {DATABASE_NAME}")
print(f"   📥 Tabela Silver: {SILVER_TABLE}")  # ATUALIZADO
print(f"   📤 Gold Output: s3://{GOLD_BUCKET}/{GOLD_PATH}")
print(f"   🔧 Job: {args['JOB_NAME']}")

# ============================================================================
# 2. LEITURA DOS DADOS SILVER (NOVA TABELA: car_silver)
# ============================================================================

print("\n📖 ETAPA 1: Leitura dos dados Silver (nova tabela car_silver)...")

try:
    # Leitura usando Glue Catalog - TABELA RENOMEADA
    dyf_silver_new = glueContext.create_dynamic_frame.from_catalog(
        database=DATABASE_NAME,
        table_name=SILVER_TABLE,  # ATUALIZADO: car_silver
        transformation_ctx="dyf_silver_source",
        # Job bookmark para processar apenas dados novos
        additional_options={"jobBookmarkKeys": ["event_id"], "jobBookmarkKeysSortOrder": "asc"}
    )
    
    df_silver = dyf_silver_new.toDF()
    
    record_count = df_silver.count()
    print(f"   ✅ Registros Silver lidos: {record_count}")
    print(f"   📊 Campos disponíveis: {len(df_silver.columns)}")
    print(f"   📝 Fonte: {DATABASE_NAME}.{SILVER_TABLE}")
    
    if record_count == 0:
        print("   ⚠️  AVISO: Nenhum registro novo encontrado!")
        print("   🔄 Encerrando job (job bookmark - sem novos dados)")
        job.commit()
        sys.exit(0)
        
except Exception as e:
    print(f"   ❌ ERRO na leitura Silver: {str(e)}")
    print(f"   🔍 Verifique se a tabela {SILVER_TABLE} existe no database {DATABASE_NAME}")
    raise e

# ============================================================================
# 3. FILTROS E PREPARAÇÃO DOS DADOS
# ============================================================================

print("\n🔍 ETAPA 2: Filtros e preparação dos dados...")

# Filtrar apenas registros com dados válidos de viagem
df_valid_trips = df_silver.filter(
    (col("trip_mileage_km").isNotNull()) &
    (col("trip_fuel_liters").isNotNull()) &
    (col("trip_mileage_km") > 0) &
    (col("trip_fuel_liters") > 0) &
    (col("manufacturer").isNotNull()) &
    (col("model").isNotNull())
)

valid_trips_count = df_valid_trips.count()
print(f"   ✅ Viagens válidas para análise: {valid_trips_count}")

if valid_trips_count == 0:
    print("   ⚠️  AVISO: Nenhuma viagem válida encontrada!")
    print("   🔄 Encerrando job (sem dados válidos para análise)")
    job.commit()
    sys.exit(0)

# Adicionar campos calculados
df_with_efficiency = df_valid_trips.withColumn(
    # Eficiência: litros por 100km
    "fuel_efficiency_l_per_100km",
    round((col("trip_fuel_liters") / col("trip_mileage_km") * 100), 2)
).withColumn(
    # Campos de tempo para agregação
    "trip_year", F.year(col("event_timestamp"))
).withColumn(
    "trip_month", F.month(col("event_timestamp"))
).withColumn(
    "year_month", F.concat(col("trip_year"), F.lit("-"), 
                          F.format_string("%02d", col("trip_month")))
)

print(f"   ✅ Campos de eficiência calculados!")

# ============================================================================
# 4. AGREGAÇÕES DE EFICIÊNCIA MENSAIS
# ============================================================================

print("\n📊 ETAPA 3: Calculando métricas de eficiência mensais...")

# Agregação principal por manufatura, modelo e mês
df_monthly_efficiency = df_with_efficiency.groupBy(
    "manufacturer",
    "model",
    "gas_type",
    "trip_year",
    "trip_month",
    "year_month"
).agg(
    # Métricas de eficiência
    avg("fuel_efficiency_l_per_100km").alias("avg_fuel_efficiency_l_per_100km"),
    min("fuel_efficiency_l_per_100km").alias("min_fuel_efficiency_l_per_100km"),
    max("fuel_efficiency_l_per_100km").alias("max_fuel_efficiency_l_per_100km"),
    
    # Totais de consumo
    sum("trip_fuel_liters").alias("total_fuel_consumed_liters"),
    sum("trip_mileage_km").alias("total_distance_km"),
    
    # Contadores
    count("*").alias("total_trips"),
    F.countDistinct("car_chassis").alias("unique_vehicles"),
    
    # Estatísticas de viagem
    avg("trip_mileage_km").alias("avg_trip_distance_km"),
    avg("trip_time_minutes").alias("avg_trip_duration_minutes"),
    
    # Data de processamento
    F.current_timestamp().alias("gold_processing_timestamp")
).withColumn(
    # Eficiência consolidada do período
    "period_overall_efficiency_l_per_100km",
    round((col("total_fuel_consumed_liters") / col("total_distance_km") * 100), 2)
).withColumn(
    # Ranking de eficiência por mês
    "efficiency_rank_in_month",
    F.row_number().over(
        Window.partitionBy("trip_year", "trip_month")
        .orderBy(col("avg_fuel_efficiency_l_per_100km").asc())
    )
).withColumn(
    # Categorização de eficiência
    "efficiency_category",
    F.when(col("avg_fuel_efficiency_l_per_100km") <= 7, "EXCELLENT")
    .when(col("avg_fuel_efficiency_l_per_100km") <= 10, "GOOD")
    .when(col("avg_fuel_efficiency_l_per_100km") <= 15, "AVERAGE")
    .otherwise("POOR")
)

monthly_records = df_monthly_efficiency.count()
print(f"   ✅ Registros mensais de eficiência: {monthly_records}")

# ============================================================================
# 5. GRAVAÇÃO NO GOLD LAYER
# ============================================================================

print("\n💾 ETAPA 4: Gravação no Gold Layer...")

# Adicionar campos de particionamento
df_gold_final = df_monthly_efficiency.withColumn(
    "processing_year", F.year(F.current_timestamp()).cast("string")
).withColumn(
    "processing_month", F.format_string("%02d", F.month(F.current_timestamp()))
)

print(f"   📊 Registros finais a gravar: {df_gold_final.count()}")
print(f"   📍 Destino: s3://{GOLD_BUCKET}/{GOLD_PATH}")

# Converter para DynamicFrame
dyf_gold_final = DynamicFrame.fromDF(df_gold_final, glueContext, "dyf_gold_final")

# Gravar dados particionados
glueContext.write_dynamic_frame.from_options(
    frame=dyf_gold_final,
    connection_type="s3",
    connection_options={
        "path": f"s3://{GOLD_BUCKET}/{GOLD_PATH}",
        "partitionKeys": ["processing_year", "processing_month"]
    },
    format="glueparquet",
    format_options={
        "compression": "snappy"
    },
    transformation_ctx="write_gold_fuel_efficiency"
)

print("   ✅ Dados de eficiência gravados no Gold!")

# ============================================================================
# 6. ESTATÍSTICAS FINAIS
# ============================================================================

print("\n📊 ESTATÍSTICAS FINAIS:")
print(f"   📥 Registros Silver processados: {record_count}")
print(f"   🚗 Viagens válidas analisadas: {valid_trips_count}")
print(f"   📤 Registros Gold de eficiência: {monthly_records}")
print(f"   📝 Fonte Silver: {DATABASE_NAME}.{SILVER_TABLE}")

# Mostrar top 3 modelos mais eficientes
print(f"\n   🏆 TOP 3 MODELOS MAIS EFICIENTES:")
top_efficient = df_monthly_efficiency.orderBy(col("avg_fuel_efficiency_l_per_100km").asc()).limit(3)
top_efficient_list = top_efficient.select("manufacturer", "model", "avg_fuel_efficiency_l_per_100km").collect()

for i, row in enumerate(top_efficient_list, 1):
    print(f"      {i}. {row['manufacturer']} {row['model']}: {row['avg_fuel_efficiency_l_per_100km']} L/100km")

print("\n" + "=" * 80)
print("🎉 Gold Fuel Efficiency Job - REFATORAÇÃO CONCLUÍDA COM SUCESSO!")
print(f"📝 Nova fonte Silver: {SILVER_TABLE}")
print(f"🕒 Timestamp final: {datetime.now().isoformat()}")
print("=" * 80)

# Commit do job
job.commit()