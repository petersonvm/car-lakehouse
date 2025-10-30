"""
AWS Lambda Function: Silver Layer Cleansing (Bronze-to-Silver Transformation)

Responsabilidades:
1. Ler arquivos Parquet aninhados (structs) da Camada Bronze
2. Achatar estruturas aninhadas (metrics, carInsurance, market)
3. Limpar e padronizar dados (Title Case, lowercase)
4. Converter tipos de dados (strings para datetime/date)
5. Enriquecer com métricas calculadas (percentuais, eficiência)
6. Particionar por data do evento (event_year, event_month, event_day)
7. Salvar no formato Parquet achatado na Camada Silver
"""

import os
import json
import boto3
import pandas as pd
from io import BytesIO
from datetime import datetime
from urllib.parse import unquote_plus

# Configuração
s3_client = boto3.client('s3')
SILVER_BUCKET = os.environ['SILVER_BUCKET']

def lambda_handler(event, context):
    """
    Handler principal da Lambda - Processamento Bronze-to-Silver
    
    Evento esperado: S3 ObjectCreated notification do bronze-bucket
    """
    print(f"📥 Evento recebido: {json.dumps(event)}")
    
    try:
        # Extrair informações do arquivo Bronze do evento S3
        record = event['Records'][0]
        bucket = record['s3']['bucket']['name']
        key = unquote_plus(record['s3']['object']['key'])
        
        print(f"🗂️  Processando arquivo Bronze:")
        print(f"   Bucket: {bucket}")
        print(f"   Key: {key}")
        
        # Validar que é um arquivo Parquet
        if not key.endswith('.parquet'):
            print(f"⚠️  Arquivo não é Parquet, ignorando: {key}")
            return {
                'statusCode': 200,
                'body': json.dumps('File ignored - not a parquet file')
            }
        
        # ETAPA 1: Ler arquivo Parquet aninhado do Bronze
        print("\n🔄 ETAPA 1: Leitura do Bronze")
        df_bronze = read_bronze_parquet(bucket, key)
        print(f"   ✅ DataFrame carregado: {df_bronze.shape[0]} linhas, {df_bronze.shape[1]} colunas")
        print(f"   📋 Colunas aninhadas detectadas: {[col for col in df_bronze.columns if isinstance(df_bronze[col].iloc[0], dict)]}")
        
        # ETAPA 2: Transformação Silver (Flatten + Cleanse + Enrich + Partition)
        print("\n🔄 ETAPA 2: Transformação Silver")
        df_silver = transform_to_silver(df_bronze)
        print(f"   ✅ DataFrame transformado: {df_silver.shape[0]} linhas, {df_silver.shape[1]} colunas")
        print(f"   📋 Colunas achatadas: {list(df_silver.columns)[:10]}... (primeiras 10)")
        
        # ETAPA 3: Salvar no Silver (particionado por data do evento)
        print("\n🔄 ETAPA 3: Escrita no Silver")
        write_to_silver(df_silver, key)
        
        print(f"\n✅ Processamento concluído com sucesso!")
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Bronze-to-Silver transformation completed',
                'source_file': key,
                'rows_processed': len(df_silver),
                'columns_created': len(df_silver.columns)
            })
        }
        
    except Exception as e:
        print(f"\n❌ ERRO durante o processamento: {str(e)}")
        import traceback
        traceback.print_exc()
        raise


def read_bronze_parquet(bucket, key):
    """
    Ler arquivo Parquet aninhado do Bronze
    
    Args:
        bucket: Nome do bucket Bronze
        key: Caminho do arquivo no S3
    
    Returns:
        DataFrame com estruturas aninhadas (structs)
    """
    print(f"   📥 Baixando de s3://{bucket}/{key}...")
    
    # Baixar arquivo do S3
    response = s3_client.get_object(Bucket=bucket, Key=key)
    parquet_content = response['Body'].read()
    
    # Ler Parquet (PyArrow preserva structs como dicts)
    df = pd.read_parquet(BytesIO(parquet_content), engine='pyarrow')
    
    print(f"   📊 Schema original (colunas aninhadas):")
    for col in df.columns:
        dtype = type(df[col].iloc[0]) if len(df) > 0 else df[col].dtype
        print(f"      - {col}: {dtype}")
    
    return df


def transform_to_silver(df):
    """
    Aplicar todas as transformações Silver:
    1. Achatamento (Flatten)
    2. Limpeza (Cleansing)
    3. Conversão de Tipos
    4. Enriquecimento (Enrichment)
    5. Criação de Partições
    
    Args:
        df: DataFrame Bronze com structs
    
    Returns:
        DataFrame Silver achatado e enriquecido
    """
    
    # 1. ACHATAMENTO (Flatten nested structures)
    print("   🔹 1/5: Achatando estruturas aninhadas...")
    df_flat = flatten_nested_columns(df)
    print(f"      ✅ {len(df_flat.columns)} colunas após achatamento")
    
    # 2. LIMPEZA (Cleansing)
    print("   🔹 2/5: Aplicando limpeza e padronização...")
    df_clean = cleanse_data(df_flat)
    print(f"      ✅ Dados limpos (Manufacturer: Title Case, color: lowercase)")
    
    # 3. CONVERSÃO DE TIPOS
    print("   🔹 3/5: Convertendo tipos de dados...")
    df_typed = convert_data_types(df_clean)
    print(f"      ✅ Timestamps e datas convertidos")
    
    # 4. ENRIQUECIMENTO (Enrichment)
    print("   🔹 4/5: Calculando métricas enriquecidas...")
    df_enriched = enrich_metrics(df_typed)
    print(f"      ✅ Métricas calculadas: fuel_level_percentage, km_per_liter")
    
    # 5. PARTICIONAMENTO (Event-based partitions)
    print("   🔹 5/5: Criando colunas de partição por data do evento...")
    df_partitioned = create_event_partitions(df_enriched)
    print(f"      ✅ Partições criadas: event_year, event_month, event_day")
    
    return df_partitioned


def flatten_nested_columns(df):
    """
    Achatar colunas aninhadas (structs) usando json_normalize
    
    Colunas esperadas para achatamento (quando presentes):
    - metrics (struct com múltiplos campos) - OBRIGATÓRIO
    - carInsurance (struct) - OBRIGATÓRIO
    - market (struct) - OBRIGATÓRIO
    
    Nota: A função detecta dinamicamente quais colunas são structs,
          portanto é resiliente a schemas variáveis.
    
    Separador: '_' (underscore)
    """
    # Identificar colunas aninhadas (structs = dicts em Pandas)
    nested_cols = []
    flat_cols = []
    
    for col in df.columns:
        # Verificar se a primeira linha tem um dict (indica struct)
        if len(df) > 0 and isinstance(df[col].iloc[0], dict):
            nested_cols.append(col)
        else:
            flat_cols.append(col)
    
    print(f"      - Colunas aninhadas: {nested_cols}")
    print(f"      - Colunas já planas: {flat_cols}")
    
    # Manter colunas já planas
    df_result = df[flat_cols].copy() if flat_cols else pd.DataFrame()
    
    # Achatar cada coluna aninhada separadamente
    for nested_col in nested_cols:
        print(f"      - Achatando '{nested_col}'...")
        
        # Converter lista de dicts em DataFrame usando json_normalize
        nested_data = df[nested_col].tolist()
        df_nested_flat = pd.json_normalize(nested_data, sep='_')
        
        # Adicionar prefixo com o nome da coluna original
        df_nested_flat.columns = [f"{nested_col}_{col}" for col in df_nested_flat.columns]
        
        print(f"         └─ Criadas {len(df_nested_flat.columns)} colunas: {list(df_nested_flat.columns)[:3]}...")
        
        # Concatenar com o resultado
        df_result = pd.concat([df_result, df_nested_flat], axis=1)
    
    return df_result


def cleanse_data(df):
    """
    Aplicar regras de limpeza e padronização
    
    Regras:
    - Manufacturer: Title Case (ex: "hyundai" -> "Hyundai")
    - color: lowercase (ex: "Blue" -> "blue")
    """
    df_clean = df.copy()
    
    # Manufacturer: Title Case
    if 'manufacturer' in df_clean.columns:
        df_clean['manufacturer'] = df_clean['manufacturer'].str.title()
        print(f"      - 'manufacturer' convertido para Title Case")
    
    # color: lowercase
    if 'color' in df_clean.columns:
        df_clean['color'] = df_clean['color'].str.lower()
        print(f"      - 'color' convertido para lowercase")
    
    return df_clean


def convert_data_types(df):
    """
    Converter tipos de dados:
    - Timestamps (string -> datetime)
    - Datas (string -> date)
    
    Colunas esperadas:
    - metrics_metricTimestamp (string ISO 8601 -> datetime)
    - metrics_trip_tripStartTimestamp (string ISO 8601 -> datetime)
    - carInsurance_validUntil (string YYYY-MM-DD -> date)
    """
    df_typed = df.copy()
    
    # Converter timestamps
    timestamp_cols = [
        'metrics_metricTimestamp',
        'metrics_trip_tripStartTimestamp'
    ]
    
    for col in timestamp_cols:
        if col in df_typed.columns:
            df_typed[col] = pd.to_datetime(df_typed[col], errors='coerce')
            print(f"      - '{col}' convertido para datetime")
    
    # Converter data de seguro (apenas data, sem hora)
    if 'carInsurance_validUntil' in df_typed.columns:
        df_typed['carInsurance_validUntil'] = pd.to_datetime(
            df_typed['carInsurance_validUntil'], 
            errors='coerce'
        ).dt.date
        print(f"      - 'carInsurance_validUntil' convertido para date")
    
    return df_typed


def enrich_metrics(df):
    """
    Criar métricas calculadas (enriquecimento)
    
    Métricas:
    1. metrics_fuel_level_percentage = (fuelAvailableLiters / fuelCapacityLiters) * 100
    2. metrics_trip_km_per_liter = tripMileage / tripFuelLiters
    """
    df_enriched = df.copy()
    
    # 1. Percentual de combustível
    if 'metrics_fuelAvailableLiters' in df_enriched.columns and 'fuelCapacityLiters' in df_enriched.columns:
        df_enriched['metrics_fuel_level_percentage'] = (
            df_enriched['metrics_fuelAvailableLiters'] / df_enriched['fuelCapacityLiters'] * 100
        ).round(2)
        print(f"      - 'metrics_fuel_level_percentage' calculado")
    
    # 2. Eficiência de combustível (km/litro)
    if 'metrics_trip_tripMileage' in df_enriched.columns and 'metrics_trip_tripFuelLiters' in df_enriched.columns:
        # Tratar divisão por zero
        df_enriched['metrics_trip_km_per_liter'] = df_enriched.apply(
            lambda row: (
                round(row['metrics_trip_tripMileage'] / row['metrics_trip_tripFuelLiters'], 2)
                if row['metrics_trip_tripFuelLiters'] > 0
                else None
            ),
            axis=1
        )
        print(f"      - 'metrics_trip_km_per_liter' calculado (divisão por zero tratada)")
    
    return df_enriched


def create_event_partitions(df):
    """
    Criar colunas de partição baseadas na data do evento
    
    Fonte: metrics_metricTimestamp (datetime do evento)
    Partições: event_year, event_month, event_day
    """
    df_part = df.copy()
    
    if 'metrics_metricTimestamp' in df_part.columns:
        # Extrair componentes da data
        df_part['event_year'] = df_part['metrics_metricTimestamp'].dt.year
        df_part['event_month'] = df_part['metrics_metricTimestamp'].dt.month
        df_part['event_day'] = df_part['metrics_metricTimestamp'].dt.day
        
        print(f"      - Partições extraídas de 'metrics_metricTimestamp':")
        print(f"         event_year: {df_part['event_year'].unique()}")
        print(f"         event_month: {df_part['event_month'].unique()}")
        print(f"         event_day: {df_part['event_day'].unique()}")
    else:
        # Fallback: usar data atual se não houver timestamp
        print(f"      ⚠️  'metrics_metricTimestamp' não encontrado, usando data atual")
        now = datetime.now()
        df_part['event_year'] = now.year
        df_part['event_month'] = now.month
        df_part['event_day'] = now.day
    
    return df_part


def write_to_silver(df, source_key):
    """
    Salvar DataFrame achatado no Silver Bucket
    
    Estrutura de saída:
    s3://[SILVER-BUCKET]/car_telemetry/event_year=YYYY/event_month=MM/event_day=DD/
    
    Args:
        df: DataFrame Silver (achatado e enriquecido)
        source_key: Chave do arquivo original (para rastreamento)
    """
    
    # Agrupar por partições para escrever separadamente
    partition_cols = ['event_year', 'event_month', 'event_day']
    
    # Verificar se as colunas de partição existem
    if not all(col in df.columns for col in partition_cols):
        print(f"   ⚠️  Colunas de partição não encontradas, escrevendo sem particionamento")
        # Escrever tudo em um único arquivo
        write_single_partition(df, SILVER_BUCKET, 'car_telemetry', {}, source_key)
        return
    
    # Agrupar por partição
    grouped = df.groupby(partition_cols)
    print(f"   📦 {len(grouped)} partições encontradas")
    
    for partition_values, df_partition in grouped:
        year, month, day = partition_values
        
        partition_dict = {
            'event_year': int(year),
            'event_month': int(month),
            'event_day': int(day)
        }
        
        print(f"   📝 Escrevendo partição: {partition_dict}")
        
        # Remover colunas de partição do DataFrame (elas vão para o path)
        df_to_write = df_partition.drop(columns=partition_cols)
        
        write_single_partition(df_to_write, SILVER_BUCKET, 'car_telemetry', partition_dict, source_key)


def write_single_partition(df, bucket, base_path, partition_dict, source_key):
    """
    Escrever uma única partição no S3
    
    Args:
        df: DataFrame (sem colunas de partição)
        bucket: Nome do bucket Silver
        base_path: Caminho base (ex: 'car_telemetry')
        partition_dict: Dicionário com valores de partição {'event_year': 2025, ...}
        source_key: Chave do arquivo fonte (para rastreamento)
    """
    
    # Construir caminho particionado
    partition_path = base_path
    for key, value in partition_dict.items():
        partition_path += f"/{key}={value}"
    
    # Gerar nome único do arquivo
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    source_filename = source_key.split('/')[-1].replace('.parquet', '')
    filename = f"{source_filename}_{timestamp}.parquet"
    
    full_key = f"{partition_path}/{filename}"
    
    print(f"      🎯 Destino: s3://{bucket}/{full_key}")
    print(f"      📊 Linhas: {len(df)}, Colunas: {len(df.columns)}")
    
    # Converter DataFrame para Parquet em memória
    parquet_buffer = BytesIO()
    df.to_parquet(
        parquet_buffer,
        engine='pyarrow',
        compression='snappy',
        index=False
    )
    parquet_buffer.seek(0)
    
    # Upload para S3
    s3_client.put_object(
        Bucket=bucket,
        Key=full_key,
        Body=parquet_buffer.getvalue(),
        ContentType='application/parquet',
        Metadata={
            'source_bronze_key': source_key,
            'processed_at': datetime.now().isoformat(),
            'row_count': str(len(df)),
            'column_count': str(len(df.columns)),
            'transformation': 'bronze-to-silver'
        }
    )
    
    print(f"      ✅ Arquivo salvo com sucesso!")
