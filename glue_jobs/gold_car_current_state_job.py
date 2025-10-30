"""
AWS Glue ETL Job - Gold Layer: Car Current State
=================================================

Objetivo:
- Ler dados consolidados da Camada Silver (histórico completo)
- Aplicar lógica de "Estado Atual" (1 linha por carChassis)
- Escrever snapshot no Gold Bucket (sobrescrita total)

Lógica de Negócio:
- Chave de negócio: carChassis
- Regra de seleção: currentMileage DESC (o maior = mais recente)
- Resultado: 1 registro único por veículo (estado atual)

Características:
- Leitura: Tabela Silver completa (sem particionamento)
- Transformação: Window Function (row_number)
- Escrita: Overwrite completo (snapshot estático)
- Saída: Parquet não-particionado (tabela pequena)

Autor: Sistema de Data Lakehouse - Camada Gold
Data: 2025-10-30
"""

import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job

from pyspark.sql import functions as F
from pyspark.sql.window import Window
from datetime import datetime

# ============================================================================
# 1. INICIALIZAÇÃO DO JOB
# ============================================================================

print("\n" + "=" * 80)
print("🥇 AWS GLUE JOB - GOLD LAYER: CAR CURRENT STATE")
print("=" * 80)

# Obter parâmetros do Job
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'silver_database',
    'silver_table',
    'gold_database',
    'gold_bucket',
    'gold_path'
])

print(f"\n📋 Parâmetros do Job:")
print(f"   Job Name: {args['JOB_NAME']}")
print(f"   Silver Database: {args['silver_database']}")
print(f"   Silver Table: {args['silver_table']}")
print(f"   Gold Database: {args['gold_database']}")
print(f"   Gold Bucket: {args['gold_bucket']}")
print(f"   Gold Path: {args['gold_path']}")

# Inicializar contextos Spark e Glue
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

print("\n✅ Contextos Spark e Glue inicializados com sucesso")

# ============================================================================
# 2. LEITURA DA CAMADA SILVER
# ============================================================================

print("\n" + "=" * 80)
print("📚 ETAPA 1: Lendo dados consolidados da Camada Silver")
print("=" * 80)

print(f"\n   Database: {args['silver_database']}")
print(f"   Table: {args['silver_table']}")

# Ler tabela Silver completa do Glue Data Catalog
silver_dynamic_frame = glueContext.create_dynamic_frame.from_catalog(
    database=args['silver_database'],
    table_name=args['silver_table'],
    transformation_ctx="silver_data"
)

# Converter para DataFrame
df_silver = silver_dynamic_frame.toDF()

# Contar registros totais
total_records = df_silver.count()
print(f"\n   ✅ Registros lidos da Silver: {total_records}")

if total_records == 0:
    print("\n   ⚠️  AVISO: Nenhum dado encontrado na Camada Silver!")
    print("   Finalizando job sem gerar dados no Gold.")
    job.commit()
    print("\n✅ JOB CONCLUÍDO (sem dados para processar)")
    # Não usar sys.exit() - deixar completar naturalmente
else:
    print("\n   📊 Schema da Camada Silver:")
    df_silver.printSchema()

    # Mostrar amostra dos dados Silver
    print("\n   📋 Amostra de dados Silver (primeiros 5 registros):")
    df_silver.select(
        "carChassis",
        "currentMileage",
        "metrics_metricTimestamp",
        "event_year",
        "event_month",
        "event_day"
    ).show(5, truncate=False)

    # ============================================================================
    # 3. TRANSFORMAÇÃO: ESTADO ATUAL (WINDOW FUNCTION)
    # ============================================================================

    print("\n" + "=" * 80)
    print("🔄 ETAPA 2: Aplicando lógica de 'Estado Atual'")
    print("=" * 80)

    print("\n   🎯 Regra de Negócio:")
    print("      - 1 registro por carChassis (veículo)")
    print("      - Critério: MAIOR currentMileage (mais recente)")
    print("      - Método: Window Function com row_number()")

    # Definir Window Specification
    # Particionar por: carChassis (cada veículo)
    # Ordenar por: currentMileage DESC (maior milhagem = mais recente)
    window_spec = Window.partitionBy("carChassis").orderBy(F.col("currentMileage").desc())

    print("\n   🔹 Aplicando Window Function...")

    # Adicionar coluna row_number
    df_with_row_number = df_silver.withColumn(
        "row_num",
        F.row_number().over(window_spec)
    )

    print("      ✅ row_number() aplicado")

    # Filtrar apenas row_number = 1 (estado atual)
    df_current_state = df_with_row_number.filter(F.col("row_num") == 1).drop("row_num")

    current_state_count = df_current_state.count()
    vehicles_deduped = total_records - current_state_count

    print(f"\n   📊 Resultado da Transformação:")
    print(f"      - Registros históricos (Silver): {total_records}")
    print(f"      - Registros de estado atual (Gold): {current_state_count}")
    print(f"      - Registros históricos descartados: {vehicles_deduped}")
    print(f"      - Taxa de redução: {(vehicles_deduped / total_records * 100):.1f}%")

    # ============================================================================
    # 4. ENRIQUECIMENTO ADICIONAL (OPCIONAL)
    # ============================================================================

    print("\n" + "=" * 80)
    print("🔧 ETAPA 3: Enriquecimento adicional da Camada Gold")
    print("=" * 80)

    # Adicionar timestamp de processamento (metadado Gold)
    df_gold = df_current_state.withColumn(
        "gold_processing_timestamp",
        F.current_timestamp()
    ).withColumn(
        "gold_snapshot_date",
        F.current_date()
    )

    print("   ✅ Metadados Gold adicionados:")
    print("      - gold_processing_timestamp: timestamp da execução do job")
    print("      - gold_snapshot_date: data do snapshot")

    # Calcular métricas agregadas (opcional - exemplo)
    print("\n   📊 Estatísticas do Estado Atual:")
    
    # Contar veículos por fabricante
    manufacturer_stats = df_gold.groupBy("Manufacturer").count().orderBy(F.col("count").desc())
    print("\n   🏭 Veículos por Fabricante:")
    manufacturer_stats.show(10, truncate=False)

    # Mostrar amostra dos dados Gold finais
    print("\n   📋 Amostra de dados Gold (estado atual - primeiros 5 veículos):")
    df_gold.select(
        "carChassis",
        "Manufacturer",
        "Model",
        "currentMileage",
        "metrics_metricTimestamp",
        "gold_processing_timestamp"
    ).orderBy(F.col("currentMileage").desc()).show(5, truncate=False)

    # ============================================================================
    # 5. ESCRITA NO GOLD BUCKET (OVERWRITE COMPLETO)
    # ============================================================================

    print("\n" + "=" * 80)
    print("💾 ETAPA 4: Escrevendo dados no Gold Bucket")
    print("=" * 80)

    gold_output_path = f"s3://{args['gold_bucket']}/{args['gold_path']}"
    
    print(f"\n   📦 Configuração de Escrita:")
    print(f"      - Bucket: {args['gold_bucket']}")
    print(f"      - Path: {args['gold_path']}")
    print(f"      - Full Path: {gold_output_path}")
    print(f"      - Modo: overwrite (snapshot completo)")
    print(f"      - Formato: parquet")
    print(f"      - Compressão: snappy")
    print(f"      - Particionamento: Nenhum (tabela pequena)")

    print("\n   🚀 Iniciando escrita...")

    # Escrever dados usando Spark DataFrame Writer
    # Modo overwrite: sobrescreve todo o diretório (snapshot estático)
    df_gold.write \
        .mode("overwrite") \
        .format("parquet") \
        .option("compression", "snappy") \
        .save(gold_output_path)

    print(f"\n   ✅ Dados escritos com sucesso!")
    print(f"   📊 Total de registros no Gold: {current_state_count}")

    # Verificar arquivos escritos
    print("\n   📂 Arquivos Parquet gerados:")
    try:
        files_df = spark.read.parquet(gold_output_path)
        num_files = len([f for f in spark._jvm.org.apache.hadoop.fs.FileSystem.get(
            spark._jsc.hadoopConfiguration()
        ).listStatus(
            spark._jvm.org.apache.hadoop.fs.Path(gold_output_path)
        ) if f.getPath().getName().endswith(".parquet")])
        print(f"      - Número de arquivos: {num_files}")
        print(f"      - Total de registros: {files_df.count()}")
    except Exception as e:
        print(f"      ⚠️  Não foi possível listar arquivos: {e}")

    # ============================================================================
    # 6. FINALIZAÇÃO DO JOB
    # ============================================================================

    print("\n" + "=" * 80)
    print("✅ JOB CONCLUÍDO COM SUCESSO!")
    print("=" * 80)
    
    print(f"\n📊 Resumo Final:")
    print(f"   - Registros lidos (Silver): {total_records}")
    print(f"   - Veículos únicos (Gold): {current_state_count}")
    print(f"   - Redução de dados: {(vehicles_deduped / total_records * 100):.1f}%")
    print(f"   - Output Path: {gold_output_path}")
    print(f"   - Snapshot Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    
    print("\n" + "=" * 80)
    print("🎯 Próximos Passos:")
    print("   1. Workflow irá acionar Gold Crawler automaticamente")
    print("   2. Crawler atualizará tabela 'gold_car_current_state' no catálogo")
    print("   3. Dados estarão disponíveis para consulta no Athena")
    print("=" * 80)

    # Commit do Job
    job.commit()

    print("\n✅ Job commit realizado com sucesso")
