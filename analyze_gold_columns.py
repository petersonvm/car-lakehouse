import pyarrow.parquet as pq
import pandas as pd
import os

print('\n🔍 ANÁLISE DETALHADA: Colunas vazias na tabela Gold\n')
print('='*80)

# Ler arquivo Gold
file = os.path.join(os.environ['TEMP'], 'gold_sample.parquet')
table = pq.read_table(file)
df = table.to_pandas()

print(f'📊 Total de colunas: {len(df.columns)}')
print(f'📊 Total de registros: {len(df)}')

# Verificar colunas vazias
print('\n📋 Análise de colunas vazias/nulas:\n')

empty_cols = []
for col in df.columns:
    null_count = df[col].isna().sum()
    null_pct = (null_count / len(df)) * 100
    value = df[col].iloc[0] if len(df) > 0 else None
    
    if null_count > 0 or pd.isna(value) or (isinstance(value, str) and value.strip() == ''):
        empty_cols.append(col)
        print(f'⚠️  {col}: NULL/VAZIO')
        print(f'    Valor: {value}')
    else:
        print(f'✅ {col}: PREENCHIDO')
        if col in ['car_chassis', 'carchassis', 'model', 'manufacturer', 'color']:
            print(f'    Valor: {value}')

print(f'\n\n📊 RESUMO:')
print(f'   Colunas com dados: {len(df.columns) - len(empty_cols)}')
print(f'   Colunas vazias/nulas: {len(empty_cols)}')

print(f'\n⚠️  Colunas vazias:')
for col in empty_cols[:10]:  # Mostrar primeiras 10
    print(f'   - {col}')

# Verificar se car_chassis existe com nome diferente
print(f'\n\n🔍 Verificando variações do nome car_chassis:')
chassis_cols = [col for col in df.columns if 'chassis' in col.lower()]
print(f'   Colunas encontradas: {chassis_cols}')
for col in chassis_cols:
    print(f'   {col}: {df[col].iloc[0]}')
