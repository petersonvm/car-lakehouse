import pyarrow.parquet as pq
import pandas as pd
import os

print('\n📊 ANÁLISE COMPLETA: SILVER vs GOLD\n')
print('='*80)

# Ler todos os 3 arquivos Silver
silver_files = [
    'run-datasink_silver-82-part-block-0-0-r-00002-snappy.parquet',
    'run-datasink_silver-83-part-block-0-0-r-00002-snappy.parquet',
    'run-datasink_silver-84-part-block-0-0-r-00002-snappy.parquet'
]

all_silver_data = []
for i, filename in enumerate(silver_files, 1):
    try:
        file_path = os.path.join(os.environ['TEMP'], filename)
        # Baixar arquivo
        import subprocess
        s3_path = f's3://datalake-pipeline-silver-dev/car_telemetry/event_year=2024/event_month=04/event_day=01/{filename}'
        subprocess.run(['aws', 's3', 'cp', s3_path, file_path, '--quiet'], check=True)
        
        # Ler arquivo
        table = pq.read_table(file_path)
        df = table.to_pandas()
        all_silver_data.append(df)
        
        print(f'\n📄 Arquivo Silver #{i}: {filename}')
        print(f'   Registros: {len(df)}')
        print(f'   car_chassis: {df["car_chassis"].iloc[0][:20]}...')
        print(f'   current_mileage_km: {df["current_mileage_km"].iloc[0]}')
        print(f'   telemetry_timestamp: {df["telemetry_timestamp"].iloc[0]}')
        
    except Exception as e:
        print(f'   ❌ Erro ao ler arquivo {filename}: {e}')

# Combinar todos os dados Silver
df_all_silver = pd.concat(all_silver_data, ignore_index=True)

print(f'\n\n📊 RESUMO SILVER (Total de {len(df_all_silver)} registros):')
print('='*80)
print(f'   Carros únicos: {df_all_silver["car_chassis"].nunique()}')
print(f'   current_mileage_km - Min: {df_all_silver["current_mileage_km"].min()}')
print(f'   current_mileage_km - Max: {df_all_silver["current_mileage_km"].max()}')
print(f'   current_mileage_km - Valores únicos: {df_all_silver["current_mileage_km"].nunique()}')
print(f'   Todos os valores: {sorted(df_all_silver["current_mileage_km"].unique().tolist())}')

# Verificar se todos têm mesmo current_mileage_km
if df_all_silver["current_mileage_km"].nunique() == 1:
    print('\n⚠️  PROBLEMA DETECTADO:')
    print('   Todos os 3 registros Silver têm o MESMO current_mileage_km!')
    print('   Logo, o job Gold aplicou a window function e pegou apenas 1 (row_number=1)')
    print('   Resultado: 3 registros Silver → 1 registro Gold (CORRETO pela lógica)')
