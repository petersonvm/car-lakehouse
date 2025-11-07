"""
AWS Glue ETL Job - Gold Layer: Car Current State
=================================================

Objective:
- Read consolidated data from Silver Layer (full history)
- Apply "Current State" logic (1 row per car_chassis)
- Write snapshot to Gold Bucket (full overwrite)

Business Logic:
- Business key: car_chassis
- Selection rule: current_mileage_km DESC (highest = most recent)
- Result: 1 unique record per vehicle (current state)

Characteristics:
- Reading: Full Silver Table (no partitioning)
- Transformation: Window Function (row_number)
- Writing: Full overwrite (static snapshot)
- Output: Non-partitioned Parquet (small table)

Author: Data Lakehouse System - Gold Layer
Date: 2025-10-30
"""

import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job

from pyspark.sql import functions as F
from pyspark.sql.window import Window
from pyspark.sql.functions import col, to_date, current_date, datediff, when, lit
from datetime import datetime

# ============================================================================
# 1. JOB INITIALIZATION
# ============================================================================

print("\n" + "=" * 80)
print(" AWS GLUE JOB - GOLD LAYER: CAR CURRENT STATE")
print("=" * 80)

# Obter parâmetros do Job
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'silver_database',
    'silver_table',
    'gold_database',
    'gold_bucket',
    'gold_path'
])

print(f"\n Job parameters:")
print(f"   Job Name: {args['JOB_NAME']}")
print(f"   Silver Database: {args['silver_database']}")
print(f"   Silver Table: {args['silver_table']}")
print(f"   Gold Database: {args['gold_database']}")
print(f"   Gold Bucket: {args['gold_bucket']}")
print(f"   Gold Path: {args['gold_path']}")

# Inicializar contextos Spark e Glue
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

print("\n Spark and Glue contexts initialized successfully")

# ============================================================================
# 2. READING FROM SILVER LAYER
# ============================================================================

print("\n" + "=" * 80)
print(" STEP 1: Reading consolidated data from Silver Layer")
print("=" * 80)

print(f"\n   Database: {args['silver_database']}")
print(f"   Table: {args['silver_table']}")

# Read full Silver table from Glue Data Catalog
silver_dynamic_frame = glueContext.create_dynamic_frame.from_catalog(
    database=args['silver_database'],
    table_name=args['silver_table'],
    transformation_ctx="silver_data"
)

# Convert to DataFrame
df_silver = silver_dynamic_frame.toDF()

# Count total records
total_records = df_silver.count()
print(f"\n    Records read from Silver: {total_records}")

if total_records == 0:
    print("\n     WARNING: No data found in Silver Layer!")
    print("   Finalizing job without generating Gold data.")
    job.commit()
    print("\n JOB COMPLETED (no data to process)")
    # Don't use sys.exit() - let it complete naturally
else:
    print("\n    Silver Layer Schema:")
    df_silver.printSchema()

    # Show Silver data sample
    print("\n    Silver data sample (first 5 records):")
    df_silver.select(
        "car_chassis",
        "current_mileage_km",
        "telemetry_timestamp",
        "event_year",
        "event_month",
        "event_day"
    ).show(5, truncate=False)

    # ============================================================================
    # 3. TRANSFORMATION: CURRENT STATE (WINDOW FUNCTION)
    # ============================================================================

    print("\n" + "=" * 80)
    print(" STEP 2: Applying 'Current State' logic")
    print("=" * 80)

    print("\n    Business Rule:")
    print("      - 1 record per car_chassis (vehicle)")
    print("      - Criteria: HIGHEST current_mileage_km (most recent)")
    print("      - Method: Window Function with row_number()")

    # Define Window Specification
    # Partition by: car_chassis (each vehicle)
    # Order by: current_mileage_km DESC (highest mileage = most recent)
    window_spec = Window.partitionBy("car_chassis").orderBy(F.col("current_mileage_km").desc())

    print("\n    Applying Window Function...")

    # Add row_number column
    df_with_row_number = df_silver.withColumn(
        "row_num",
        F.row_number().over(window_spec)
    )

    print("       row_number() applied")

    # Filter only row_number = 1 (current state)
    df_current_state = df_with_row_number.filter(F.col("row_num") == 1).drop("row_num")

    current_state_count = df_current_state.count()
    vehicles_deduped = total_records - current_state_count

    print(f"\n    Transformation Result:")
    print(f"      - Historical records (Silver): {total_records}")
    print(f"      - Current state records (Gold): {current_state_count}")
    print(f"      - Historical records discarded: {vehicles_deduped}")
    print(f"      - Reduction rate: {(vehicles_deduped / total_records * 100):.1f}%")

    # ============================================================================
    # 4. ENRICHMENT: INSURANCE KPIs
    # ============================================================================

    print("\n" + "=" * 80)
    print("  STEP 3: Enrichment with Insurance KPIs")
    print("=" * 80)

    print("\n    Insurance KPIs to be calculated:")
    print("      1. insurance_status (String): EXPIRED | EXPIRING_IN_90_DAYS | ACTIVE")
    print("      2. insurance_days_expired (Int): Days since expiration (null if active)")
    print("\n    Business Logic:")
    print("      - Source: insurance_valid_until (flattened field from Silver)")
    print("      - Reference: current_date() at execution time")
    print("      - EXPIRED: validUntil < current_date")
    print("      - EXPIRING_IN_90_DAYS: 0 <= days_remaining <= 90")
    print("      - ACTIVE: days_remaining > 90")

    print("\n    Applying date transformations...")

    # Define date columns
    current_date_col = current_date()
    # Flattened field from Silver: insurance_valid_until (format: "2026-10-29")
    valid_until_date_col = to_date(col("insurance_valid_until"), "yyyy-MM-dd")

    # Calculate difference in days
    # datediff(end_date, start_date) -> Positive if end_date > start_date
    # In this case: datediff(validUntil, current_date)
    # - Positive = days remaining until expiration
    # - Negative = days expired
    days_diff_col = datediff(valid_until_date_col, current_date_col)

    print("       Date columns configured")
    print("         - current_date: Job execution date")
    print("         - valid_until: insurance_valid_until converted to date")
    print("         - days_diff: Difference in days (positive = remaining, negative = expired)")

    # Enrich DataFrame with insurance KPIs
    df_enriched = df_current_state.withColumn(
        "insurance_status",
        when(days_diff_col < 0, "EXPIRED")
        .when((days_diff_col >= 0) & (days_diff_col <= 90), "EXPIRING_IN_90_DAYS")
        .otherwise("ACTIVE")
    ).withColumn(
        "insurance_days_expired",
        when(days_diff_col < 0, -days_diff_col)  # Convert negative to expired days
        .otherwise(lit(None).cast("int"))         # Null if not expired
    )

    print("       Insurance KPIs added")

    # Insurance status statistics
    print("\n    Insurance Status Distribution:")
    insurance_stats = df_enriched.groupBy("insurance_status").count().orderBy(F.col("count").desc())
    insurance_stats.show(10, truncate=False)

    # Show sample with new fields
    print("\n    Data sample with Insurance KPIs:")
    df_enriched.select(
        "car_chassis",
        "manufacturer",
        "model",
        "insurance_valid_until",
        "insurance_status",
        "insurance_days_expired"
    ).orderBy(F.col("current_mileage_km").desc()).show(5, truncate=False)

    # ============================================================================
    # 5. ADDITIONAL ENRICHMENT (GOLD METADATA)
    # ============================================================================

    print("\n" + "=" * 80)
    print(" STEP 4: Additional Gold Layer enrichment")
    print("=" * 80)

    # Add processing timestamp (Gold metadata)
    df_gold = df_enriched.withColumn(
        "gold_processing_timestamp",
        F.current_timestamp()
    ).withColumn(
        "gold_snapshot_date",
        F.current_date()
    )

    print("    Gold metadata added:")
    print("      - gold_processing_timestamp: job execution timestamp")
    print("      - gold_snapshot_date: snapshot date")

    # Calculate aggregated metrics (optional - example)
    print("\n    Current State Statistics:")
    
    # Count vehicles by manufacturer
    manufacturer_stats = df_gold.groupBy("manufacturer").count().orderBy(F.col("count").desc())
    print("\n    Vehicles by Manufacturer:")
    manufacturer_stats.show(10, truncate=False)

    # Show final Gold data sample
    print("\n    Gold data sample (current state - first 5 vehicles):")
    df_gold.select(
        "car_chassis",
        "manufacturer",
        "model",
        "current_mileage_km",
        "telemetry_timestamp",
        "gold_processing_timestamp"
    ).orderBy(F.col("current_mileage_km").desc()).show(5, truncate=False)

    # ============================================================================
    # 6. WRITING TO GOLD BUCKET (FULL OVERWRITE)
    # ============================================================================

    print("\n" + "=" * 80)
    print(" STEP 5: Writing data to Gold Bucket")
    print("=" * 80)

    gold_output_path = f"s3://{args['gold_bucket']}/{args['gold_path']}"
    
    print(f"\n    Write Configuration:")
    print(f"      - Bucket: {args['gold_bucket']}")
    print(f"      - Path: {args['gold_path']}")
    print(f"      - Full Path: {gold_output_path}")
    print(f"      - Mode: overwrite (full snapshot)")
    print(f"      - Format: parquet")
    print(f"      - Compression: snappy")
    print(f"      - Partitioning: None (small table)")

    print("\n    Starting write...")

    # Write data using Spark DataFrame Writer
    # Overwrite mode: overwrites entire directory (static snapshot)
    df_gold.write \
        .mode("overwrite") \
        .format("parquet") \
        .option("compression", "snappy") \
        .save(gold_output_path)

    print(f"\n    Data written successfully!")
    print(f"    Total records in Gold: {current_state_count}")

    # Verify written files
    print("\n    Generated Parquet files:")
    try:
        files_df = spark.read.parquet(gold_output_path)
        num_files = len([f for f in spark._jvm.org.apache.hadoop.fs.FileSystem.get(
            spark._jsc.hadoopConfiguration()
        ).listStatus(
            spark._jvm.org.apache.hadoop.fs.Path(gold_output_path)
        ) if f.getPath().getName().endswith(".parquet")])
        print(f"      - Number of files: {num_files}")
        print(f"      - Total records: {files_df.count()}")
    except Exception as e:
        print(f"        Could not list files: {e}")

    # ============================================================================
    # 7. JOB FINALIZATION
    # ============================================================================

    print("\n" + "=" * 80)
    print(" JOB COMPLETED SUCCESSFULLY!")
    print("=" * 80)
    
    print(f"\n Final Summary:")
    print(f"   - Records read (Silver): {total_records}")
    print(f"   - Unique vehicles (Gold): {current_state_count}")
    print(f"   - Data reduction: {(vehicles_deduped / total_records * 100):.1f}%")
    print(f"   - KPIs added: insurance_status, insurance_days_expired")
    print(f"   - Output Path: {gold_output_path}")
    print(f"   - Snapshot Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    
    print("\n Final Insurance Status Distribution:")
    final_insurance_stats = df_gold.groupBy("insurance_status").count().collect()
    for row in final_insurance_stats:
        print(f"   - {row['insurance_status']}: {row['count']} vehicles")
    
    print("\n" + "=" * 80)
    print(" Next Steps:")
    print("   1. Workflow will trigger Gold Crawler automatically")
    print("   2. Crawler will update 'gold_car_current_state' table in catalog")
    print("   3. Data will be available for querying in Athena")
    print("   4. New columns available:")
    print("      - insurance_status: Vehicle insurance status")
    print("      - insurance_days_expired: Days expired (if applicable)")
    print("=" * 80)

    # Job commit
    job.commit()

    print("\n Job commit completed successfully")