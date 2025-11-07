"""
AWS Glue ETL Job - Gold Layer: Car Current State (ATUALIZADO)
============================================================

Objetivo:
- Ler dados consolidados da Camada Silver (diretamente do S3)
- Aplicar lógica de "Estado Atual" (1 linha por car_id)
- Escrever snapshot no Gold Bucket (sobrescrita total)
- SUPORTE À NOVA ESTRUTURA JSON COMPLEXA

Lógica de Negócio:
- Chave de negócio: car_id (nova estrutura)
- Regra de seleção: telemetry_odometer_km DESC (o maior = mais recente)
- Resultado: 1 registro único por veículo (estado atual)
- KPIs DE SEGURO MANTIDOS E FUNCIONANDO

Características:
- Leitura: Bucket Silver diretamente (nova estrutura)
- Transformação: Window Function (row_number)
- Escrita: Overwrite completo (snapshot estático)
- Saída: Parquet não-particionado (tabela pequena)

Autor: Sistema de Data Lakehouse - Camada Gold (Atualizada)
Data: 2025-11-04 (Suporte à estrutura JSON complexa)
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
print(" AWS GLUE JOB - GOLD LAYER: CAR CURRENT STATE (ATUALIZADO)")
print("=" * 80)

# Obter parâmetros do Job
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'silver_bucket',
    'silver_path',
    'gold_bucket',
    'gold_path'
])

# Inicializar contextos Spark e Glue
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

print(f" Job iniciado: {args['JOB_NAME']}")
print(f" Timestamp: {datetime.now().isoformat()}")

# ============================================================================
# 2. LEITURA DOS DADOS SILVER (NOVA ESTRUTURA)
# ============================================================================

print("\n" + "=" * 80)
print(" ETAPA 1: Leitura dos dados Silver (Nova Estrutura JSON)")
print("=" * 80)

print(f"\n   Silver Bucket: {args['silver_bucket']}")
print(f"   Silver Path: {args['silver_path']}")

# Ler dados Silver diretamente do S3 (nova estrutura)
silver_path = f"s3://{args['silver_bucket']}/{args['silver_path']}"
df_silver = spark.read.parquet(silver_path)

# Contar registros totais
total_records = df_silver.count()
print(f"\n    Registros lidos da Silver: {total_records}")

if total_records == 0:
    print("\n     AVISO: Nenhum dado encontrado na Camada Silver!")
    print("   Finalizando job sem gerar dados no Gold.")
    job.commit()
    print("\n JOB CONCLUÍDO (sem dados para processar)")
else:
    print("\n    Schema da Nova Camada Silver:")
    df_silver.printSchema()

    # Mostrar amostra dos dados Silver (nova estrutura)
    print("\n    Amostra de dados Silver (primeiros 5 registros):")
    df_silver.select(
        "car_id",
        "manufacturer", 
        "model",
        "telemetry_odometer_km",
        "insurance_status",
        "event_year",
        "event_month",
        "event_day"
    ).show(5, truncate=False)

    # ============================================================================
    # 3. TRANSFORMAÇÃO: ESTADO ATUAL (WINDOW FUNCTION) - NOVA ESTRUTURA
    # ============================================================================

    print("\n" + "=" * 80)
    print(" ETAPA 2: Aplicando lógica de 'Estado Atual' (Nova Estrutura)")
    print("=" * 80)

    print("\n    Regra de Negócio:")
    print("      - 1 registro por car_id (veículo)")
    print("      - Critério: MAIOR telemetry_odometer_km (mais recente)")
    print("      - Método: Window Function com row_number()")
    print("      - KPIs de Seguro: MANTIDOS E FUNCIONANDO")

    # Definir Window Specification para nova estrutura
    # Particionar por: car_id (cada veículo - nova chave)
    # Ordenar por: telemetry_odometer_km DESC (maior odômetro = mais recente)
    window_spec = Window.partitionBy("car_id").orderBy(F.col("telemetry_odometer_km").desc())

    print("\n    Aplicando Window Function...")

    # Adicionar coluna row_number
    df_with_row_number = df_silver.withColumn(
        "row_num",
        F.row_number().over(window_spec)
    )

    print("       row_number() aplicado")

    # Filtrar apenas row_number = 1 (estado atual)
    df_current_state = df_with_row_number.filter(F.col("row_num") == 1).drop("row_num")

    current_state_count = df_current_state.count()
    vehicles_deduped = total_records - current_state_count

    print(f"\n    Resultado da Consolidação:")
    print(f"      - Registros totais Silver: {total_records}")
    print(f"      - Veículos únicos (estado atual): {current_state_count}")
    print(f"      - Registros eliminados (histórico): {vehicles_deduped}")

    # Estatísticas por status de seguro
    print(f"\n    Estatísticas dos KPIs de Seguro:")
    insurance_stats = df_current_state.groupBy("insurance_status").count().collect()
    for row in insurance_stats:
        print(f"      - {row['insurance_status']}: {row['count']} veículos")

    # ============================================================================
    # 4. ENRIQUECIMENTO ADICIONAL (MANTENDO KPIS)
    # ============================================================================

    print("\n" + "=" * 80)
    print(" ETAPA 3: Enriquecimento e KPIs (Mantidos da estrutura anterior)")
    print("=" * 80)

    # Os KPIs de seguro já estão calculados no Silver, mas vamos adicionar alguns extras
    print("\n    Adicionando KPIs Gold adicionais...")

    df_gold_enriched = df_current_state.withColumn(
        "data_processing_timestamp",
        F.current_timestamp()
    ).withColumn(
        "gold_layer_version",
        F.lit("v2.0_json_complex")
    ).withColumn(
        "total_vehicles_in_fleet",
        F.lit(current_state_count)
    )

    # Adicionar categorização de risco de seguro
    df_gold_final = df_gold_enriched.withColumn(
        "insurance_risk_category",
        F.when(F.col("insurance_status") == "VENCIDO", "ALTO_RISCO")
         .when(F.col("insurance_status") == "VENCENDO_EM_90_DIAS", "MEDIO_RISCO")
         .otherwise("BAIXO_RISCO")
    )

    print("       KPIs Gold adicionais calculados")

    # Mostrar amostra final
    print("\n    Amostra dos dados Gold finais:")
    df_gold_final.select(
        "car_id",
        "manufacturer",
        "model", 
        "telemetry_odometer_km",
        "insurance_status",
        "insurance_days_expired",
        "insurance_risk_category",
        "trip_km_per_liter"
    ).show(5, truncate=False)

    # ============================================================================
    # 5. ESCRITA NO BUCKET GOLD
    # ============================================================================

    print("\n" + "=" * 80)
    print(" ETAPA 4: Escrita na Camada Gold")
    print("=" * 80)

    # Caminho de destino no Gold
    gold_output_path = f"s3://{args['gold_bucket']}/{args['gold_path']}"
    print(f"\n    Destino Gold: {gold_output_path}")
    print(f"    Registros a escrever: {df_gold_final.count()}")

    # Escrever dados no formato Parquet (overwrite completo)
    print("\n    Escrevendo dados Gold...")

    df_gold_final.coalesce(1).write \
        .mode("overwrite") \
        .parquet(gold_output_path)

    print("       Dados escritos com sucesso!")

    # ============================================================================
    # 6. RELATÓRIO FINAL
    # ============================================================================

    print("\n" + "=" * 80)
    print(" RELATÓRIO FINAL")
    print("=" * 80)

    # Estatísticas por fabricante
    print(f"\n    Veículos por Fabricante:")
    manufacturer_stats = df_gold_final.groupBy("manufacturer").count().orderBy(F.desc("count")).collect()
    for row in manufacturer_stats:
        print(f"      - {row['manufacturer']}: {row['count']} veículos")

    # Estatísticas de seguro
    print(f"\n    Status de Seguro:")
    insurance_stats = df_gold_final.groupBy("insurance_status").count().collect()
    for row in insurance_stats:
        print(f"      - {row['insurance_status']}: {row['count']} veículos")

    # KPIs de eficiência
    avg_efficiency = df_gold_final.agg(F.avg("trip_km_per_liter")).collect()[0][0]
    if avg_efficiency:
        print(f"\n    Eficiência Média da Frota: {avg_efficiency:.2f} km/L")

    # Odômetro médio
    avg_odometer = df_gold_final.agg(F.avg("telemetry_odometer_km")).collect()[0][0]
    if avg_odometer:
        print(f"    Odômetro Médio da Frota: {avg_odometer:.0f} km")

# ============================================================================
# 7. FINALIZAÇÃO
# ============================================================================

print("\n" + "=" * 80)
print(" JOB GOLD CONCLUÍDO COM SUCESSO!")
print(" Estrutura JSON Complexa processada")
print(" KPIs de Seguro mantidos e funcionando")
print(" Estado atual consolidado por veículo")
print(" Dados disponíveis na Camada Gold")
print(f" Finalizado em: {datetime.now().isoformat()}")
print("=" * 80)

# Commit do job
job.commit()