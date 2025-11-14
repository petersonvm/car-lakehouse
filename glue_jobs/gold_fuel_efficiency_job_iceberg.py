"""
===============================================================================
AWS GLUE JOB: Gold Layer - Fuel Efficiency Monthly (Iceberg - MERGE INTO)
===============================================================================

PURPOSE:
    Calculates monthly fuel efficiency KPIs using Apache Iceberg tables.
    Uses MERGE INTO for incremental upserts of monthly aggregations.

ICEBERG BENEFITS:
    - ACID transactions: Atomic updates of monthly metrics
    - Schema evolution: Add new metrics without breaking queries
    - Time travel: Query historical aggregation snapshots
    - Partition evolution: Change partitioning without rewriting data
    - No crawlers needed: Iceberg metadata updated atomically

BUSINESS LOGIC:
    - Read Silver telemetry data (Iceberg)
    - Aggregate total mileage and fuel by car/month
    - MERGE INTO Gold: Update existing months, insert new ones
    - Primary key: (car_chassis, year_month)

INPUT:
    - Table: glue_catalog.datalake-pipeline-catalog-dev.silver_car_telemetry (Iceberg)
    - Catalog: Glue Catalog with Iceberg support
    - Warehouse: s3://datalake-pipeline-silver-dev/

OUTPUT:
    - Table: glue_catalog.datalake-pipeline-catalog-dev.fuel_efficiency_monthly (Iceberg)
    - Path: s3://datalake-pipeline-gold-dev/gold_fuel_efficiency/
    - Operation: MERGE INTO (upsert by car_chassis + year_month)
    - No partitions (small table, monthly aggregation)

MERGE LOGIC:
    - ON: target.car_chassis = source.car_chassis 
          AND target.year_month = source.year_month
    - WHEN MATCHED: Update aggregated totals
    - WHEN NOT MATCHED: Insert new month

EXECUTION:
    - Triggered by: Silver job success (conditional trigger in event-driven workflow)
    - Runs in parallel with: gold_car_current_state, gold_performance_alerts
    - No crawler needed: Iceberg metadata atomically updated

AUTHOR: AWS Glue ETL Pipeline - Iceberg Migration
DATE: November 12, 2025
VERSION: 2.0 (Iceberg)
===============================================================================
"""

import sys
from pyspark.sql import SparkSession
from pyspark.sql.functions import col, sum as spark_sum, count, avg, format_string, current_timestamp
from datetime import datetime

# ============================================================
# SPARK SESSION WITH ICEBERG
# ============================================================

spark = SparkSession.builder \
    .appName("Gold Fuel Efficiency - Iceberg") \
    .config("spark.sql.extensions", "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions") \
    .config("spark.sql.catalog.glue_catalog", "org.apache.iceberg.spark.SparkCatalog") \
    .config("spark.sql.catalog.glue_catalog.warehouse", "s3://datalake-pipeline-gold-dev/iceberg-warehouse") \
    .config("spark.sql.catalog.glue_catalog.catalog-impl", "org.apache.iceberg.aws.glue.GlueCatalog") \
    .config("spark.sql.catalog.glue_catalog.io-impl", "org.apache.iceberg.aws.s3.S3FileIO") \
    .config("spark.sql.iceberg.handle-timestamp-without-timezone", "true") \
    .getOrCreate()

# Configure Spark checkpoint directory (for forced materialization)
print("\n  Configuring Spark checkpoint directory...")
spark.sparkContext.setCheckpointDir("s3://datalake-pipeline-glue-temp-dev/spark-checkpoints/gold/")
print("  [OK] Checkpoint directory set")

# ============================================================
# JOB PARAMETERS
# ============================================================

# Get job arguments (passed from Terraform default_arguments)
args = {}
for arg in sys.argv[1:]:
    if arg.startswith('--'):
        key_value = arg.split('=', 1)
        if len(key_value) == 2:
            args[key_value[0].lstrip('--')] = key_value[1]

GOLD_BUCKET = args.get('gold_bucket', 'datalake-pipeline-gold-dev')
GLUE_DATABASE = args.get('glue_database', 'datalake_pipeline_catalog_dev')

# Table names with glue_catalog prefix and backticks around database name (contains hyphens)
SILVER_TABLE = f"glue_catalog.`{GLUE_DATABASE}`.silver_car_telemetry"
GOLD_TABLE = f"glue_catalog.`{GLUE_DATABASE}`.fuel_efficiency_monthly"

print("=" * 80)
print("GOLD FUEL EFFICIENCY JOB - ICEBERG")
print("=" * 80)
print(f"Glue Database: {GLUE_DATABASE}")
print(f"Gold Bucket: {GOLD_BUCKET}")
print(f"Silver Table: {SILVER_TABLE}")
print(f"Gold Table: {GOLD_TABLE}")
print(f"Timestamp: {datetime.now()}")
print("=" * 80)

# ============================================================
# READ SILVER TELEMETRY (ICEBERG)
# ============================================================

print("\n[INFO] Reading Silver telemetry data from Iceberg table...")

try:
    silver_df = spark.sql(f"""
        SELECT 
            car_chassis,
            manufacturer,
            model,
            event_year,
            event_month,
            current_mileage_km,
            fuel_available_liters,
            telemetry_timestamp
        FROM {SILVER_TABLE}
        WHERE event_year IS NOT NULL 
          AND event_month IS NOT NULL
    """)
    
    record_count = silver_df.count()
    print(f"[OK] Successfully read {record_count:,} records from Silver")
    
    # Validate required columns exist
    print("\n[INFO] Validating Silver DataFrame schema...")
    required_cols = ["event_year", "event_month", "current_mileage_km", "fuel_available_liters"]
    actual_cols = silver_df.columns
    missing_cols = [col for col in required_cols if col not in actual_cols]
    
    if missing_cols:
        print(f"[ERROR] Missing required columns in Silver table: {missing_cols}")
        print(f"[ERROR] Available columns: {actual_cols}")
        spark.stop()
        sys.exit(1)
    
    print(f"[OK] All required columns present: {required_cols}")
    
    if record_count == 0:
        print("[WARN] No data in Silver table. Exiting job.")
        spark.stop()
        sys.exit(0)
        
except Exception as e:
    print(f"[ERROR] Error reading Silver table: {str(e)}")
    spark.stop()
    sys.exit(1)

# ============================================================
# CALCULATE FUEL EFFICIENCY METRICS
# ============================================================

print("\n[INFO] Calculating monthly fuel efficiency metrics...")

# Aggregate by car and month
aggregated_df = silver_df \
    .withColumn("year_month", 
                format_string("%04d-%02d", col("event_year"), col("event_month"))) \
    .groupBy("car_chassis", "manufacturer", "model", "year_month") \
    .agg(
        spark_sum("current_mileage_km").alias("total_km_driven"),
        spark_sum("fuel_available_liters").alias("total_fuel_liters"),
        count("*").alias("trip_count")
    ) \
    .withColumn("avg_fuel_efficiency_kmpl", 
                col("total_km_driven") / col("total_fuel_liters")) \
    .withColumn("processing_timestamp", current_timestamp())

agg_count = aggregated_df.count()
print(f"[OK] Calculated metrics for {agg_count:,} car-month combinations")

# Check if there is data to process
if agg_count == 0:
    print("[INFO] No aggregated data to merge. Exiting job successfully.")
    spark.stop()
    sys.exit(0)

# Show sample
print("\n[INFO] Sample aggregated data:")
aggregated_df.show(5, truncate=False)

# ============================================================
# DROP SILVER-INHERITED COLUMNS & CHECKPOINT
# ============================================================

print("\n" + "=" * 80)
print("Dropping Silver-inherited columns and forcing materialization")
print("=" * 80)

print(f"\n  Columns in aggregated_df BEFORE drop: {len(aggregated_df.columns)}")
print(f"  {aggregated_df.columns}")

# Drop Silver-only columns if they exist
df_cleaned = aggregated_df.drop(
    "event_id", "event_primary_timestamp", 
    "event_year", "event_month", "event_day"
)

print(f"\n  Columns after drop: {len(df_cleaned.columns)}")

# Force materialization via checkpoint
print("\n  Checkpointing DataFrame to break lineage...")
df_final = df_cleaned.checkpoint()
checkpoint_count = df_final.count()
print(f"  [OK] Checkpoint completed: {checkpoint_count:,} rows materialized")

# Schema validation
print("\n  Final schema:")
df_final.printSchema()

# ============================================================
# CREATE TEMP VIEW FOR MERGE
# ============================================================

df_final.createOrReplaceTempView("fuel_efficiency_updates")

# ============================================================
# MERGE INTO GOLD TABLE (ICEBERG UPSERT)
# ============================================================

print("\n[INFO] Executing MERGE INTO operation...")

# WORKAROUND: Table created via Athena DDL (not via PySpark createOrReplace)
# Reason: PySpark writeTo().createOrReplace() fails with "Writing job aborted"
print("  Using pre-existing Iceberg table (created via Athena DDL)...")

# Verify table exists
try:
    existing_count = spark.sql(f"SELECT COUNT(*) as cnt FROM {GOLD_TABLE}").collect()[0]['cnt']
    print(f"  [OK] Table exists with {existing_count} rows, proceeding with MERGE")
except Exception as e:
    print(f"  [ERROR] Table does not exist! Run athena_ddl_workaround.sql first")
    print(f"  [ERROR] Error details: {str(e)}")
    raise

merge_sql = f"""
MERGE INTO {GOLD_TABLE} AS target
USING fuel_efficiency_updates AS source
ON target.car_chassis = source.car_chassis 
   AND target.year_month = source.year_month

WHEN MATCHED THEN UPDATE SET
    target.manufacturer = source.manufacturer,
    target.model = source.model,
    target.total_km_driven = source.total_km_driven,
    target.total_fuel_liters = source.total_fuel_liters,
    target.avg_fuel_efficiency_kmpl = source.avg_fuel_efficiency_kmpl,
    target.trip_count = source.trip_count,
    target.processing_timestamp = source.processing_timestamp

WHEN NOT MATCHED THEN INSERT (
    car_chassis,
    manufacturer,
    model,
    year_month,
    total_km_driven,
    total_fuel_liters,
    avg_fuel_efficiency_kmpl,
    trip_count,
    processing_timestamp
) VALUES (
    source.car_chassis,
    source.manufacturer,
    source.model,
    source.year_month,
    source.total_km_driven,
    source.total_fuel_liters,
    source.avg_fuel_efficiency_kmpl,
    source.trip_count,
    source.processing_timestamp
)
"""

try:
    spark.sql(merge_sql)
    print(f"[OK] MERGE INTO completed successfully for {agg_count:,} records")
    
    # Verify final record count
    final_count = spark.sql(f"SELECT COUNT(*) as cnt FROM {GOLD_TABLE}").collect()[0]['cnt']
    print(f"[INFO] Total records in Gold table: {final_count:,}")
    
except Exception as e:
    print(f"[ERROR] Error executing MERGE INTO: {str(e)}")
    print(f"[DEBUG] Merge SQL: {merge_sql}")
    spark.stop()
    sys.exit(1)

# ============================================================
# JOB SUMMARY
# ============================================================

print("\n" + "=" * 80)
print("JOB COMPLETED SUCCESSFULLY")
print("=" * 80)
print(f"Silver records read: {record_count:,}")
print(f"Aggregations calculated: {agg_count:,}")
print(f"Gold table total: {final_count:,}")
print(f"Operation: MERGE INTO (upsert)")
print(f"Completed at: {datetime.now()}")
print("=" * 80)

spark.stop()
