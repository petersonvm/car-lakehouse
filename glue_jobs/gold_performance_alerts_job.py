"""
AWS Glue Job: Gold Performance Alerts Log
=========================================

Objetivo:
    Criar tabela Gold com histórico de alertas de performance (KPIs críticos).
    Filtra registros Silver que violam limites operacionais e classifica por tipo de alerta.

Camada: Gold (Agregação/Alertas)
Entrada: analytics_db.silver_car_telemetry
Saída: s3://[gold-bucket]/performance_alerts_log/ (append mode)

Lógica de Negócio (KPIs de Alerta):
    - KPI 2 (Temperatura Motor): engineTempCelsius > 100
    - KPI 2 (Temperatura Óleo): oilTempCelsius > 110  
    - KPI 5 (Velocidade Máxima): tripMaxSpeedKm > 110

Particionamento: alert_type, event_year, event_month, event_day

Job Bookmarks: Habilitado (processamento incremental)
Modo Escrita: Append (histórico cumulativo de infrações)

Author: AWS Glue Agent
Date: 2025-10-31
"""

import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql import functions as F
from pyspark.sql.types import StringType
from datetime import datetime
import logging

# ============================================================
# CONFIGURAÇÃO DE LOGGING
# ============================================================
logger = logging.getLogger()
logger.setLevel(logging.INFO)
handler = logging.StreamHandler(sys.stdout)
handler.setLevel(logging.INFO)
formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
handler.setFormatter(formatter)
logger.addHandler(handler)

# ============================================================
# INICIALIZAÇÃO DO JOB GLUE
# ============================================================
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'gold_bucket',
    'glue_database'
])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

logger.info("="*60)
logger.info(f"Job: {args['JOB_NAME']}")
logger.info(f"Gold Bucket: {args['gold_bucket']}")
logger.info(f"Database: {args['glue_database']}")
logger.info("="*60)

# ============================================================
# LEITURA INCREMENTAL - SILVER LAYER (COM JOB BOOKMARKS)
# ============================================================
logger.info("📖 Lendo dados Silver com Job Bookmarks (incremental)...")

try:
    # Leitura incremental usando GlueContext e transformation_ctx
    dyf_silver = glueContext.create_dynamic_frame.from_catalog(
        database=args['glue_database'],
        table_name="silver_car_telemetry",
        transformation_ctx="read_silver_telemetry"  # Habilita Job Bookmarks
    )
    
    # Converter DynamicFrame para DataFrame Spark
    df_silver = dyf_silver.toDF()
    
    initial_count = df_silver.count()
    logger.info(f"✅ Registros Silver lidos (novos desde último bookmark): {initial_count}")
    
    if initial_count == 0:
        logger.warning("⚠️ Nenhum dado novo para processar (Job Bookmark marca tudo como processado)")
        logger.info("Finalizando job com sucesso (sem novos alertas)")
        job.commit()
        sys.exit(0)
    
    logger.info(f"📊 Schema Silver: {df_silver.columns}")
    
except Exception as e:
    logger.error(f"❌ Erro ao ler dados Silver: {str(e)}")
    raise

# ============================================================
# LÓGICA DE FILTRAGEM - KPIs DE ALERTA
# ============================================================
logger.info("🔍 Aplicando filtros de KPIs de Performance...")

# Definir limites de alerta (KPIs)
KPI_ENGINE_TEMP_LIMIT = 100  # Celsius
KPI_OIL_TEMP_LIMIT = 110     # Celsius
KPI_MAX_SPEED_LIMIT = 120    # km/h

logger.info(f"   • KPI 2 - Temperatura Motor: > {KPI_ENGINE_TEMP_LIMIT}°C")
logger.info(f"   • KPI 2 - Temperatura Óleo: > {KPI_OIL_TEMP_LIMIT}°C")
logger.info(f"   • KPI 5 - Velocidade Máxima: > {KPI_MAX_SPEED_LIMIT} km/h")

# Filtro OR: qualquer violação gera um alerta
df_alerts = df_silver.filter(
    (F.col("metrics_engineTempCelsius") > KPI_ENGINE_TEMP_LIMIT) |
    (F.col("metrics_oilTempCelsius") > KPI_OIL_TEMP_LIMIT) |
    (F.col("metrics_trip_tripMaxSpeedKm") > KPI_MAX_SPEED_LIMIT)
)

alerts_count = df_alerts.count()
logger.info(f"⚠️ Total de ALERTAS detectados: {alerts_count}")

if alerts_count == 0:
    logger.info("✅ Nenhum alerta detectado neste lote (todos os valores dentro dos limites)")
    logger.info("Finalizando job com sucesso (sem alertas)")
    job.commit()
    sys.exit(0)

# ============================================================
# ENRIQUECIMENTO - CLASSIFICAÇÃO DE ALERTAS
# ============================================================
logger.info("🏷️ Classificando tipo de alerta...")

# UDF para determinar o tipo de alerta (pode ter múltiplos tipos por registro)
def classify_alert(engine_temp, oil_temp, max_speed):
    """
    Classifica o tipo de alerta baseado nas violações.
    Retorna o tipo mais crítico (prioridade: motor > óleo > velocidade).
    """
    if engine_temp is not None and engine_temp > KPI_ENGINE_TEMP_LIMIT:
        return "OVERHEAT_ENGINE"
    elif oil_temp is not None and oil_temp > KPI_OIL_TEMP_LIMIT:
        return "OVERHEAT_OIL"
    elif max_speed is not None and max_speed > KPI_MAX_SPEED_LIMIT:
        return "SPEEDING_ALERT"
    else:
        return "UNKNOWN"

classify_alert_udf = F.udf(classify_alert, StringType())

# Adicionar coluna alert_type
df_alerts_classified = df_alerts.withColumn(
    "alert_type",
    classify_alert_udf(
        F.col("metrics_engineTempCelsius"),
        F.col("metrics_oilTempCelsius"),
        F.col("metrics_trip_tripMaxSpeedKm")
    )
)

# Adicionar timestamp de processamento do alerta
df_alerts_classified = df_alerts_classified.withColumn(
    "alert_processed_timestamp",
    F.lit(datetime.now().isoformat())
)

# Estatísticas por tipo de alerta
logger.info("📊 Distribuição de alertas por tipo:")
alert_stats = df_alerts_classified.groupBy("alert_type").count().collect()
for row in alert_stats:
    logger.info(f"   • {row['alert_type']}: {row['count']} alertas")

# ============================================================
# ESCRITA - GOLD LAYER (APPEND MODE, PARTICIONADO)
# ============================================================
logger.info("💾 Escrevendo alertas no Gold Layer...")

output_path = f"s3://{args['gold_bucket']}/performance_alerts_log/"
logger.info(f"Caminho de saída: {output_path}")
logger.info(f"Modo: APPEND (histórico cumulativo)")
logger.info(f"Particionamento: alert_type, event_year, event_month, event_day")

try:
    # Escrever no formato Parquet com particionamento
    df_alerts_classified.write \
        .mode("append") \
        .partitionBy("alert_type", "event_year", "event_month", "event_day") \
        .parquet(output_path)
    
    logger.info("✅ Alertas escritos com sucesso no Gold!")
    logger.info(f"📊 Total de alertas persistidos: {alerts_count}")
    
except Exception as e:
    logger.error(f"❌ Erro ao escrever no Gold: {str(e)}")
    raise

# ============================================================
# ESTATÍSTICAS FINAIS
# ============================================================
logger.info("="*60)
logger.info("📈 ESTATÍSTICAS FINAIS DO JOB")
logger.info("="*60)
logger.info(f"Registros Silver processados: {initial_count}")
logger.info(f"Alertas gerados: {alerts_count}")
logger.info(f"Taxa de violação: {(alerts_count/initial_count*100):.2f}%")
logger.info(f"Destino: {output_path}")
logger.info("="*60)

# Commit do Job (atualiza Job Bookmark)
job.commit()
logger.info("✅ Job finalizado com sucesso!")
