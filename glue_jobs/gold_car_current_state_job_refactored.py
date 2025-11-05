"""
AWS Glue ETL Job - Gold Layer: Car Current State (REFATORADO - car_silver)
========================================================================

REFATORAÇÃO: Atualização para ler da nova tabela Silver
De: silver_car_telemetry_new → Para: car_silver

Objetivo:
- Ler dados processados da Camada Silver (nova tabela car_silver)
- Aplicar lógica de "Estado Atual" por carChassis
- Enriquecer com KPIs e métricas Gold
- Escrever snapshot consolidado no Gold Bucket

Lógica de Negócio:
- Chave de negócio: car_chassis (carChassis)
- Regra de seleção: current_mileage_km DESC + event_timestamp DESC
- Resultado: 1 registro único por veículo (estado atual)

Nova Estrutura:
- Campos do car_raw.json processados pelo Silver (tabela car_silver)
- KPIs de seguro: insurance_status, insurance_days_expired
- Métricas de eficiência: fuel_efficiency_l_per_100km
- Status de manutenção: oil_status

Características:
- Leitura: Dados da tabela car_silver (via Glue Catalog)
- Transformação: Window Function + enriquecimento Gold
- Escrita: Overwrite completo (snapshot Gold)
- Saída: Parquet consolidado

Autor: Sistema de Data Lakehouse - Camada Gold (Refatorado)
Data: 2025-11-05 (Refatoração: silver_car_telemetry_new → car_silver)
"""

import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job

from pyspark.sql import functions as F
from pyspark.sql.window import Window
from pyspark.sql.functions import col, to_date, current_date, datediff, when, lit
from datetime import datetime

# ============================================================================
# 1. INICIALIZAÇÃO DO JOB
# ============================================================================

print("\n" + "=" * 80)
print("🥇 AWS GLUE JOB - GOLD LAYER: CAR CURRENT STATE (REFATORADO)")
print("📝 Fonte Silver: car_silver (anteriormente: silver_car_telemetry_new)")
print("=" * 80)

# Obter parâmetros do Job
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'database_name',        # NOVO: Para usar Glue Catalog
    'silver_table_name',    # NOVO: Nome da tabela Silver (car_silver)
    'gold_bucket',
    'gold_path'
])

# Inicializar contextos
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

print(f"\n📋 PARÂMETROS DO JOB:")
print(f"   🗃️  Database: {args['database_name']}")
print(f"   📥 Tabela Silver: {args['silver_table_name']}")  # NOVO PARÂMETRO
print(f"   📤 Gold: s3://{args['gold_bucket']}/{args['gold_path']}")
print(f"   🔧 Job Name: {args['JOB_NAME']}")

# ============================================================================
# 2. LEITURA DOS DADOS SILVER (NOVA TABELA: car_silver)
# ============================================================================

print("\n📖 ETAPA 1: Leitura dos dados Silver (nova tabela car_silver)...")

try:
    # Leitura usando Glue Catalog - TABELA RENOMEADA
    dyf_silver = glueContext.create_dynamic_frame.from_catalog(
        database=args['database_name'],
        table_name=args['silver_table_name'],  # ATUALIZADO: car_silver
        transformation_ctx="dyf_silver_source"
    )
    
    # Converter para DataFrame
    df_silver = dyf_silver.toDF()
    
    silver_records_count = df_silver.count()
    print(f"   ✅ Registros Silver lidos: {silver_records_count}")
    print(f"   📊 Campos Silver: {len(df_silver.columns)}")
    print(f"   📝 Fonte: {args['database_name']}.{args['silver_table_name']}")
    
    if silver_records_count == 0:
        print("   ⚠️  AVISO: Nenhum registro encontrado no Silver!")
        print("   🔄 Encerrando job (sem dados para processar)")
        job.commit()
        sys.exit(0)
        
except Exception as e:
    print(f"   ❌ ERRO na leitura Silver: {str(e)}")
    print(f"   🔍 Verifique se a tabela {args['silver_table_name']} existe no database {args['database_name']}")
    raise e

# ============================================================================
# 3. LÓGICA DE NEGÓCIO: ESTADO ATUAL POR VEÍCULO
# ============================================================================

print("\n🔄 ETAPA 2: Aplicando lógica de Estado Atual por veículo...")

# Window para selecionar o registro mais recente por car_chassis
# Critério: current_mileage_km DESC, event_timestamp DESC
window_latest = Window.partitionBy("car_chassis").orderBy(
    F.col("current_mileage_km").desc(),
    F.col("event_timestamp").desc()
)

# Adicionar ranking
df_with_rank = df_silver.withColumn("rank", F.row_number().over(window_latest))

# Filtrar apenas o estado atual (rank = 1)
df_current_state = df_with_rank.filter(F.col("rank") == 1).drop("rank")

current_vehicles_count = df_current_state.count()
print(f"   ✅ Veículos únicos processados: {current_vehicles_count}")
print(f"   📊 Registros de estado atual: {df_current_state.count()}")

# ============================================================================
# 4. ENRIQUECIMENTO COM KPIS GOLD
# ============================================================================

print("\n📊 ETAPA 3: Enriquecimento com KPIs Gold...")

# Calcular KPIs adicionais
df_gold_enriched = df_current_state.withColumn(
    # KPI: Status do seguro (válido ou expirado)
    "insurance_status",
    when(
        to_date(col("insurance_valid_until")) >= current_date(),
        "VALID"
    ).otherwise("EXPIRED")
).withColumn(
    # KPI: Dias até expiração do seguro
    "insurance_days_to_expiry",
    datediff(to_date(col("insurance_valid_until")), current_date())
).withColumn(
    # KPI: Eficiência de combustível (estimativa simples)
    "fuel_efficiency_l_per_100km",
    when(
        col("trip_mileage_km") > 0,
        (col("trip_fuel_liters") / col("trip_mileage_km") * 100).cast("double")
    ).otherwise(lit(None))
).withColumn(
    # KPI: Status do óleo
    "oil_status",
    when(col("oil_life_percentage") >= 50, "GOOD")
    .when(col("oil_life_percentage") >= 25, "FAIR")
    .when(col("oil_life_percentage") >= 10, "LOW")
    .otherwise("CRITICAL")
).withColumn(
    # KPI: Status da bateria
    "battery_status",
    when(col("battery_charge_percentage") >= 80, "FULL")
    .when(col("battery_charge_percentage") >= 50, "GOOD")
    .when(col("battery_charge_percentage") >= 20, "LOW")
    .otherwise("CRITICAL")
).withColumn(
    # KPI: Fuel level status
    "fuel_status",
    when(col("fuel_available_liters") >= (col("fuel_capacity_liters") * 0.5), "FULL")
    .when(col("fuel_available_liters") >= (col("fuel_capacity_liters") * 0.25), "HALF")
    .when(col("fuel_available_liters") >= (col("fuel_capacity_liters") * 0.1), "LOW")
    .otherwise("CRITICAL")
).withColumn(
    # Timestamp de processamento Gold
    "gold_processing_timestamp",
    F.current_timestamp()
).withColumn(
    # Data de processamento (partição)
    "processing_date",
    F.current_date().cast("string")
)

print(f"   ✅ KPIs Gold adicionados!")
print(f"   📊 Total de campos Gold: {len(df_gold_enriched.columns)}")

# ============================================================================
# 5. GRAVAÇÃO NO GOLD LAYER
# ============================================================================

print("\n💾 ETAPA 4: Gravação no Gold Layer...")

# Preparar dados finais
df_gold_final = df_gold_enriched

print(f"   📊 Total de registros a gravar: {df_gold_final.count()}")
print(f"   📍 Destino Gold: s3://{args['gold_bucket']}/{args['gold_path']}")

# Converter para DynamicFrame para gravação
dynamic_frame_gold = DynamicFrame.fromDF(df_gold_final, glueContext, "dynamic_frame_gold")

# Gravar no Gold (overwrite completo para snapshot)
glueContext.write_dynamic_frame.from_options(
    frame=dynamic_frame_gold,
    connection_type="s3",
    connection_options={
        "path": f"s3://{args['gold_bucket']}/{args['gold_path']}",
        "partitionKeys": ["processing_date"]
    },
    format="glueparquet",
    format_options={
        "compression": "snappy"
    },
    transformation_ctx="datasink_gold_current_state"
)

print("   ✅ Dados gravados no Gold Layer com sucesso!")

# ============================================================================
# 6. ESTATÍSTICAS FINAIS E ENCERRAMENTO
# ============================================================================

print("\n📊 ESTATÍSTICAS FINAIS:")
print(f"   📥 Registros lidos do Silver: {silver_records_count}")
print(f"   🚗 Veículos únicos processados: {current_vehicles_count}")
print(f"   📤 Registros gravados no Gold: {df_gold_final.count()}")
print(f"   🎯 Campos Gold total: {len(df_gold_final.columns)}")
print(f"   📝 Fonte Silver: {args['database_name']}.{args['silver_table_name']}")

# Mostrar KPIs criados
kpi_fields = [
    "insurance_status", "insurance_days_to_expiry", 
    "fuel_efficiency_l_per_100km", "oil_status", 
    "battery_status", "fuel_status"
]

print(f"\n   📋 KPIs Gold criados:")
for i, kpi in enumerate(kpi_fields, 1):
    print(f"      {i}. {kpi}")

print("\n" + "=" * 80)
print("🎉 Gold Car Current State Job - REFATORAÇÃO CONCLUÍDA COM SUCESSO!")
print(f"📝 Nova fonte Silver: {args['silver_table_name']}")
print(f"🕒 Timestamp final: {datetime.now().isoformat()}")
print("=" * 80)

# Commit do job
job.commit()