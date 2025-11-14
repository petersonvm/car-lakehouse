"""
===============================================================================
AWS GLUE JOB: Gold Layer - Performance Alerts (Iceberg - INSERT INTO)
===============================================================================

PURPOSE:
    Detects performance alerts from vehicle telemetry using Apache Iceberg.
    Uses INSERT INTO for append-only log pattern.

ICEBERG BENEFITS:
    - ACID transactions: Atomic append operations
    - Schema evolution: Add new alert types without breaking queries
    - Time travel: Query historical alert snapshots
    - Partition evolution: Optimize partitioning over time
    - No crawlers needed: Metadata updated atomically

BUSINESS LOGIC:
    - Read latest Silver telemetry data (Iceberg)
    - Detect alerts: LOW_FUEL, HIGH_MILEAGE, ANOMALY
    - Generate alert records with severity
    - INSERT INTO Gold (append-only log)

ALERT RULES:
    - LOW_FUEL (CRITICAL): fuel_available_liters < 5.0
    - LOW_FUEL (WARNING): fuel_available_liters < 10.0
    - HIGH_MILEAGE (WARNING): current_mileage_km > 100000

INPUT:
    - Table: glue_catalog.datalake-pipeline-catalog-dev.silver_car_telemetry (Iceberg)
    - Catalog: Glue Catalog with Iceberg support
    - Warehouse: s3://datalake-pipeline-silver-dev/

OUTPUT:
    - Table: glue_catalog.datalake-pipeline-catalog-dev.performance_alerts_log_slim (Iceberg)
    - Path: s3://datalake-pipeline-gold-dev/gold_performance_alerts_slim/
    - Operation: INSERT INTO (append-only)
    - Partition: alert_date (derived from telemetry_timestamp)

EXECUTION:
    - Triggered by: Silver job success (conditional trigger in event-driven workflow)
    - Runs in parallel with: gold_car_current_state, gold_fuel_efficiency
    - No crawler needed: Iceberg metadata atomically updated

AUTHOR: AWS Glue ETL Pipeline - Iceberg Migration
DATE: November 12, 2025
VERSION: 2.0 (Iceberg)
===============================================================================
"""

import sys
from pyspark.sql import SparkSession
from pyspark.sql.functions import (
    col, when, lit, current_timestamp, to_date,
    concat_ws, expr
)
from datetime import datetime

# ============================================================
# SPARK SESSION WITH ICEBERG
# ============================================================

spark = SparkSession.builder \
    .appName("Gold Performance Alerts - Iceberg") \
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
GOLD_TABLE = f"glue_catalog.`{GLUE_DATABASE}`.performance_alerts_log_slim"

print("=" * 80)
print("GOLD PERFORMANCE ALERTS JOB - ICEBERG")
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
            current_mileage_km,
            fuel_available_liters,
            telemetry_timestamp
        FROM {SILVER_TABLE}
        WHERE telemetry_timestamp IS NOT NULL
    """)
    
    record_count = silver_df.count()
    print(f"[OK] Successfully read {record_count:,} records from Silver")
    
    # Validate required columns exist
    print("\n[INFO] Validating Silver DataFrame schema...")
    required_cols = ["current_mileage_km", "fuel_available_liters", "telemetry_timestamp"]
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
# DETECT ALERTS
# ============================================================

print("\n[INFO] Detecting performance alerts...")

# Detect LOW_FUEL alerts
low_fuel_critical = silver_df \
    .filter(col("fuel_available_liters") < 5.0) \
    .withColumn("alert_type", lit("LOW_FUEL")) \
    .withColumn("alert_severity", lit("CRITICAL")) \
    .withColumn("alert_message", 
                concat_ws(" ", 
                         lit("Critical: Fuel level below 5L -"),
                         col("fuel_available_liters"),
                         lit("liters remaining")))

low_fuel_warning = silver_df \
    .filter((col("fuel_available_liters") >= 5.0) & (col("fuel_available_liters") < 10.0)) \
    .withColumn("alert_type", lit("LOW_FUEL")) \
    .withColumn("alert_severity", lit("WARNING")) \
    .withColumn("alert_message",
                concat_ws(" ",
                         lit("Warning: Fuel level below 10L -"),
                         col("fuel_available_liters"),
                         lit("liters remaining")))

# Detect HIGH_MILEAGE alerts
high_mileage = silver_df \
    .filter(col("current_mileage_km") > 100000) \
    .withColumn("alert_type", lit("HIGH_MILEAGE")) \
    .withColumn("alert_severity", lit("WARNING")) \
    .withColumn("alert_message",
                concat_ws(" ",
                         lit("Warning: Mileage exceeds 100,000 km -"),
                         col("current_mileage_km"),
                         lit("km")))

# Count alerts before union to provide diagnostics
low_fuel_critical_count = low_fuel_critical.count()
low_fuel_warning_count = low_fuel_warning.count()
high_mileage_count = high_mileage.count()

print(f"[INFO] Low Fuel Critical alerts: {low_fuel_critical_count}")
print(f"[INFO] Low Fuel Warning alerts: {low_fuel_warning_count}")
print(f"[INFO] High Mileage alerts: {high_mileage_count}")

# Union all alerts
all_alerts = low_fuel_critical \
    .union(low_fuel_warning) \
    .union(high_mileage) \
    .withColumn("alert_id", expr("uuid()")) \
    .withColumn("alert_generated_timestamp", current_timestamp()) \
    .select(
        "alert_id",
        "car_chassis",
        "alert_type",
        "alert_severity",
        "alert_message",
        "current_mileage_km",
        "fuel_available_liters",
        "telemetry_timestamp",
        "alert_generated_timestamp"
    ) \
    .withColumn("alert_date", to_date(col("alert_generated_timestamp")))

alert_count = all_alerts.count()
print(f"[OK] Total alerts detected: {alert_count:,}")

# CIRCUIT BREAKER: Exit successfully if no alerts detected
if alert_count == 0:
    print("[INFO] No alerts detected in this run. Skipping write.")
    print("[INFO] This is normal behavior - exiting successfully.")
    spark.stop()
    sys.exit(0)

# Show sample alerts
print("\n[INFO] Sample alerts:")
all_alerts.show(5, truncate=False)

# ============================================================
# DROP SILVER-INHERITED COLUMNS & CHECKPOINT
# ============================================================

print("\n" + "=" * 80)
print("Dropping Silver-inherited columns and forcing materialization")
print("=" * 80)

print(f"\n  Columns in all_alerts BEFORE drop: {len(all_alerts.columns)}")
print(f"  {all_alerts.columns}")

# Drop Silver-only columns if they exist
df_cleaned = all_alerts.drop(
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
# CREATE TEMP VIEW FOR INSERT
# ============================================================

df_final.createOrReplaceTempView("new_alerts")

# ============================================================
# INSERT INTO GOLD TABLE (ICEBERG APPEND)
# ============================================================

print("\n[INFO] Inserting alerts into Gold table...")

# WORKAROUND: Table created via Athena DDL (not via PySpark createOrReplace)
# Reason: PySpark writeTo().createOrReplace() fails with "Writing job aborted"
print("  Using pre-existing Iceberg table (created via Athena DDL)...")

# Verify table exists
try:
    existing_count = spark.sql(f"SELECT COUNT(*) as cnt FROM {GOLD_TABLE}").collect()[0]['cnt']
    print(f"  [OK] Table exists with {existing_count} rows, proceeding with INSERT")
except Exception as e:
    print(f"  [ERROR] Table does not exist! Run athena_ddl_workaround.sql first")
    print(f"  [ERROR] Error details: {str(e)}")
    raise

insert_sql = f"""
INSERT INTO {GOLD_TABLE}
SELECT 
    alert_id,
    car_chassis,
    alert_type,
    alert_severity,
    alert_message,
    current_mileage_km,
    fuel_available_liters,
    telemetry_timestamp,
    alert_generated_timestamp,
    alert_date
FROM new_alerts
"""

try:
    spark.sql(insert_sql)
    print(f"[OK] INSERT INTO completed successfully - {alert_count:,} alerts appended")
    
    # Verify final record count
    final_count = spark.sql(f"SELECT COUNT(*) as cnt FROM {GOLD_TABLE}").collect()[0]['cnt']
    print(f"[INFO] Total alerts in Gold table: {final_count:,}")
    
    # Show alert breakdown
    alert_summary = spark.sql(f"""
        SELECT 
            alert_type,
            alert_severity,
            COUNT(*) as alert_count
        FROM {GOLD_TABLE}
        GROUP BY alert_type, alert_severity
        ORDER BY alert_type, alert_severity
    """)
    
    print("\n[INFO] Alert breakdown:")
    alert_summary.show(truncate=False)
    
except Exception as e:
    print(f"[ERROR] Error executing INSERT INTO: {str(e)}")
    print(f"[DEBUG] Insert SQL: {insert_sql}")
    spark.stop()
    sys.exit(1)

# ============================================================
# JOB SUMMARY
# ============================================================

print("\n" + "=" * 80)
print("JOB COMPLETED SUCCESSFULLY")
print("=" * 80)
print(f"Silver records read: {record_count:,}")
print(f"Alerts detected: {alert_count:,}")
print(f"Gold table total: {final_count:,}")
print(f"Operation: INSERT INTO (append-only)")
print(f"Completed at: {datetime.now()}")
print("=" * 80)

spark.stop()
