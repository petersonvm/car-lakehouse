"""
Glue Job: Silver Consolidation (Event-Driven Pipeline)
Reads Bronze Parquet files created by event-driven Lambda ingestion
Writes to Silver Iceberg table with MERGE for upserts
"""

import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql import functions as F
from pyspark.sql.types import *

# ============================================================================
# INITIALIZE GLUE CONTEXT
# ============================================================================
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'bronze_database',
    'bronze_table',
    'silver_database',
    'silver_table'
])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

print("\n" + "=" * 80)
print(" SILVER CONSOLIDATION JOB - EVENT-DRIVEN PIPELINE (ICEBERG)")
print("=" * 80)
print(f"\n  Job: {args['JOB_NAME']}")
print(f"  Bronze: {args['bronze_database']}.{args['bronze_table']}")
print(f"  Silver: {args['silver_database']}.{args['silver_table']}")

# ============================================================================
# 1. READ FROM BRONZE LAYER (GLUE CATALOG)
# ============================================================================

print("\n" + "=" * 80)
print(" STEP 1: Reading from Bronze Layer (Glue Catalog)")
print("=" * 80)

try:
    bronze_dynamic_frame = glueContext.create_dynamic_frame.from_catalog(
        database=args['bronze_database'],
        table_name=args['bronze_table'],
        transformation_ctx="bronze_dynamic_frame"
    )
    
    df_bronze = bronze_dynamic_frame.toDF()
    total_records = df_bronze.count()
    print(f"\n✅ Records read from Bronze: {total_records}")
    
    if total_records == 0:
        print("\n⚠️  WARNING: No data found in Bronze Layer!")
        job.commit()
        sys.exit(0)
    
    print("\n📋 Bronze Schema:")
    df_bronze.printSchema()
    
except Exception as e:
    print(f"\n❌ ERROR reading Bronze table: {str(e)}")
    raise

# ============================================================================
# 2. TRANSFORMATION: EVENT-DRIVEN SCHEMA
# ============================================================================

print("\n" + "=" * 80)
print(" STEP 2: Transforming data for Silver Layer")
print("=" * 80)

# Event-driven schema is flat (no nested structs)
# Fields: carChassis, manufacturer, model, year, metrics{}, telemetryTimestamp, event_primary_timestamp
df_flattened = df_bronze \
    .withColumn("event_id", F.concat(F.col("carChassis"), F.lit("_"), F.col("event_primary_timestamp"))) \
    .withColumn("car_chassis", F.col("carChassis")) \
    .withColumn("telemetry_timestamp", F.to_timestamp(F.col("event_primary_timestamp"))) \
    .withColumn("current_mileage_km", F.col("metrics.currentMileageKm").cast("double")) \
    .withColumn("fuel_available_liters", F.col("metrics.fuelAvailableLiters").cast("double")) \
    .withColumn("engine_temp_celsius", F.col("metrics.engineTempCelsius").cast("int")) \
    .withColumn("oil_pressure_psi", F.col("metrics.oilPressurePsi").cast("int")) \
    .withColumn("gas_type", F.lit(None).cast("string")) \
    .withColumn("insurance_provider", F.lit(None).cast("string")) \
    .withColumn("insurance_valid_until", F.lit(None).cast("string")) \
    .withColumn("event_year", F.year(F.col("telemetry_timestamp"))) \
    .withColumn("event_month", F.month(F.col("telemetry_timestamp"))) \
    .withColumn("event_day", F.dayofmonth(F.col("telemetry_timestamp"))) \
    .select(
        F.col("event_id"),
        F.col("car_chassis"),
        F.col("event_primary_timestamp"),
        F.col("telemetry_timestamp"),
        F.col("manufacturer"),
        F.col("model"),
        F.col("year").cast("int"),
        F.col("current_mileage_km"),
        F.col("fuel_available_liters"),
        F.col("gas_type"),
        F.col("insurance_provider"),
        F.col("insurance_valid_until"),
        F.col("event_year"),
        F.col("event_month"),
        F.col("event_day")
    )

records_transformed = df_flattened.count()
print(f"\n✅ Records transformed: {records_transformed}")

print("\n📋 Silver Schema (before write):")
df_flattened.printSchema()

# ============================================================================
# 3. WRITE TO SILVER ICEBERG TABLE (CREATE IF NEEDED, THEN MERGE/INSERT)
# ============================================================================

print("\n" + "=" * 80)
print(" STEP 3: Writing to Silver Iceberg Table")
print("=" * 80)

silver_table_path = f"{args['silver_database']}.{args['silver_table']}"
silver_location = "s3://datalake-pipeline-silver-dev/car_telemetry/"
print(f"\n  Target: {silver_table_path}")
print(f"\n  Location: {silver_location}")

try:
    # Register Bronze data as temp view
    df_flattened.createOrReplaceTempView("bronze_updates")
    records_to_process = df_flattened.count()
    print(f"\n  Records to process: {records_to_process}")
    
    # Check if Iceberg table exists with data
    try:
        silver_count = spark.sql(f"SELECT COUNT(*) as count FROM {silver_table_path}").collect()[0]['count']
        table_has_data = True
        print(f"\n  ✅ Iceberg table exists with {silver_count} records")
    except Exception as e:
        table_has_data = False
        silver_count = 0
        print(f"\n  ⚠️  Iceberg table empty or needs initialization: {str(e)[:100]}")
        
        # Create Iceberg table with explicit schema (NOT using AS SELECT)
        print(f"\n📝 Creating Iceberg table with explicit column definitions...")
        create_table_sql = f"""
        CREATE TABLE IF NOT EXISTS {silver_table_path} (
          event_id string,
          car_chassis string,
          event_primary_timestamp string,
          telemetry_timestamp timestamp,
          manufacturer string,
          model string,
          year int,
          current_mileage_km double,
          fuel_available_liters double,
          engine_temp_celsius int,
          oil_pressure_psi int,
          gas_type string,
          insurance_provider string,
          insurance_valid_until string,
          event_year int,
          event_month int,
          event_day int
        )
        USING iceberg
        PARTITIONED BY (event_year, event_month, event_day)
        LOCATION '{silver_location}'
        TBLPROPERTIES (
          'format-version' = '2',
          'write.format.default' = 'parquet'
        )
        """
        spark.sql(create_table_sql)
        print(f"\n✅ Iceberg table created with explicit schema!")
    
    # Now INSERT or MERGE
    if not table_has_data:
        # First run: Direct INSERT
        print(f"\n📝 Performing direct INSERT (first run)...")
        spark.sql(f"INSERT INTO {silver_table_path} SELECT * FROM bronze_updates")
        print(f"\n✅ INSERT completed successfully!")
    else:
        # Subsequent runs: MERGE for upserts
        print(f"\n📝 Performing MERGE (upsert)...")
        merge_query = f"""
        MERGE INTO {silver_table_path} AS target
        USING bronze_updates AS source
        ON target.car_chassis = source.car_chassis 
           AND target.event_primary_timestamp = source.event_primary_timestamp
        WHEN MATCHED THEN
            UPDATE SET *
        WHEN NOT MATCHED THEN
            INSERT *
        """
        spark.sql(merge_query)
        print(f"\n✅ MERGE completed successfully!")
    
    # Verify Silver table
    silver_count_after = spark.sql(f"SELECT COUNT(*) as count FROM {silver_table_path}").collect()[0]['count']
    print(f"\n📊 Total records in Silver after write: {silver_count_after}")
    
except Exception as e:
    print(f"\n❌ ERROR during write: {str(e)}")
    raise

# ============================================================================
# 4. JOB COMPLETION
# ============================================================================

print("\n" + "=" * 80)
print(" JOB COMPLETED SUCCESSFULLY")
print("=" * 80)
print(f"\n  Records processed: {records_transformed}")
print(f"  Silver table: {silver_table_path}")
print(f"  Total in Silver: {silver_count_after}")

job.commit()
