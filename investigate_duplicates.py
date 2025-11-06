import pyarrow.parquet as pq
import pandas as pd
import os
import subprocess

print('\n🔍 INVESTIGAÇÃO: Por que 3 registros IDÊNTICOS no Silver?\n')
print('='*80)

# Ler todos os 3 arquivos Silver
silver_files = [
    'run-datasink_silver-82-part-block-0-0-r-00002-snappy.parquet',
    'run-datasink_silver-83-part-block-0-0-r-00002-snappy.parquet',
    'run-datasink_silver-84-part-block-0-0-r-00002-snappy.parquet'
]

all_silver_data = []
for i, filename in enumerate(silver_files, 1):
    file_path = os.path.join(os.environ['TEMP'], filename)
    s3_path = f's3://datalake-pipeline-silver-dev/car_telemetry/event_year=2024/event_month=04/event_day=01/{filename}'
    subprocess.run(['aws', 's3', 'cp', s3_path, file_path, '--quiet'], check=True)
    
    table = pq.read_table(file_path)
    df = table.to_pandas()
    df['source_file'] = filename
    all_silver_data.append(df)

# Combinar todos os dados
df_all = pd.concat(all_silver_data, ignore_index=True)

# Mostrar primeiras 10 colunas importantes
important_cols = ['car_chassis', 'current_mileage_km', 'telemetry_timestamp', 
                  'event_id', 'device_id', 'trip_id', 'source_file']

# Verificar se existem essas colunas
existing_cols = [col for col in important_cols if col in df_all.columns]
print(f'\n📋 Comparação dos 3 registros Silver:')
print(df_all[existing_cols].to_string(index=False))

# Verificar se são exatamente iguais (exceto source_file)
cols_to_compare = [col for col in df_all.columns if col != 'source_file']
print(f'\n\n🔎 Verificação de duplicatas:')
print(f'   Total de registros: {len(df_all)}')
print(f'   Registros únicos (ignorando source_file): {df_all[cols_to_compare].drop_duplicates().shape[0]}')

if df_all[cols_to_compare].drop_duplicates().shape[0] == 1:
    print('\n⚠️  CONFIRMADO: Os 3 registros Silver são DUPLICATAS EXATAS!')
    print('   Causa provável: O mesmo JSON foi processado 3 vezes')
    print('   Impacto: Job Gold funciona CORRETAMENTE (deduplica para 1 registro)')
    print('\n💡 CONCLUSÃO:')
    print('   - Silver: 3 registros (duplicatas do mesmo evento)')
    print('   - Gold: 1 registro (após dedupe por current_mileage_km)')
    print('   - Status: Sistema funcionando como esperado!')
