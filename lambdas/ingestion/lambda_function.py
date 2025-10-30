"""
AWS Lambda Function - Bronze Layer Ingestion
Reads JSON files from landing bucket and saves them as Parquet in bronze bucket.
Preserves nested structures (metrics, market, etc.) as struct columns in Parquet.
"""

import json
import boto3
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from io import BytesIO
from datetime import datetime
from urllib.parse import unquote_plus
import uuid
import os

# Initialize S3 client
s3_client = boto3.client('s3')

def normalize_numeric_types(obj, is_inside_struct=False):
    """
    Recursively convert numeric types to float only inside known struct fields.
    This ensures schema consistency for nested structures (metrics, market, etc.)
    while preserving natural types for top-level scalar fields.
    
    Struct fields that should have floats: metrics, market, carInsurance
    
    Args:
        obj: dict, list, or primitive value
        is_inside_struct: whether we're processing inside a struct field
        
    Returns:
        Normalized object
    """
    # Known struct field names (these contain nested data)
    STRUCT_FIELDS = {'metrics', 'market', 'carInsurance', 'owner', 'trip'}
    
    if isinstance(obj, dict):
        result = {}
        for k, v in obj.items():
            # Mark as inside struct if key is a known struct field
            is_struct = k in STRUCT_FIELDS or is_inside_struct
            result[k] = normalize_numeric_types(v, is_struct)
        return result
    elif isinstance(obj, list):
        return [normalize_numeric_types(item, is_inside_struct) for item in obj]
    elif isinstance(obj, int) and not isinstance(obj, bool) and is_inside_struct:
        # Convert integers to float ONLY inside struct fields
        return float(obj)
    else:
        return obj

def lambda_handler(event, context):
    """
    Lambda handler for S3 triggered events on JSON files.
    Reads JSON, converts to Parquet preserving nested structures,
    and partitions by ingestion date.
    
    Args:
        event: S3 event notification
        context: Lambda context object
        
    Returns:
        dict: Response with status and processed files
    """
    
    # Get environment variables
    bronze_bucket = os.environ.get('BRONZE_BUCKET')
    landing_bucket_env = os.environ.get('LANDING_BUCKET')
    
    print(f"Ingestion Lambda started at {datetime.utcnow().isoformat()}")
    print(f"Bronze bucket: {bronze_bucket}")
    
    processed_files = []
    failed_files = []
    
    try:
        # Process each record in the S3 event
        for record in event['Records']:
            try:
                # Extract S3 event information
                source_bucket = record['s3']['bucket']['name']
                source_key = unquote_plus(record['s3']['object']['key'])
                file_size = record['s3']['object']['size']
                
                print(f"\n{'='*60}")
                print(f"Processing file: {source_key}")
                print(f"Source bucket: {source_bucket}")
                print(f"File size: {file_size} bytes")
                
                # Only process JSON files
                file_extension = source_key.lower().split('.')[-1]
                
                if file_extension != 'json':
                    print(f"Skipping non-JSON file: {source_key} (.{file_extension})")
                    continue
                
                print(f"File type detected: JSON")
                
                # Read JSON file from S3
                print(f"Reading JSON file from S3...")
                response = s3_client.get_object(Bucket=source_bucket, Key=source_key)
                file_content = response['Body'].read()
                
                # Parse JSON
                json_data = json.loads(file_content.decode('utf-8'))
                print(f"JSON successfully parsed")
                
                # Normalize numeric types in nested structures to float
                # This prevents schema inconsistencies (int64 vs double)
                json_data = normalize_numeric_types(json_data)
                
                # Load into Pandas DataFrame WITHOUT flattening
                # This preserves nested structures (metrics, market) as struct columns
                if isinstance(json_data, dict):
                    # Single JSON object - wrap in list to create single-row DataFrame
                    df = pd.DataFrame([json_data])
                elif isinstance(json_data, list):
                    # Array of JSON objects
                    df = pd.DataFrame(json_data)
                else:
                    raise ValueError(f"Unsupported JSON structure: {type(json_data)}")
                
                print(f"DataFrame shape: {df.shape}")
                print(f"Columns: {list(df.columns)}")
                print(f"Data types:\n{df.dtypes}")
                
                # Get current timestamp for partitioning (ingestion date)
                ingestion_time = datetime.utcnow()
                
                # Add partition columns (will be removed before writing to avoid duplication)
                df['ingest_year'] = ingestion_time.year
                df['ingest_month'] = ingestion_time.month
                df['ingest_day'] = ingestion_time.day
                
                # Add metadata columns
                df['ingestion_timestamp'] = ingestion_time.isoformat()
                df['source_file'] = source_key
                df['source_bucket'] = source_bucket
                
                print(f"Added metadata and partition columns")
                
                # Create partitioned path using ingest date
                # bronze/car_data/ingest_year=YYYY/ingest_month=MM/ingest_day=DD/
                partitioned_path = f"car_data/ingest_year={ingestion_time.year}/ingest_month={ingestion_time.month:02d}/ingest_day={ingestion_time.day:02d}"
                
                # Generate unique filename
                file_id = str(uuid.uuid4())[:8]
                timestamp_str = ingestion_time.strftime('%Y%m%d_%H%M%S')
                parquet_filename = f"car_data_{timestamp_str}_{file_id}.parquet"
                dest_key = f"bronze/{partitioned_path}/{parquet_filename}"
                
                print(f"Partitioned destination: {dest_key}")
                print(f"Partition: ingest_year={ingestion_time.year}/ingest_month={ingestion_time.month:02d}/ingest_day={ingestion_time.day:02d}")
                
                # Remove partition columns from DataFrame before writing
                # They will be in the S3 path, not in the data
                df_to_write = df.drop(columns=['ingest_year', 'ingest_month', 'ingest_day'])
                
                print(f"DataFrame to write shape: {df_to_write.shape}")
                print(f"Columns to write: {list(df_to_write.columns)}")
                
                # Convert DataFrame to Parquet in memory
                # PyArrow will automatically convert nested dicts to struct columns
                print("Converting to Parquet format (preserving nested structures)...")
                parquet_buffer = BytesIO()
                
                # Write to Parquet using pyarrow engine
                # This preserves nested structures as struct columns
                df_to_write.to_parquet(
                    parquet_buffer,
                    engine='pyarrow',
                    compression='snappy',
                    index=False
                )
                
                # Reset buffer position
                parquet_buffer.seek(0)
                parquet_size = len(parquet_buffer.getvalue())
                
                print(f"Parquet size: {parquet_size} bytes")
                print(f"Compression ratio: {(1 - parquet_size/file_size)*100:.2f}%")
                
                # Upload Parquet file to bronze bucket
                # This is wrapped to ensure source deletion only happens on success
                try:
                    print(f"Uploading to bronze bucket: {bronze_bucket}")
                    s3_client.put_object(
                        Bucket=bronze_bucket,
                        Key=dest_key,
                        Body=parquet_buffer.getvalue(),
                        ContentType='application/octet-stream',
                        Metadata={
                            'source-file': source_key,
                            'source-bucket': source_bucket,
                            'original-format': 'JSON',
                            'rows': str(len(df_to_write)),
                            'columns': str(len(df_to_write.columns)),
                            'ingestion-timestamp': ingestion_time.isoformat(),
                            'partition-year': str(ingestion_time.year),
                            'partition-month': str(ingestion_time.month),
                            'partition-day': str(ingestion_time.day),
                            'partitioned': 'true',
                            'nested-structures-preserved': 'true'
                        }
                    )
                    
                    print(f"✅ Successfully uploaded to Bronze: {dest_key}")
                    
                    # Delete the source file from landing bucket ONLY after successful Bronze write
                    # This ensures we don't lose data if the write fails
                    print(f"Deleting source file from landing bucket: {source_key}")
                    s3_client.delete_object(
                        Bucket=source_bucket,
                        Key=source_key
                    )
                    print(f"✅ Source file deleted from landing: {source_key}")
                    
                    # Mark as successfully processed
                    processed_files.append({
                        'source': f"s3://{source_bucket}/{source_key}",
                        'destination': f"s3://{bronze_bucket}/{dest_key}",
                        'rows': len(df_to_write),
                        'columns': len(df_to_write.columns),
                        'original_size': file_size,
                        'parquet_size': parquet_size,
                        'compression_ratio': f"{(1 - parquet_size/file_size)*100:.2f}%",
                        'source_deleted': True,
                        'partitioned': True,
                        'partition_path': partitioned_path,
                        'partition_year': ingestion_time.year,
                        'partition_month': ingestion_time.month,
                        'partition_day': ingestion_time.day,
                        'nested_structures_preserved': True
                    })
                    
                except Exception as upload_error:
                    # If upload or deletion fails, log error but don't delete source
                    error_msg = f"Failed to upload to Bronze or delete source: {str(upload_error)}"
                    print(f"❌ {error_msg}")
                    print(f"ℹ️  Source file preserved in landing bucket: {source_key}")
                    raise  # Re-raise to be caught by outer exception handler
                
            except Exception as file_error:
                error_msg = f"Error processing file {source_key}: {str(file_error)}"
                print(f"❌ {error_msg}")
                failed_files.append({
                    'file': source_key,
                    'error': str(file_error)
                })
                # Continue processing other files
                continue
        
        # Prepare response
        response = {
            'statusCode': 200 if not failed_files else 207,  # 207 = Multi-Status
            'body': json.dumps({
                'message': 'Ingestion process completed',
                'processed_files': len(processed_files),
                'failed_files': len(failed_files),
                'details': {
                    'processed': processed_files,
                    'failed': failed_files
                }
            }, indent=2)
        }
        
        print(f"\n{'='*60}")
        print(f"Summary: {len(processed_files)} processed, {len(failed_files)} failed")
        print(f"Lambda execution completed at {datetime.utcnow().isoformat()}")
        
        return response
        
    except Exception as e:
        error_msg = f"Critical error in lambda_handler: {str(e)}"
        print(f"❌ {error_msg}")
        
        return {
            'statusCode': 500,
            'body': json.dumps({
                'message': 'Ingestion process failed',
                'error': str(e)
            })
        }
