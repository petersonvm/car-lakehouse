"""

AWS GLUE ETL JOB: Gold Performance Alerts - SLIM (Optimized)


 DESCRIÇÃO:
    Pipeline ETL OTIMIZADO para detectar alertas de performance de veículos.
    
    **DIFERENÇA CRÍTICA vs. Pipeline Antigo:**
    -  Antigo: Copiava ~36 colunas (Model, Manufacturer, market_price, etc.)
    -  Novo: Seleciona APENAS 7 colunas essenciais (Quem, Quando, O Quê, Valor)
    -  Redução: ~80% menos armazenamento e custo

 INPUT:
    - Source: silver_car_telemetry (Glue Catalog)
    - Mode: Incremental (Job Bookmarks)
    - Database: datalake-pipeline-catalog-dev

 OUTPUT:
    - Target: s3://[gold-bucket]/performance_alerts_log_slim/
    - Format: Parquet
    - Mode: Append
    - Partitions: alert_type, event_year, event_month, event_day

 KPIs MONITORADOS:
    1. OVERHEAT_ENGINE: engineTempCelsius > 100°C
    2. OVERHEAT_OIL: oilTempCelsius > 110°C
    3. SPEEDING_ALERT: tripMaxSpeedKm > 110 km/h

 SCHEMA (SLIM):
     car_chassis (string) - Identificador do veículo
     event_timestamp (string) - Quando ocorreu
     alert_type (string) - Tipo do alerta
     alert_value (double) - Valor que disparou o alerta
     event_year (string) - Partição
     event_month (string) - Partição
     event_day (string) - Partição

 OTIMIZAÇÕES APLICADAS:
    -  .select() para apenas colunas necessárias
    -  Particionamento multi-nível (alert_type + data)
    -  Job Bookmarks para processamento incremental
    -  Sem duplicação de dados do Silver Layer


"""

import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql.functions import col, when, lit, current_timestamp
from datetime import datetime

# 
# 1. INICIALIZAÇÃO DO JOB
# 

# Capturar argumentos passados pelo Job
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'glue_database',
    'gold_bucket'
])

# Inicializar contextos
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

# Variáveis de ambiente
GLUE_DATABASE = args['glue_database']
GOLD_BUCKET = args['gold_bucket']
OUTPUT_PATH = f"s3://{GOLD_BUCKET}/performance_alerts_log_slim/"

print("" * 80)
print(" GOLD PERFORMANCE ALERTS - SLIM PIPELINE")
print("" * 80)
print(f" Database: {GLUE_DATABASE}")
print(f" Output Path: {OUTPUT_PATH}")
print(f"⏰ Execution Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
print("" * 80)

# 
# 2. LEITURA INCREMENTAL (Job Bookmarks)
# 

print("\n STEP 1: Reading INCREMENTAL data from Silver Layer...")

try:
    # Leitura incremental com transformation_ctx (habilita Job Bookmarks)
    dyf_silver_telemetry = glueContext.create_dynamic_frame.from_catalog(
        database=GLUE_DATABASE,
        table_name="silver_car_telemetry",  # VIEW com mapeamento de colunas (car_chassis → carChassis)
        transformation_ctx="read_silver_telemetry_incremental_slim"
    )
    
    # Converter para Spark DataFrame para operações avançadas
    df_silver = dyf_silver_telemetry.toDF()
    
    print(f" Incremental read completed")
    print(f"   Records to process: {df_silver.count()}")
    
except Exception as e:
    print(f" ERROR reading Silver data: {str(e)}")
    raise

# 
# 3. FILTRAGEM (KPIs de Performance)
# 

print("\n STEP 2: Filtering performance violations...")

try:
    # Filtrar apenas registros que violaram pelo menos 1 KPI
    df_alerts = df_silver.filter(
        (col("engine_temp_celsius") > 100) |
        (col("oil_temp_celsius") > 110) |
        (col("trip_max_speed_kmh") > 110)
    )
    
    alerts_count = df_alerts.count()
    print(f" Filtering completed")
    print(f"    Alerts detected: {alerts_count}")
    
    if alerts_count == 0:
        print("   ℹ  No performance violations found in this batch")
        print("    Job completed successfully (no data to write)")
        job.commit()
        sys.exit(0)
    
except Exception as e:
    print(f" ERROR filtering alerts: {str(e)}")
    raise

# 
# 4. ENRIQUECIMENTO (Classificação + Valor do Alerta)
# 

print("\n  STEP 3: Enriching with alert_type and alert_value...")

try:
    # Criar coluna alert_type (classificação do tipo de alerta)
    df_enriched = df_alerts.withColumn(
        "alert_type",
        when(col("engine_temp_celsius") > 100, lit("OVERHEAT_ENGINE"))
        .when(col("oil_temp_celsius") > 110, lit("OVERHEAT_OIL"))
        .when(col("trip_max_speed_kmh") > 110, lit("SPEEDING_ALERT"))
        .otherwise(lit("UNKNOWN"))
    )
    
    # Criar coluna alert_value (captura o valor que disparou o alerta)
    df_enriched = df_enriched.withColumn(
        "alert_value",
        when(col("engine_temp_celsius") > 100, col("engine_temp_celsius"))
        .when(col("oil_temp_celsius") > 110, col("oil_temp_celsius"))
        .when(col("trip_max_speed_kmh") > 110, col("trip_max_speed_kmh"))
        .otherwise(lit(None))
    )
    
    print(" Enrichment completed")
    print(f"   Columns added: alert_type, alert_value")
    
    # Log da distribuição de tipos de alertas
    print("\n    Alert Distribution:")
    alert_distribution = df_enriched.groupBy("alert_type").count().collect()
    for row in alert_distribution:
        print(f"      • {row['alert_type']}: {row['count']} alerts")
    
except Exception as e:
    print(f" ERROR enriching data: {str(e)}")
    raise

# 
# 5. SELEÇÃO (SLIM - Apenas Colunas Essenciais)
# 

print("\n  STEP 4: Selecting SLIM columns (optimization)...")

try:
    #  CRÍTICO: Selecionar APENAS as 7 colunas essenciais
    # Esta é a principal diferença vs. pipeline antigo (que tinha ~36 colunas)
    df_slim = df_enriched.select(
        col("car_chassis"),                     # Quem (identificador do veículo)
        col("event_timestamp"),                 # Quando (timestamp do evento)
        col("alert_type"),                      # O Quê (tipo do alerta)
        col("alert_value"),                     # Valor (valor que disparou)
        col("event_year"),                      # Partição 1
        col("event_month"),                     # Partição 2
        col("event_day")                        # Partição 3
    )
    
    print(" Slim selection completed")
    print(f"   Total columns: {len(df_slim.columns)} (vs 36 in old pipeline)")
    print(f"   Columns: {', '.join(df_slim.columns)}")
    print(f"    Storage reduction: ~80%")
    
except Exception as e:
    print(f" ERROR selecting columns: {str(e)}")
    raise

# 
# 6. ESCRITA (Append com Particionamento)
# 

print(f"\n STEP 5: Writing SLIM alerts to Gold Layer...")
print(f"    Target: {OUTPUT_PATH}")
print(f"    Mode: append")
print(f"     Partitions: alert_type, event_year, event_month, event_day")

try:
    # Escrever no S3 com particionamento multi-nível
    df_slim.write \
        .mode("append") \
        .partitionBy("alert_type", "event_year", "event_month", "event_day") \
        .parquet(OUTPUT_PATH)
    
    print(" Write completed successfully")
    print(f"   Records written: {df_slim.count()}")
    
except Exception as e:
    print(f" ERROR writing to S3: {str(e)}")
    raise

# 
# 7. FINALIZAÇÃO
# 

print("\n" + "" * 80)
print(" JOB COMPLETED SUCCESSFULLY")
print("" * 80)
print(f" Summary:")
print(f"   • Total alerts processed: {df_slim.count()}")
print(f"   • Alert types: {df_enriched.select('alert_type').distinct().count()}")
print(f"   • Output location: {OUTPUT_PATH}")
print(f"   • Schema: SLIM (7 columns only)")
print(f"   • Mode: Incremental (Job Bookmarks enabled)")
print("" * 80)

# Commit do Job (salvar estado do Bookmark)
job.commit()
