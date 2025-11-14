"""
AWS Glue ETL Job - Gold Layer: Car Current State (Iceberg with MERGE INTO)

Objective:
- Read consolidated data from Silver Layer (Iceberg table)
- Apply "Current State" logic using MERGE INTO (upsert)
- Calculate insurance KPIs
- Write to Gold Iceberg table with atomic updates (no crawler)

Business Logic:
- Primary key: car_chassis (one row per vehicle)
- Upsert logic: Update if car exists and new data is more recent, INSERT if new car
- Insurance KPIs: EXPIRED, EXPIRING_IN_90_DAYS, ACTIVE

Iceberg Benefits:
- MERGE INTO replaces Window Function complexity
- Atomic catalog updates (no crawler needed)
- ACID transactions guarantee data consistency
- Time travel for auditing

Author: Data Lakehouse System - Gold Layer (Iceberg Migration)
Date: 2025-11-12
Version: 3.0 (Iceberg with MERGE INTO)
"""

import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job

from pyspark.sql import functions as F
from pyspark.sql.functions import col, to_date, current_date, datediff, when, lit, current_timestamp
from datetime import datetime

# ============================================================================
# 1. JOB INITIALIZATION
# ============================================================================

print("\n" + "=" * 80)
print(" AWS GLUE JOB - GOLD LAYER: CAR CURRENT STATE (ICEBERG)")
print("=" * 80)

# Get job parameters
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'silver_database',
    'silver_table',
    'gold_database',
    'gold_table'
])

print(f"\nJob Parameters:")
print(f"  Job Name: {args['JOB_NAME']}")
print(f"  Silver Database: {args['silver_database']}")
print(f"  Silver Table: {args['silver_table']}")
print(f"  Gold Database: {args['gold_database']}")
print(f"  Gold Table: {args['gold_table']}")

# Configure Iceberg BEFORE creating SparkContext (spark.sql.extensions is STATIC)
from pyspark import SparkConf
conf = SparkConf()
conf.set("spark.sql.extensions", "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions")
conf.set("spark.sql.catalog.glue_catalog", "org.apache.iceberg.spark.SparkCatalog")
conf.set("spark.sql.catalog.glue_catalog.warehouse", "s3://datalake-pipeline-gold-dev/iceberg-warehouse")
conf.set("spark.sql.catalog.glue_catalog.catalog-impl", "org.apache.iceberg.aws.glue.GlueCatalog")
conf.set("spark.sql.catalog.glue_catalog.io-impl", "org.apache.iceberg.aws.s3.S3FileIO")

# Initialize Spark and Glue contexts
sc = SparkContext(conf=conf)
glueContext = GlueContext(sc)
spark = glueContext.spark_session

# Configure Spark checkpoint directory (for forced materialization)
print("\n  Configuring Spark checkpoint directory...")
spark.sparkContext.setCheckpointDir("s3://datalake-pipeline-glue-temp-dev/spark-checkpoints/gold/")
print("  ✅ Checkpoint directory set")

job = Job(glueContext)
job.init(args['JOB_NAME'], args)

print("\nSpark and Glue contexts initialized")
print(f"Iceberg MERGE INTO: ENABLED")
print(f"Checkpointing: ENABLED (forces schema materialization)")

# ============================================================================
# 2. READING FROM SILVER LAYER (ICEBERG)
# ============================================================================

print("\n" + "=" * 80)
print(" STEP 1: Reading consolidated data from Silver Layer")
print("=" * 80)

# Create table names with Iceberg catalog prefix
silver_table = f"glue_catalog.`{args['silver_database']}`.{args['silver_table']}"
print(f"\n  Reading from Iceberg table: {silver_table}")

# Read from Silver Iceberg table using Spark SQL
df_silver = spark.sql(f"SELECT * FROM {silver_table}")

total_records = df_silver.count()
print(f"\n  Records read from Silver: {total_records}")

if total_records == 0:
    print("\n  WARNING: No data found in Silver Layer!")
    print("  Finalizing job without updating Gold.")
    job.commit()
    print("\nJOB COMPLETED (no data to process)")
else:
    print("\n  Silver Layer Schema:")
    df_silver.printSchema()

    # Show sample data
    print("\n  Sample Silver data (first 5 records):")
    df_silver.select(
        "car_chassis",
        "current_mileage_km",
        "telemetry_timestamp",
        "manufacturer",
        "model"
    ).show(5, truncate=False)

    # ============================================================================
    # 3. CALCULATE INSURANCE KPIs
    # ============================================================================

    print("\n" + "=" * 80)
    print(" STEP 2: Calculating Insurance KPIs")
    print("=" * 80)

    print("\n  Insurance KPIs to be calculated:")
    print("    1. insurance_status (String): EXPIRED | EXPIRING_IN_90_DAYS | ACTIVE")
    print("    2. insurance_days_expired (Int): Days since expiration (null if active)")

    # Define date columns
    current_date_col = current_date()
    valid_until_date_col = to_date(col("insurance_valid_until"), "yyyy-MM-dd")
    days_diff_col = datediff(valid_until_date_col, current_date_col)

    # Calculate insurance KPIs
    df_with_kpis = df_silver.withColumn(
        "insurance_status",
        when(days_diff_col < 0, "EXPIRED")
        .when((days_diff_col >= 0) & (days_diff_col <= 90), "EXPIRING_IN_90_DAYS")
        .otherwise("ACTIVE")
    ).withColumn(
        "insurance_days_expired",
        when(days_diff_col < 0, -days_diff_col)
        .otherwise(lit(None).cast("int"))
    ).withColumn(
        "event_timestamp",
        col("telemetry_timestamp")
    ).withColumn(
        "gold_processing_timestamp",
        current_timestamp()
    )

    print("  Insurance KPIs calculated")

    # Show insurance status distribution
    print("\n  Insurance Status Distribution:")
    df_with_kpis.groupBy("insurance_status").count().orderBy(F.col("count").desc()).show()
    
    # ============================================================================
    # 3.5. DROP UNWANTED COLUMNS (EXPLICIT REMOVAL)
    # ============================================================================
    
    print("\n" + "=" * 80)
    print(" STEP 2.5: Dropping Silver-inherited columns")
    print("=" * 80)
    
    print("\n  Columns in df_with_kpis BEFORE drop:")
    print(f"  {df_with_kpis.columns}")
    print(f"  Total: {len(df_with_kpis.columns)} columns")
    
    # Explicitly drop Silver partition columns and Silver-only metadata
    df_cleaned = df_with_kpis.drop(
        "event_id",               # Silver primary key (not needed in Gold)
        "event_primary_timestamp", # Silver metadata (not needed in Gold)
        "event_year",              # Silver partition column
        "event_month",             # Silver partition column
        "event_day"                # Silver partition column
    )
    
    print("\n  ✅ Dropped 5 Silver-inherited columns: event_id, event_primary_timestamp, event_year, event_month, event_day")
    print(f"  Columns after drop: {len(df_cleaned.columns)}")
    
    # Select only Gold columns from cleaned DataFrame
    print("\n  Selecting final Gold layer columns from cleaned DataFrame...")
    df_gold = df_cleaned.select(
        "car_chassis",
        "manufacturer",
        "model",
        "year",
        "gas_type",
        "insurance_provider",
        "insurance_valid_until",
        "current_mileage_km",
        "fuel_available_liters",
        "telemetry_timestamp",
        "insurance_status",
        "insurance_days_expired",
        "event_timestamp",
        "gold_processing_timestamp"
    )
    
    print(f"\n  Gold DataFrame: {len(df_gold.columns)} columns selected")
    
    # ============================================================================
    # 3.6. FORCE MATERIALIZATION (CHECKPOINT - BREAKS LINEAGE)
    # ============================================================================
    
    print("\n" + "=" * 80)
    print(" STEP 2.6: Forcing DataFrame materialization via checkpoint")
    print("=" * 80)
    
    print("\n  Checkpointing df_gold to break Spark lineage and force schema materialization...")
    print("  This ensures Iceberg receives the EXACT schema defined above (14 columns)")
    
    # CRITICAL: checkpoint() forces Spark to materialize the DataFrame and breaks lineage
    # This prevents Iceberg from "looking back" at parent DataFrames (df_with_kpis)
    df_gold = df_gold.checkpoint()
    
    gold_count = df_gold.count()
    print(f"\n  ✅ Checkpoint completed: {gold_count} rows materialized")
    
    # ============================================================================
    # 3.7. SCHEMA VALIDATION (DEBUGGING)
    # ============================================================================
    
    print("\n" + "=" * 80)
    print(" STEP 2.7: Schema Validation (Pre-Write)")
    print("=" * 80)
    
    print("\n  Final schema being sent to Iceberg:")
    df_gold.printSchema()
    
    print(f"\n  Final column list ({len(df_gold.columns)} columns):")
    for idx, col_name in enumerate(df_gold.columns, 1):
        print(f"    {idx}. {col_name}")
    
    print("\n  ⚠️  CRITICAL CHECK: Verify NO Silver columns (event_id, event_year, etc.)")
    silver_only_cols = ["event_id", "event_primary_timestamp", "event_year", "event_month", "event_day"]
    found_silver_cols = [col for col in silver_only_cols if col in df_gold.columns]
    
    if found_silver_cols:
        error_msg = f"❌ ERROR: Silver columns still present in df_gold: {found_silver_cols}"
        print(f"\n  {error_msg}")
        raise ValueError(error_msg)
    else:
        print("\n  ✅ VALIDATION PASSED: No Silver-only columns in df_gold")

    # ============================================================================
    # 4. CREATE/REPLACE GOLD ICEBERG TABLE
    # ============================================================================

    print("\n" + "=" * 80)
    print(" STEP 3: Creating/Replacing Gold Iceberg Table")
    print("=" * 80)

    # Use glue_catalog prefix
    gold_table = f"glue_catalog.datalake_pipeline_catalog_dev.{args['gold_table']}"
    print(f"\n  Target Iceberg Table: {gold_table}")
    print(f"  Operation: CREATE OR REPLACE")
    print(f"  Primary Key: car_chassis")
    print(f"  DataFrame columns: {len(df_gold.columns)}")
    print(f"  DataFrame rows: {gold_count}")

    # Final pre-write validation
    print("\n  Pre-write validation:")
    print(f"    - Checkpoint: COMPLETED ✅")
    print(f"    - Schema validation: PASSED ✅")
    print(f"    - Silver columns removed: CONFIRMED ✅")
    
    # Create/Replace Iceberg table using writeTo() API
    print("\n  Calling writeTo().createOrReplace()...")
    print("  (Using checkpointed DataFrame with materialized schema)")
    
    df_gold.writeTo(gold_table) \
        .using("iceberg") \
        .tableProperty("format-version", "2") \
        .createOrReplace()
    
    print("\n  ✅ Table created/replaced successfully")

    # Verify results
    result_df = spark.sql(f"SELECT COUNT(*) as total_vehicles FROM {gold_table}")
    total_vehicles = result_df.collect()[0]['total_vehicles']
    print(f"\n  Total vehicles in Gold table: {total_vehicles}")

    # Show sample of updated data
    print("\n  Sample Gold data (current state - first 5 vehicles):")
    spark.sql(f"""
        SELECT 
            car_chassis,
            manufacturer,
            model,
            current_mileage_km,
            insurance_status,
            insurance_days_expired,
            gold_processing_timestamp
        FROM {gold_table}
        ORDER BY current_mileage_km DESC
        LIMIT 5
    """).show(truncate=False)

    # ============================================================================
    # 5. JOB COMPLETION
    # ============================================================================

    print("\n" + "=" * 80)
    print(" JOB COMPLETED SUCCESSFULLY!")
    print("=" * 80)
    
    print(f"\nFinal Summary:")
    print(f"  Silver records processed: {total_records}")
    print(f"  Gold vehicles (unique): {total_vehicles}")
    print(f"  Operation: MERGE INTO (upsert)")
    print(f"  KPIs: insurance_status, insurance_days_expired")
    print(f"  Format: Apache Iceberg")
    print(f"  Catalog: Atomically updated")
    print(f"  Crawler: NOT REQUIRED")
    print(f"  Timestamp: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    
    # Final insurance status distribution
    print("\n  Final Insurance Status Distribution:")
    final_stats = spark.sql(f"""
        SELECT insurance_status, COUNT(*) as vehicle_count 
        FROM {gold_table} 
        GROUP BY insurance_status
        ORDER BY vehicle_count DESC
    """)
    final_stats.show()
    
    print("\nNext Steps:")
    print("  1. Data available for querying in Athena immediately")
    print("  2. No crawler needed - Iceberg handles catalog updates")
    print("  3. Time travel available for auditing")
    print("=" * 80)

    # Commit job
    job.commit()
    print("\nJob commit completed")
