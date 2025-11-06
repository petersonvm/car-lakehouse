import pyarrow.parquet as pq
import os

file = os.path.join(os.environ['TEMP'], 'gold_sample.parquet')
table = pq.read_table(file)
df = table.to_pandas()

print('\n📊 DADOS GOLD (1 registro):\n')
print(df[['car_chassis', 'current_mileage_km', 'telemetry_timestamp']].to_string(index=False))

print(f'\n📈 current_mileage_km: {df["current_mileage_km"].iloc[0]}')
print(f'🔍 car_chassis: {df["car_chassis"].iloc[0]}')
