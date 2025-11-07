"""
===============================================================================
AWS GLUE JOB: Gold Layer - Fuel Efficiency Monthly Aggregation (KPI 1)
===============================================================================

PURPOSE:
    Calculates monthly fuel efficiency KPIs by aggregating Silver telemetry data.
    Uses incremental processing with Job Bookmarks to efficiently update 
    monthly aggregations without reprocessing historical data.

BUSINESS LOGIC:
    - Reads NEW telemetry data from Silver layer (incremental via bookmarks)
    - Aggregates total mileage and fuel consumption by car/month
    - Merges with existing Gold aggregations (union + re-aggregate)
    - Enables BI tools to calculate efficiency: total_mileage / total_fuel

INPUT:
    - Table: silver_car_telemetry
    - Incremental: Job Bookmarks track processed data
    - Fields: car_chassis, event_year, event_month, 
              trip_distance_km, trip_fuel_consumed_liters

OUTPUT:
    - Table: gold_fuel_efficiency_monthly
    - Path: s3://[GOLD_BUCKET]/fuel_efficiency_monthly/
    - Mode: OVERWRITE (full refresh of aggregation table)
    - Partitioning: event_year, event_month
    - Fields: car_chassis, event_year, event_month, 
              total_mileage, total_fuel, last_updated

INCREMENTAL PATTERN:
    1. Read NEW Silver data (bookmarks)
    2. Aggregate new data → delta DataFrame
    3. Read existing Gold aggregations (if exists)
    4. Union delta + existing data
    5. Re-aggregate (groupBy) to get updated totals
    6. Overwrite Gold table with fresh aggregations

EXECUTION:
    - Triggered by: silver_crawler_succeeded (conditional trigger)
    - Runs in PARALLEL with: gold_car_current_state_job, gold_performance_alerts_job
    - Followed by: gold_fuel_efficiency_crawler (catalogs results)

AUTHOR: AWS Glue ETL Pipeline
DATE: October 31, 2025
VERSION: 1.0
===============================================================================
"""

import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.dynamicframe import DynamicFrame
from pyspark.sql import functions as F
from pyspark.sql.types import StructType, StructField, StringType, DoubleType
from datetime import datetime

# ============================================================
# JOB INITIALIZATION
# ============================================================

# Parse job arguments
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'gold_bucket',
    'glue_database'
])

# Initialize Spark and Glue contexts
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

# Configuration
GOLD_BUCKET = args['gold_bucket']
GLUE_DATABASE = args['glue_database']
SILVER_TABLE = "silver_car_telemetry"  # VIEW com mapeamento de columns (car_chassis → carChassis)
GOLD_TABLE = "gold_fuel_efficiency_monthly"
OUTPUT_PATH = f"s3://{GOLD_BUCKET}/fuel_efficiency_monthly/"

print("=" * 80)
print("GOLD FUEL EFFICIENCY JOB - STARTED")
print("=" * 80)
print(f"Job Name: {args['JOB_NAME']}")
print(f"Gold Bucket: {GOLD_BUCKET}")
print(f"Database: {GLUE_DATABASE}")
print(f"Output Path: {OUTPUT_PATH}")
print(f"Timestamp: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
print("=" * 80)

# ============================================================
# STEP 1: READ NEW SILVER DATA (INCREMENTAL)
# ============================================================

print("\n[STEP 1] Reading NEW Silver telemetry data (incremental via Job Bookmarks)...")

try:
    # Read Silver data with Job Bookmarks enabled
    # transformation_ctx is CRITICAL for bookmark tracking
    dyf_silver_new = glueContext.create_dynamic_frame.from_catalog(
        database=GLUE_DATABASE,
        table_name=SILVER_TABLE,
        transformation_ctx="read_silver_telemetry_incremental"  # Enables bookmarks
    )
    
    df_silver_new = dyf_silver_new.toDF()
    new_records_count = df_silver_new.count()
    
    print(f" Silver data read successfully")
    print(f"   New records to process: {new_records_count}")
    
    if new_records_count == 0:
        print("  No new data to process. Job will exit gracefully.")
        job.commit()
        sys.exit(0)
    
except Exception as e:
    print(f" ERROR reading Silver data: {str(e)}")
    raise

# ============================================================
# STEP 2: AGGREGATE NEW DATA (DELTA)
# ============================================================

print("\n[STEP 2] Aggregating NEW data by car/month (delta aggregation)...")

try:
    # Select required fields and filter nulls
    df_silver_prepared = df_silver_new.select(
        "car_chassis",
        "event_year",
        "event_month",
        "trip_distance_km",
        "trip_fuel_consumed_liters"
    ).filter(
        (F.col("car_chassis").isNotNull()) &
        (F.col("event_year").isNotNull()) &
        (F.col("event_month").isNotNull()) &
        (F.col("trip_distance_km").isNotNull()) &
        (F.col("trip_fuel_consumed_liters").isNotNull()) &
        (F.col("trip_distance_km") >= 0) &  # Sanity check
        (F.col("trip_fuel_consumed_liters") >= 0)  # Sanity check
    )
    
    # Aggregate NEW data (delta)
    df_delta = df_silver_prepared.groupBy(
        "car_chassis",
        "event_year",
        "event_month"
    ).agg(
        F.sum("trip_distance_km").alias("total_mileage_delta"),
        F.sum("trip_fuel_consumed_liters").alias("total_fuel_delta")
    )
    
    delta_records = df_delta.count()
    print(f" Delta aggregation completed")
    print(f"   Aggregated records (new): {delta_records}")
    
    # Show sample
    print("\n   Sample delta aggregations:")
    df_delta.show(5, truncate=False)
    
except Exception as e:
    print(f" ERROR during delta aggregation: {str(e)}")
    raise

# ============================================================
# STEP 3: READ EXISTING GOLD AGGREGATIONS
# ============================================================

print("\n[STEP 3] Reading existing Gold aggregations (if exists)...")

try:
    # Check if Gold table exists
    existing_tables = spark.catalog.listTables(GLUE_DATABASE)
    table_exists = any(table.name == GOLD_TABLE for table in existing_tables)
    
    if table_exists:
        print(f"   Found existing table: {GOLD_TABLE}")
        
        # Read existing aggregations
        df_gold_existing = spark.read.format("parquet").load(OUTPUT_PATH)
        
        existing_records = df_gold_existing.count()
        print(f" Existing Gold data read successfully")
        print(f"   Existing aggregation records: {existing_records}")
        
        # Rename columns to match delta naming for union
        df_gold_existing = df_gold_existing.select(
            "car_chassis",
            "event_year",
            "event_month",
            F.col("total_mileage").alias("total_mileage_delta"),
            F.col("total_fuel").alias("total_fuel_delta")
        )
        
    else:
        print(f"   Table {GOLD_TABLE} does NOT exist yet (first run)")
        print("   Creating empty DataFrame with matching schema...")
        
        # Create empty DataFrame with same schema as delta
        schema = StructType([
            StructField("car_chassis", StringType(), nullable=False),
            StructField("event_year", StringType(), nullable=False),
            StructField("event_month", StringType(), nullable=False),
            StructField("total_mileage_delta", DoubleType(), nullable=True),
            StructField("total_fuel_delta", DoubleType(), nullable=True)
        ])
        
        df_gold_existing = spark.createDataFrame([], schema)
        print(" Empty DataFrame created (first run scenario)")
        
except Exception as e:
    print(f" ERROR reading existing Gold data: {str(e)}")
    raise

# ============================================================
# STEP 4: UNION AND FINAL AGGREGATION (MERGE)
# ============================================================

print("\n[STEP 4] Merging delta with existing data (union + re-aggregate)...")

try:
    # Union new delta with existing aggregations
    df_combined = df_delta.union(df_gold_existing)
    
    combined_records = df_combined.count()
    print(f" Union completed")
    print(f"   Combined records (before re-aggregation): {combined_records}")
    
    # Final aggregation - sum all deltas to get updated totals
    df_final = df_combined.groupBy(
        "car_chassis",
        "event_year",
        "event_month"
    ).agg(
        F.sum("total_mileage_delta").alias("total_mileage"),
        F.sum("total_fuel_delta").alias("total_fuel")
    )
    
    # Add metadata columns
    df_final = df_final.withColumn(
        "last_updated",
        F.lit(datetime.now().strftime('%Y-%m-%d %H:%M:%S'))
    )
    
    # Add calculated efficiency (for reference, though BI tools will recalculate)
    df_final = df_final.withColumn(
        "km_per_liter",
        F.when(F.col("total_fuel") > 0, F.col("total_mileage") / F.col("total_fuel"))
         .otherwise(None)
    )
    
    final_records = df_final.count()
    print(f" Final aggregation completed")
    print(f"   Final aggregation records: {final_records}")
    
    # Show sample results
    print("\n   Sample final aggregations:")
    df_final.orderBy(F.desc("total_mileage")).show(10, truncate=False)
    
    # Statistics
    print("\n   Aggregation Statistics:")
    df_final.select(
        F.count("car_chassis").alias("unique_car_months"),
        F.sum("total_mileage").alias("total_km_all_cars"),
        F.sum("total_fuel").alias("total_fuel_all_cars"),
        F.avg("km_per_liter").alias("avg_efficiency")
    ).show(truncate=False)
    
except Exception as e:
    print(f" ERROR during merge and final aggregation: {str(e)}")
    raise

# ============================================================
# STEP 5: WRITE TO GOLD LAYER (OVERWRITE)
# ============================================================

print("\n[STEP 5] Writing aggregations to Gold layer...")

try:
    # Write with overwrite mode (full refresh of aggregation table)
    df_final.write \
        .mode("overwrite") \
        .partitionBy("event_year", "event_month") \
        .parquet(OUTPUT_PATH)
    
    print(f" Data written successfully to Gold layer")
    print(f"   Output path: {OUTPUT_PATH}")
    print(f"   Mode: OVERWRITE (full table refresh)")
    print(f"   Partitioning: event_year, event_month")
    print(f"   Records written: {final_records}")
    
except Exception as e:
    print(f" ERROR writing to Gold layer: {str(e)}")
    raise

# ============================================================
# JOB COMPLETION
# ============================================================

print("\n" + "=" * 80)
print("GOLD FUEL EFFICIENCY JOB - COMPLETED SUCCESSFULLY")
print("=" * 80)
print(f"Summary:")
print(f"  - New Silver records processed: {new_records_count}")
print(f"  - Delta aggregations: {delta_records}")
print(f"  - Final aggregations: {final_records}")
print(f"  - Output: {OUTPUT_PATH}")
print(f"  - Timestamp: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
print("=" * 80)

# Commit job (updates bookmark state)
job.commit()
