"""
AWS Glue ETL Job - Gold Performance Alerts Slim (REFATORADO - car_silver)
========================================================================

REFATORAÇÃO: Atualização para ler da nova tabela Silver
De: silver_car_telemetry → Para: car_silver

Objetivo:
- Ler dados da camada Silver (nova tabela car_silver)
- Detectar problemas de performance e gerar alertas
- Produzir versão "slim" dos alertas (apenas críticos)
- Suportar monitoramento em tempo real

Tipos de Alertas:
- Low battery (<20%)
- Low fuel (<10% capacity)
- High engine temperature (>100°C)
- Low oil life (<25%)
- Tire pressure issues
- Insurance expiry alerts

Source: car_silver (via Glue Catalog) - ATUALIZADO
Output: performance_alerts_log_slim

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
from pyspark.sql.functions import col, when, lit, current_timestamp, to_date, current_date, datediff
from datetime import datetime

# ============================================================================
# 1. CONFIGURAÇÃO E INICIALIZAÇÃO
# ============================================================================

print("\n" + "=" * 80)
print("🚨 AWS GLUE JOB - GOLD PERFORMANCE ALERTS SLIM (REFATORADO)")
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
    dyf_silver_telemetry = glueContext.create_dynamic_frame.from_catalog(
        database=DATABASE_NAME,
        table_name=SILVER_TABLE,  # ATUALIZADO: car_silver
        transformation_ctx="dyf_silver_source",
        # Job bookmark para processar apenas dados novos
        additional_options={"jobBookmarkKeys": ["event_id"], "jobBookmarkKeysSortOrder": "asc"}
    )
    
    df_silver = dyf_silver_telemetry.toDF()
    
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
# 3. DETECÇÃO DE ALERTAS (VERSÃO SLIM - APENAS CRÍTICOS)
# ============================================================================

print("\n🚨 ETAPA 2: Detecção de alertas críticos...")

# Configurações de limites críticos (versão slim)
CRITICAL_BATTERY_THRESHOLD = 20
CRITICAL_FUEL_THRESHOLD = 0.1  # 10% da capacidade
CRITICAL_ENGINE_TEMP = 100
CRITICAL_OIL_LIFE = 25
CRITICAL_TIRE_PRESSURE_MIN = 28
CRITICAL_TIRE_PRESSURE_MAX = 40
INSURANCE_WARNING_DAYS = 30

# Base DataFrame com informações essenciais
df_base = df_silver.select(
    "event_id",
    "event_timestamp", 
    "car_chassis",
    "manufacturer",
    "model",
    "current_mileage_km",
    "battery_charge_percentage",
    "fuel_available_liters",
    "fuel_capacity_liters",
    "engine_temp_celsius",
    "oil_life_percentage",
    "tire_pressure_front_left_psi",
    "tire_pressure_front_right_psi", 
    "tire_pressure_rear_left_psi",
    "tire_pressure_rear_right_psi",
    "insurance_valid_until",
    "rental_agreement_id"
)

# Detectar alertas críticos apenas
alerts_list = []

# 1. BATERIA CRÍTICA
battery_alerts = df_base.filter(
    col("battery_charge_percentage") < CRITICAL_BATTERY_THRESHOLD
).select(
    "*",
    lit("CRITICAL").alias("alert_severity"),
    lit("LOW_BATTERY").alias("alert_type"),
    F.concat(lit("Bateria crítica: "), col("battery_charge_percentage"), lit("%")).alias("alert_message"),
    col("battery_charge_percentage").alias("alert_value")
)

# 2. COMBUSTÍVEL CRÍTICO  
fuel_alerts = df_base.filter(
    col("fuel_available_liters") < (col("fuel_capacity_liters") * CRITICAL_FUEL_THRESHOLD)
).select(
    "*",
    lit("CRITICAL").alias("alert_severity"),
    lit("LOW_FUEL").alias("alert_type"),
    F.concat(lit("Combustível crítico: "), 
            F.round(col("fuel_available_liters"), 1), lit(" L")).alias("alert_message"),
    col("fuel_available_liters").alias("alert_value")
)

# 3. TEMPERATURA DO MOTOR CRÍTICA
engine_temp_alerts = df_base.filter(
    col("engine_temp_celsius") > CRITICAL_ENGINE_TEMP
).select(
    "*",
    lit("CRITICAL").alias("alert_severity"),
    lit("HIGH_ENGINE_TEMP").alias("alert_type"),
    F.concat(lit("Temperatura do motor alta: "), col("engine_temp_celsius"), lit("°C")).alias("alert_message"),
    col("engine_temp_celsius").alias("alert_value")
)

# 4. VIDA ÚTIL DO ÓLEO CRÍTICA
oil_alerts = df_base.filter(
    col("oil_life_percentage") < CRITICAL_OIL_LIFE
).select(
    "*",
    lit("CRITICAL").alias("alert_severity"),
    lit("LOW_OIL_LIFE").alias("alert_type"),
    F.concat(lit("Vida útil do óleo baixa: "), col("oil_life_percentage"), lit("%")).alias("alert_message"),
    col("oil_life_percentage").alias("alert_value")
)

# 5. SEGURO PRÓXIMO AO VENCIMENTO
insurance_alerts_temp = df_base.filter(
    datediff(to_date(col("insurance_valid_until")), current_date()) <= INSURANCE_WARNING_DAYS
).withColumn(
    "days_to_expiry", 
    datediff(to_date(col("insurance_valid_until")), current_date())
).withColumn(
    "alert_severity", lit("WARNING")
).withColumn(
    "alert_type", lit("INSURANCE_EXPIRY")
).withColumn(
    "alert_message", F.concat(lit("Seguro vence em "), col("days_to_expiry"), lit(" dias"))
).withColumn(
    "alert_value", col("days_to_expiry")
)

# Remover a coluna days_to_expiry para manter consistência no UNION
insurance_alerts = insurance_alerts_temp.drop("days_to_expiry")

# Unir todos os alertas
all_alerts_df = battery_alerts.union(fuel_alerts) \
                              .union(engine_temp_alerts) \
                              .union(oil_alerts) \
                              .union(insurance_alerts)

alerts_count = all_alerts_df.count() if all_alerts_df.count() > 0 else 0
print(f"   🚨 Total de alertas críticos detectados: {alerts_count}")

# ============================================================================
# 4. PROCESSAMENTO FINAL DOS ALERTAS
# ============================================================================

print("\n📊 ETAPA 3: Processamento final dos alertas...")

if alerts_count > 0:
    # Adicionar metadados aos alertas
    df_alerts_final = all_alerts_df.withColumn(
        "alert_timestamp", current_timestamp()
    ).withColumn(
        "processing_date", F.current_date().cast("string")
    ).withColumn(
        "alert_id", 
        F.concat(col("car_chassis"), lit("_"), col("alert_type"), lit("_"), 
                F.unix_timestamp(current_timestamp()).cast("string"))
    ).select(
        "alert_id",
        "event_id",
        "event_timestamp",
        "car_chassis", 
        "manufacturer",
        "model",
        "alert_type",
        "alert_severity",
        "alert_message",
        "alert_value",
        "alert_timestamp",
        "current_mileage_km",
        "rental_agreement_id",
        "processing_date"
    )
    
    print(f"   ✅ Alertas processados e formatados!")
    
    # ========================================================================
    # 5. GRAVAÇÃO NO GOLD LAYER
    # ========================================================================
    
    print("\n💾 ETAPA 4: Gravação dos alertas no Gold Layer...")
    
    print(f"   📊 Alertas a gravar: {df_alerts_final.count()}")
    print(f"   📍 Destino: s3://{GOLD_BUCKET}/{GOLD_PATH}")
    
    # Converter para DynamicFrame
    dyf_alerts_final = DynamicFrame.fromDF(df_alerts_final, glueContext, "dyf_alerts_final")
    
    # Gravar alertas particionados por data
    glueContext.write_dynamic_frame.from_options(
        frame=dyf_alerts_final,
        connection_type="s3",
        connection_options={
            "path": f"s3://{GOLD_BUCKET}/{GOLD_PATH}",
            "partitionKeys": ["processing_date"]
        },
        format="glueparquet",
        format_options={
            "compression": "snappy"
        },
        transformation_ctx="write_gold_alerts"
    )
    
    print("   ✅ Alertas gravados no Gold Layer!")
    
    # Estatísticas por tipo de alerta
    alert_types_stats = df_alerts_final.groupBy("alert_type", "alert_severity").count().collect()
    
    print(f"\n   📋 ALERTAS POR TIPO:")
    for row in alert_types_stats:
        print(f"      • {row['alert_type']} ({row['alert_severity']}): {row['count']}")

else:
    print("   ✅ Nenhum alerta crítico detectado!")
    print("   📝 Nenhum dado será gravado (frota operando normalmente)")

# ============================================================================
# 6. ESTATÍSTICAS FINAIS
# ============================================================================

print("\n📊 ESTATÍSTICAS FINAIS:")
print(f"   📥 Registros Silver processados: {record_count}")
print(f"   🚨 Alertas críticos gerados: {alerts_count}")
print(f"   📝 Fonte Silver: {DATABASE_NAME}.{SILVER_TABLE}")

if alerts_count > 0:
    # Mostrar veículos com mais alertas
    vehicles_with_alerts = df_alerts_final.groupBy("car_chassis", "manufacturer", "model") \
                                         .count() \
                                         .orderBy(col("count").desc()) \
                                         .limit(3) \
                                         .collect()
    
    print(f"\n   🚗 VEÍCULOS COM MAIS ALERTAS:")
    for i, row in enumerate(vehicles_with_alerts, 1):
        print(f"      {i}. {row['manufacturer']} {row['model']} (Chassis: {row['car_chassis'][-8:]}): {row['count']} alertas")

print("\n" + "=" * 80)
print("🎉 Gold Performance Alerts Slim Job - REFATORAÇÃO CONCLUÍDA COM SUCESSO!")
print(f"📝 Nova fonte Silver: {SILVER_TABLE}")
print(f"🕒 Timestamp final: {datetime.now().isoformat()}")
print("=" * 80)

# Commit do job
job.commit()