#!/usr/bin/env python3
"""
Script: Create car_bronze Table in Glue Data Catalog
Purpose: Manually creates the "car_bronze" table in AWS Glue Data Catalog.

Background:
-----------
AWS Glue Crawlers infer table names from S3 paths and cannot directly control
the exact table name. Since we need the table to be named "car_bronze" (not
"car_data" which would be inferred from the path s3://.../bronze/car_data/),
this table must be created manually before running the Bronze crawler.

The crawler will then UPDATE the existing table (add partitions, update schema)
instead of creating a new one.

Usage:
------
    python scripts/create_car_bronze_table.py --environment dev

Requirements:
-------------
    - AWS CLI configured with appropriate credentials
    - boto3 installed: pip install boto3
    - Glue Data Catalog database already exists

Table Schema:
-------------
The table includes the following columns with nested structs:
- event_id: string
- event_primary_timestamp: string
- processing_timestamp: string
- carChassis: string
- vehicle_static_info: struct (nested)
- vehicle_dynamic_state: struct (nested with sub-structs)
- current_rental_agreement: struct (nested)
- trip_data: struct (nested with sub-structs)
- ingestion_timestamp: string
- source_file: string
- source_bucket: string

Partitioned by:
- ingest_year: string
- ingest_month: string
- ingest_day: string
"""

import boto3
import argparse
from botocore.exceptions import ClientError

def create_car_bronze_table(environment: str = "dev"):
    """
    Creates the car_bronze table in AWS Glue Data Catalog.
    
    Args:
        environment: Environment name (dev, stg, prod)
    """
    
    # Initialize Glue client
    glue_client = boto3.client('glue', region_name='us-east-1')
    
    database_name = f"datalake-pipeline-catalog-{environment}"
    table_name = "car_bronze"
    bucket_name = f"datalake-pipeline-bronze-{environment}"
    location = f"s3://{bucket_name}/bronze/car_data/"
    
    # Table definition
    table_input = {
        "Name": table_name,
        "StorageDescriptor": {
            "Columns": [
                {"Name": "event_id", "Type": "string", "Comment": "Unique event identifier"},
                {"Name": "event_primary_timestamp", "Type": "string", "Comment": "Primary timestamp of the event"},
                {"Name": "processing_timestamp", "Type": "string", "Comment": "Processing timestamp"},
                {"Name": "carChassis", "Type": "string", "Comment": "Vehicle chassis number (unique identifier)"},
                {
                    "Name": "vehicle_static_info",
                    "Type": "struct<data:struct<Manufacturer:string,Model:string,ModelYear:bigint,color:string,fuelCapacityLiters:bigint,gasType:string,year:bigint>,extraction_timestamp:string,source_system:string>",
                    "Comment": "Static vehicle information (manufacturer, model, year, etc.)"
                },
                {
                    "Name": "vehicle_dynamic_state",
                    "Type": "struct<insurance_info:struct<data:struct<policy_number:string,provider:string,validUntil:string>,extraction_timestamp:string,source_system:string>,maintenance_info:struct<data:struct<last_service_date:string,last_service_mileage:bigint,oil_life_percentage:double>,extraction_timestamp:string,source_system:string>>",
                    "Comment": "Dynamic vehicle state (insurance, maintenance)"
                },
                {
                    "Name": "current_rental_agreement",
                    "Type": "struct<data:struct<agreement_id:string,customer_id:string,rental_start_date:string>,extraction_timestamp:string,source_system:string>",
                    "Comment": "Current rental agreement information"
                },
                {
                    "Name": "trip_data",
                    "Type": "struct<trip_summary:struct<data:struct<tripEndTimestamp:string,tripFuelLiters:double,tripMaxSpeedKm:bigint,tripMileage:double,tripStartTimestamp:string,tripTimeMinutes:bigint>,extraction_timestamp:string,source_system:string>,vehicle_telemetry_snapshot:struct<data:struct<batteryChargePerc:bigint,currentMileage:bigint,engineTempCelsius:bigint,fuelAvailableLiters:double,oilTempCelsius:bigint,tire_pressures_psi:struct<front_left:double,front_right:double,rear_left:double,rear_right:double>>,extraction_timestamp:string,source_system:string>>",
                    "Comment": "Trip data with telemetry and summary"
                },
                {"Name": "ingestion_timestamp", "Type": "string", "Comment": "Lambda ingestion timestamp"},
                {"Name": "source_file", "Type": "string", "Comment": "Original JSON filename"},
                {"Name": "source_bucket", "Type": "string", "Comment": "Source S3 bucket"}
            ],
            "Location": location,
            "InputFormat": "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat",
            "OutputFormat": "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat",
            "SerdeInfo": {
                "SerializationLibrary": "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe",
                "Parameters": {
                    "serialization.format": "1"
                }
            },
            "StoredAsSubDirectories": False
        },
        "PartitionKeys": [
            {"Name": "ingest_year", "Type": "string", "Comment": "Ingestion year (YYYY)"},
            {"Name": "ingest_month", "Type": "string", "Comment": "Ingestion month (MM)"},
            {"Name": "ingest_day", "Type": "string", "Comment": "Ingestion day (DD)"}
        ],
        "TableType": "EXTERNAL_TABLE",
        "Parameters": {
            "classification": "parquet",
            "compressionType": "snappy",
            "typeOfData": "file",
            "EXTERNAL": "TRUE",
            "comment": "Bronze layer table for car data with nested structures. Created manually to control exact table name."
        }
    }
    
    try:
        # Check if table already exists
        try:
            glue_client.get_table(DatabaseName=database_name, Name=table_name)
            print(f"⚠️  Table '{table_name}' already exists in database '{database_name}'")
            print("   No action taken. Delete the table first if you want to recreate it.")
            return False
        except ClientError as e:
            if e.response['Error']['Code'] != 'EntityNotFoundException':
                raise
        
        # Create the table
        print(f"Creating table '{table_name}' in database '{database_name}'...")
        glue_client.create_table(
            DatabaseName=database_name,
            TableInput=table_input
        )
        
        print(f"✅ Table '{table_name}' created successfully!")
        print(f"   Database: {database_name}")
        print(f"   Location: {location}")
        print(f"   Partition Keys: ingest_year, ingest_month, ingest_day")
        print(f"\n📝 Next steps:")
        print(f"   1. Run the Bronze crawler to discover partitions")
        print(f"   2. The crawler will UPDATE this table (not create a new one)")
        
        return True
        
    except ClientError as e:
        print(f"❌ Error creating table: {e}")
        return False

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Create car_bronze table in Glue Data Catalog"
    )
    parser.add_argument(
        "--environment",
        type=str,
        default="dev",
        choices=["dev", "stg", "prod"],
        help="Environment (dev, stg, prod)"
    )
    
    args = parser.parse_args()
    
    print(f"🚀 Creating car_bronze table for environment: {args.environment}\n")
    success = create_car_bronze_table(args.environment)
    
    exit(0 if success else 1)
