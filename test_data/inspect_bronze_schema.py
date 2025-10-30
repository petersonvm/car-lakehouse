import pandas as pd
import pyarrow.parquet as pq

# Read the Parquet file
parquet_file = r'c:\dev\HP\wsas\Poc\test_data\bronze_nested_test.parquet'

# Read schema using PyArrow (shows struct columns)
print("=" * 80)
print("PARQUET SCHEMA (PyArrow)")
print("=" * 80)
parquet_table = pq.read_table(parquet_file)
print(parquet_table.schema)

print("\n" + "=" * 80)
print("DATAFRAME INFO (Pandas)")
print("=" * 80)
df = pd.read_parquet(parquet_file)
print(f"\nShape: {df.shape}")
print(f"\nColumns: {list(df.columns)}")
print(f"\nData types:\n{df.dtypes}")

print("\n" + "=" * 80)
print("NESTED STRUCTURE VERIFICATION")
print("=" * 80)

# Check if nested columns are dictionaries (preserved structure)
print(f"\nmetrics column type: {type(df['metrics'].iloc[0])}")
print(f"metrics content: {df['metrics'].iloc[0]}")

print(f"\nmarket column type: {type(df['market'].iloc[0])}")
print(f"market content: {df['market'].iloc[0]}")

print(f"\ncarInsurance column type: {type(df['carInsurance'].iloc[0])}")
print(f"carInsurance content: {df['carInsurance'].iloc[0]}")

print(f"\nowner column type: {type(df['owner'].iloc[0])}")
print(f"owner content: {df['owner'].iloc[0]}")

print("\n" + "=" * 80)
print("✅ VERIFICATION RESULT")
print("=" * 80)

# Verify nested structures are preserved as dicts
all_preserved = (
    isinstance(df['metrics'].iloc[0], dict) and
    isinstance(df['market'].iloc[0], dict) and
    isinstance(df['carInsurance'].iloc[0], dict) and
    isinstance(df['owner'].iloc[0], dict)
)

if all_preserved:
    print("✅ SUCCESS: All nested structures preserved as dictionaries!")
    print("✅ Bronze layer is now 'Fonte da Verdade' (Source of Truth)")
    print("✅ PyArrow successfully converted nested dicts to struct columns in Parquet")
else:
    print("❌ ERROR: Some structures were flattened")
