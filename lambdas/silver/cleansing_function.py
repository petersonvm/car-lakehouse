"""
AWS Lambda Function - Silver Layer Cleansing
============================================
Transforms raw JSON data from Bronze layer into clean, partitioned Parquet files in Silver layer.

Trigger: S3 ObjectCreated event on bronze-bucket (JSON files)
Input: JSON files from Bronze bucket
Output: Partitioned Parquet files in Silver bucket (partitioned by event date)

Author: Data Engineering Team
Version: 1.0.0
"""

import json
import logging
import os
import uuid
from datetime import datetime
from io import BytesIO

import boto3
import pandas as pd

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize S3 client
s3_client = boto3.client('s3')

# Environment variables
SILVER_BUCKET = os.environ.get('SILVER_BUCKET_NAME', 'datalake-pipeline-silver-dev')
TABLE_NAME = os.environ.get('TABLE_NAME', 'car_telemetry')


def lambda_handler(event, context):
    """
    Main Lambda handler for Silver layer data cleansing.
    
    Args:
        event (dict): S3 event notification containing bucket and object information
        context (object): Lambda context object
        
    Returns:
        dict: Response with status code and processing details
    """
    try:
        logger.info("Starting Silver layer cleansing process")
        logger.info(f"Event received: {json.dumps(event)}")
        
        # Parse S3 event
        bucket_name, object_key = parse_s3_event(event)
        logger.info(f"Processing file: s3://{bucket_name}/{object_key}")
        
        # Read data from Bronze bucket (supports JSON and Parquet)
        df = read_data_from_s3(bucket_name, object_key)
        logger.info(f"Successfully read data from Bronze bucket: {len(df)} rows, {len(df.columns)} columns")
        
        # Apply cleansing transformations (only if needed - Bronze may already be clean)
        df = apply_cleansing(df)
        logger.info("Applied cleansing transformations")
        
        # Apply type conversions
        df = convert_data_types(df)
        logger.info("Converted data types")
        
        # Enrich with calculated columns
        df = enrich_data(df)
        logger.info("Enriched data with calculated columns")
        
        # Create partition columns
        df = create_partition_columns(df)
        logger.info("Created partition columns")
        
        # Write to Silver bucket
        output_path = write_to_silver(df)
        logger.info(f"Successfully wrote data to Silver: {output_path}")
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Silver cleansing completed successfully',
                'input_file': f"s3://{bucket_name}/{object_key}",
                'output_path': output_path,
                'rows_processed': len(df),
                'columns': len(df.columns)
            })
        }
        
    except Exception as e:
        logger.error(f"Error processing Silver cleansing: {str(e)}", exc_info=True)
        return {
            'statusCode': 500,
            'body': json.dumps({
                'message': 'Error processing Silver cleansing',
                'error': str(e)
            })
        }


def parse_s3_event(event):
    """
    Extract bucket name and object key from S3 event.
    
    Args:
        event (dict): S3 event notification
        
    Returns:
        tuple: (bucket_name, object_key)
    """
    try:
        # Handle different event formats (direct S3 event or SQS-wrapped)
        if 'Records' in event:
            record = event['Records'][0]
            
            # Check if it's an SQS message wrapping an S3 event
            if 'body' in record:
                s3_event = json.loads(record['body'])
                s3_record = s3_event['Records'][0]['s3']
            else:
                s3_record = record['s3']
            
            bucket_name = s3_record['bucket']['name']
            object_key = s3_record['object']['key']
        else:
            # Fallback for manual invocation
            bucket_name = event.get('bucket_name') or event.get('source_bucket')
            object_key = event.get('object_key') or event.get('file_key')
        
        if not bucket_name or not object_key:
            raise ValueError("Missing bucket_name or object_key in event")
        
        return bucket_name, object_key
        
    except Exception as e:
        logger.error(f"Error parsing S3 event: {str(e)}")
        raise


def read_data_from_s3(bucket_name, object_key):
    """
    Read data file from S3 bucket (supports JSON and Parquet).
    
    Args:
        bucket_name (str): S3 bucket name
        object_key (str): S3 object key
        
    Returns:
        pd.DataFrame: DataFrame with data
    """
    try:
        # Detect file type by extension
        file_extension = object_key.lower().split('.')[-1]
        
        if file_extension == 'parquet':
            # Read Parquet file
            logger.info(f"Reading Parquet file from s3://{bucket_name}/{object_key}")
            s3_path = f"s3://{bucket_name}/{object_key}"
            df = pd.read_parquet(s3_path)
            logger.info(f"Successfully read Parquet: {len(df)} rows")
            
        elif file_extension == 'json':
            # Read JSON file
            logger.info(f"Reading JSON file from s3://{bucket_name}/{object_key}")
            response = s3_client.get_object(Bucket=bucket_name, Key=object_key)
            content = response['Body'].read().decode('utf-8')
            
            # Try to parse as JSON
            try:
                json_data = json.loads(content)
            except json.JSONDecodeError:
                # Try to parse as JSON Lines (one JSON per line)
                json_data = [json.loads(line) for line in content.strip().split('\n') if line.strip()]
            
            # Convert to DataFrame
            if isinstance(json_data, dict):
                json_data = [json_data]
            
            df = pd.json_normalize(json_data, sep='_')
            logger.info(f"Successfully read JSON: {len(df)} rows")
            
        else:
            raise ValueError(f"Unsupported file type: {file_extension}. Supported: json, parquet")
        
        return df
        
    except Exception as e:
        logger.error(f"Error reading data from S3: {str(e)}")
        raise


def read_json_from_s3(bucket_name, object_key):
    """
    Read JSON file from S3 bucket.
    
    Args:
        bucket_name (str): S3 bucket name
        object_key (str): S3 object key
        
    Returns:
        dict or list: Parsed JSON data
    """
    try:
        response = s3_client.get_object(Bucket=bucket_name, Key=object_key)
        content = response['Body'].read().decode('utf-8')
        
        # Try to parse as JSON
        try:
            json_data = json.loads(content)
        except json.JSONDecodeError:
            # Try to parse as JSON Lines (one JSON per line)
            json_data = [json.loads(line) for line in content.strip().split('\n') if line.strip()]
        
        return json_data
        
    except Exception as e:
        logger.error(f"Error reading JSON from S3: {str(e)}")
        raise


def transform_json_to_dataframe(json_data):
    """
    Transform JSON data to flattened Pandas DataFrame.
    
    Args:
        json_data (dict or list): JSON data
        
    Returns:
        pd.DataFrame: Flattened DataFrame
    """
    try:
        # Ensure json_data is a list for json_normalize
        if isinstance(json_data, dict):
            json_data = [json_data]
        
        # Flatten nested JSON using pandas.json_normalize
        # Use '_' as separator for nested keys
        df = pd.json_normalize(json_data, sep='_')
        
        logger.info(f"Flattened DataFrame columns: {df.columns.tolist()}")
        
        return df
        
    except Exception as e:
        logger.error(f"Error transforming JSON to DataFrame: {str(e)}")
        raise


def apply_cleansing(df):
    """
    Apply data cleansing transformations.
    
    Args:
        df (pd.DataFrame): Input DataFrame
        
    Returns:
        pd.DataFrame: Cleaned DataFrame
    """
    try:
        # Create a copy to avoid modifying original
        df = df.copy()
        
        # Clean Manufacturer: Convert to Title Case
        if 'Manufacturer' in df.columns:
            df['Manufacturer'] = df['Manufacturer'].str.title()
            logger.info("Cleaned 'Manufacturer' column (Title Case)")
        
        # Clean color: Convert to lowercase
        if 'color' in df.columns:
            df['color'] = df['color'].str.lower()
            logger.info("Cleaned 'color' column (lowercase)")
        
        # Remove any leading/trailing whitespace from string columns
        string_columns = df.select_dtypes(include=['object']).columns
        for col in string_columns:
            if df[col].dtype == 'object':
                df[col] = df[col].astype(str).str.strip()
        
        return df
        
    except Exception as e:
        logger.error(f"Error applying cleansing: {str(e)}")
        raise


def convert_data_types(df):
    """
    Convert data types for specific columns.
    
    Args:
        df (pd.DataFrame): Input DataFrame
        
    Returns:
        pd.DataFrame: DataFrame with converted types
    """
    try:
        # Create a copy to avoid modifying original
        df = df.copy()
        
        # Convert metrics_metricTimestamp to datetime
        if 'metrics_metricTimestamp' in df.columns:
            df['metrics_metricTimestamp'] = pd.to_datetime(
                df['metrics_metricTimestamp'], 
                format='%a, %d %b %Y %H:%M:%S',
                errors='coerce'
            )
            logger.info("Converted 'metrics_metricTimestamp' to datetime")
        
        # Convert metrics_trip_tripStartTimestamp to datetime
        if 'metrics_trip_tripStartTimestamp' in df.columns:
            df['metrics_trip_tripStartTimestamp'] = pd.to_datetime(
                df['metrics_trip_tripStartTimestamp'],
                format='%a, %d %b %Y %H:%M:%S',
                errors='coerce'
            )
            logger.info("Converted 'metrics_trip_tripStartTimestamp' to datetime")
        
        # Convert carInsurance_validUntil to date
        if 'carInsurance_validUntil' in df.columns:
            df['carInsurance_validUntil'] = pd.to_datetime(
                df['carInsurance_validUntil'],
                format='%Y-%m-%d',
                errors='coerce'
            ).dt.date
            logger.info("Converted 'carInsurance_validUntil' to date")
        
        # Convert numeric columns explicitly
        numeric_columns = [
            'year', 'ModelYear', 'horsePower', 'currentMileage', 'fuelCapacityLiters',
            'metrics_engineTempCelsius', 'metrics_oilTempCelsius', 'metrics_batteryChargePerc',
            'metrics_fuelAvailableLiters', 'metrics_coolantCelsius',
            'metrics_trip_tripMileage', 'metrics_trip_tripTimeMinutes', 'metrics_trip_tripFuelLiters',
            'metrics_trip_tripMaxSpeedKm', 'metrics_trip_tripAverageSpeedKm',
            'market_currentPrice', 'market_warrantyYears'
        ]
        
        for col in numeric_columns:
            if col in df.columns:
                df[col] = pd.to_numeric(df[col], errors='coerce')
        
        logger.info(f"Converted {len([c for c in numeric_columns if c in df.columns])} numeric columns")
        
        return df
        
    except Exception as e:
        logger.error(f"Error converting data types: {str(e)}")
        raise


def enrich_data(df):
    """
    Enrich data with calculated columns.
    
    Args:
        df (pd.DataFrame): Input DataFrame
        
    Returns:
        pd.DataFrame: Enriched DataFrame
    """
    try:
        # Create a copy to avoid modifying original
        df = df.copy()
        
        # Calculate fuel level percentage
        if 'metrics_fuelAvailableLiters' in df.columns and 'fuelCapacityLiters' in df.columns:
            df['metrics_fuel_level_percentage'] = (
                df['metrics_fuelAvailableLiters'] / df['fuelCapacityLiters']
            ).round(4)
            logger.info("Created 'metrics_fuel_level_percentage' column")
        
        # Calculate trip km per liter (fuel efficiency)
        if 'metrics_trip_tripMileage' in df.columns and 'metrics_trip_tripFuelLiters' in df.columns:
            # Handle division by zero: return 0 if tripFuelLiters is 0
            df['metrics_trip_km_per_liter'] = df.apply(
                lambda row: round(row['metrics_trip_tripMileage'] / row['metrics_trip_tripFuelLiters'], 2)
                if row['metrics_trip_tripFuelLiters'] > 0 else 0.0,
                axis=1
            )
            logger.info("Created 'metrics_trip_km_per_liter' column")
        
        # Add processing metadata
        df['silver_processing_timestamp'] = datetime.utcnow()
        df['silver_processing_date'] = datetime.utcnow().date()
        
        logger.info("Added processing metadata columns")
        
        return df
        
    except Exception as e:
        logger.error(f"Error enriching data: {str(e)}")
        raise


def create_partition_columns(df):
    """
    Create partition columns based on event timestamp.
    
    Args:
        df (pd.DataFrame): Input DataFrame
        
    Returns:
        pd.DataFrame: DataFrame with partition columns
    """
    try:
        # Create a copy to avoid modifying original
        df = df.copy()
        
        # Extract partition columns from metrics_metricTimestamp
        if 'metrics_metricTimestamp' in df.columns:
            df['event_year'] = df['metrics_metricTimestamp'].dt.year
            df['event_month'] = df['metrics_metricTimestamp'].dt.month.astype(str).str.zfill(2)
            df['event_day'] = df['metrics_metricTimestamp'].dt.day.astype(str).str.zfill(2)
            
            logger.info("Created partition columns: event_year, event_month, event_day")
        else:
            # Fallback: use current date if metrics_metricTimestamp is not available
            logger.warning("metrics_metricTimestamp not found, using current date for partitions")
            now = datetime.utcnow()
            df['event_year'] = now.year
            df['event_month'] = str(now.month).zfill(2)
            df['event_day'] = str(now.day).zfill(2)
        
        return df
        
    except Exception as e:
        logger.error(f"Error creating partition columns: {str(e)}")
        raise


def write_to_silver(df):
    """
    Write DataFrame to Silver bucket as partitioned Parquet file.
    
    Args:
        df (pd.DataFrame): DataFrame to write
        
    Returns:
        str: S3 path where data was written
    """
    try:
        # Get partition values from first row (all rows should have same partition)
        if len(df) == 0:
            raise ValueError("DataFrame is empty, cannot write to Silver")
        
        event_year = df['event_year'].iloc[0]
        event_month = df['event_month'].iloc[0]
        event_day = df['event_day'].iloc[0]
        
        # Generate unique filename
        file_id = str(uuid.uuid4())
        timestamp = datetime.utcnow().strftime('%Y%m%d_%H%M%S')
        filename = f"{TABLE_NAME}_{timestamp}_{file_id}.parquet"
        
        # Construct S3 partition path
        partition_path = f"{TABLE_NAME}/event_year={event_year}/event_month={event_month}/event_day={event_day}"
        s3_key = f"{partition_path}/{filename}"
        
        # Remove partition columns from data (they're in the path)
        df_to_write = df.drop(columns=['event_year', 'event_month', 'event_day'], errors='ignore')
        
        # Convert DataFrame to Parquet in memory
        parquet_buffer = BytesIO()
        df_to_write.to_parquet(
            parquet_buffer,
            engine='pyarrow',
            compression='snappy',
            index=False
        )
        
        # Reset buffer position to beginning
        parquet_buffer.seek(0)
        
        # Upload to S3
        s3_client.put_object(
            Bucket=SILVER_BUCKET,
            Key=s3_key,
            Body=parquet_buffer.getvalue(),
            ContentType='application/octet-stream',
            Metadata={
                'source': 'silver-cleansing-lambda',
                'record_count': str(len(df)),
                'partition_year': str(event_year),
                'partition_month': str(event_month),
                'partition_day': str(event_day),
                'processing_timestamp': datetime.utcnow().isoformat()
            }
        )
        
        output_path = f"s3://{SILVER_BUCKET}/{s3_key}"
        logger.info(f"Successfully wrote {len(df)} rows to {output_path}")
        
        return output_path
        
    except Exception as e:
        logger.error(f"Error writing to Silver bucket: {str(e)}")
        raise


# For local testing
if __name__ == "__main__":
    # Sample test event
    test_event = {
        "Records": [
            {
                "s3": {
                    "bucket": {
                        "name": "datalake-pipeline-bronze-dev"
                    },
                    "object": {
                        "key": "bronze/partition_year=2025/partition_month=10/partition_day=29/car_data_20251029_110000.json"
                    }
                }
            }
        ]
    }
    
    result = lambda_handler(test_event, None)
    print(json.dumps(result, indent=2))
