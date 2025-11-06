import pyarrow.parquet as pq
import os

file = os.path.join(os.environ['TEMP'], 'silver_sample.parquet')
table = pq.read_table(file)
df = table.to_pandas()

print('\n📊 DADOS SILVER (3 registros):\n')
print(df[['car_chassis', 'current_mileage_km', 'telemetry_timestamp']].to_string(index=False))

print(f'\n📈 Resumo current_mileage_km:')
print(f'   Min: {df["current_mileage_km"].min()}')
print(f'   Max: {df["current_mileage_km"].max()}')
print(f'   Valores únicos: {df["current_mileage_km"].nunique()}')
print(f'\n   Todos os valores: {sorted(df["current_mileage_km"].tolist())}')
