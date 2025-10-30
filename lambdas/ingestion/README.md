# Ingestion Lambda Function - Technical Documentation

## 📋 Overview

The **Ingestion Lambda Function** is a specialized AWS Lambda function that automatically processes CSV files uploaded to the landing S3 bucket, converts them to Parquet format, and stores them in the bronze S3 bucket.

This function is part of the Data Lake pipeline and implements the first step of the Medallion Architecture (Landing → Bronze).

## 🏗️ Architecture

```
┌─────────────────┐      S3 Event      ┌──────────────────────┐
│  Landing Bucket │  ────────────────> │  Ingestion Lambda    │
│   (CSV files)   │   (*.csv upload)   │  + Pandas Layer      │
└─────────────────┘                    └──────────────────────┘
                                                 │
                                                 │ Convert to Parquet
                                                 ▼
                                       ┌─────────────────┐
                                       │  Bronze Bucket  │
                                       │ (Parquet files) │
                                       └─────────────────┘
```

## 🔧 Technical Specifications

### Lambda Configuration
- **Runtime**: Python 3.9
- **Handler**: `lambda_function.lambda_handler`
- **Timeout**: 120 seconds (2 minutes)
- **Memory**: 512 MB
- **Layer**: Pandas + PyArrow (custom layer)

### Dependencies
- **boto3**: AWS SDK (included in Lambda runtime)
- **pandas**: Data manipulation and analysis
- **pyarrow**: Efficient Parquet file format support

### Trigger
- **Type**: S3 Event Notification
- **Source**: Landing bucket (`{project_name}-landing-{environment}`)
- **Event**: `s3:ObjectCreated:*`
- **Filter**: `*.csv` files only

## 📊 Processing Flow

1. **Event Reception**: Lambda receives S3 event when a CSV file is uploaded
2. **File Extraction**: Parses event to get bucket name and file key
3. **CSV Reading**: Downloads and reads CSV file from S3 into memory
4. **DataFrame Creation**: Loads CSV data into Pandas DataFrame
5. **Metadata Addition**: Adds ingestion timestamp and source information
6. **Parquet Conversion**: Converts DataFrame to Parquet format (Snappy compression)
7. **Upload to Bronze**: Uploads Parquet file to bronze bucket with metadata
8. **Logging**: Comprehensive logging of all operations

## 🔐 IAM Permissions Required

The Lambda execution role needs the following permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::*-landing-*",
        "arn:aws:s3:::*-landing-*/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::*-bronze-*/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": [
        "arn:aws:logs:*:*:log-group:/aws/lambda/*:*"
      ]
    }
  ]
}
```

## 📝 Input/Output

### Input (S3 Event)
```json
{
  "Records": [
    {
      "s3": {
        "bucket": {
          "name": "datalake-pipeline-landing-dev"
        },
        "object": {
          "key": "data/sample.csv",
          "size": 1024
        }
      }
    }
  ]
}
```

### Output (Lambda Response)
```json
{
  "statusCode": 200,
  "body": {
    "message": "Ingestion process completed",
    "processed_files": 1,
    "failed_files": 0,
    "details": {
      "processed": [
        {
          "source": "s3://...-landing-.../data/sample.csv",
          "destination": "s3://...-bronze-.../bronze/data/sample.parquet",
          "rows": 1000,
          "columns": 5,
          "original_size": 1024,
          "parquet_size": 512,
          "compression_ratio": "50.00%"
        }
      ]
    }
  }
}
```

## 🚀 Deployment

### Prerequisites
1. Python 3.9+ installed
2. pip package manager
3. AWS CLI configured
4. Terraform installed

### Step 1: Build Lambda Package and Layer

**Windows (PowerShell):**
```powershell
.\build_lambda.ps1
```

**Linux/Mac:**
```bash
chmod +x build_lambda.sh
./build_lambda.sh
```

This script will:
- Create `ingestion_package.zip` (Lambda function code)
- Create `pandas_pyarrow_layer.zip` (Lambda layer with dependencies)
- Place both files in the `assets/` directory

### Step 2: Deploy with Terraform

```bash
cd terraform
terraform init      # If first time
terraform plan      # Review changes
terraform apply     # Deploy infrastructure
```

### Step 3: Verify Deployment

```bash
# Get outputs
terraform output

# Check Lambda function
aws lambda get-function --function-name datalake-pipeline-ingestion-dev

# Check Lambda layer
aws lambda list-layers
```

## 🧪 Testing

### Test 1: Upload a CSV File

Create a test CSV file:
```csv
id,name,age,city,country
1,John Doe,30,New York,USA
2,Jane Smith,25,London,UK
3,Bob Johnson,35,Toronto,Canada
```

Upload to landing bucket:
```bash
aws s3 cp test.csv s3://datalake-pipeline-landing-dev/test.csv
```

### Test 2: Monitor Execution

```bash
# Watch CloudWatch Logs
aws logs tail /aws/lambda/datalake-pipeline-ingestion-dev --follow

# Check bronze bucket for Parquet file
aws s3 ls s3://datalake-pipeline-bronze-dev/bronze/ --recursive
```

### Test 3: Verify Parquet Output

Download and read the Parquet file:
```python
import pandas as pd
import boto3

s3 = boto3.client('s3')
obj = s3.get_object(Bucket='datalake-pipeline-bronze-dev', Key='bronze/test.parquet')
df = pd.read_parquet(obj['Body'])
print(df)
```

## 📊 Monitoring and Logging

### CloudWatch Logs

All execution details are logged to CloudWatch:
- File processing start/end
- DataFrame shape and columns
- Compression ratio
- Success/failure status
- Error messages

### CloudWatch Metrics

Standard Lambda metrics available:
- Invocations
- Duration
- Errors
- Throttles
- Concurrent Executions

### Custom Metrics (Future Enhancement)

Consider adding custom metrics:
- Files processed per hour
- Average compression ratio
- Processing time per file size
- Error rate by file type

## 🐛 Troubleshooting

### Issue: Lambda Timeout

**Symptoms**: Lambda execution exceeds 120 seconds

**Solution**:
1. Increase timeout in `variables.tf`:
   ```hcl
   timeout = 300  # 5 minutes
   ```
2. Increase memory (faster CPU):
   ```hcl
   memory_size = 1024  # 1 GB
   ```

### Issue: Out of Memory

**Symptoms**: Lambda fails with memory error

**Solution**:
1. Increase memory allocation
2. Process files in chunks for large CSVs
3. Consider using S3 Select for filtering

### Issue: Layer Too Large

**Symptoms**: Layer exceeds AWS limit (250 MB)

**Solution**:
1. Use slimmer pandas build:
   ```bash
   pip install pandas --no-deps -t python/
   pip install numpy pyarrow -t python/
   ```
2. Remove unnecessary packages:
   ```bash
   rm -rf python/pandas/tests
   rm -rf python/numpy/tests
   ```

### Issue: Parquet Conversion Fails

**Symptoms**: Error during DataFrame to Parquet conversion

**Solution**:
1. Check data types (convert incompatible types)
2. Handle missing values
3. Validate CSV encoding (UTF-8)

## 🔄 Update Process

### Update Lambda Code Only

```bash
# Rebuild package
.\build_lambda.ps1

# Update Lambda function
aws lambda update-function-code \
  --function-name datalake-pipeline-ingestion-dev \
  --zip-file fileb://../assets/ingestion_package.zip
```

### Update Lambda Layer

```bash
# Rebuild layer
.\build_lambda.ps1

# Publish new layer version
aws lambda publish-layer-version \
  --layer-name datalake-pipeline-pandas-pyarrow-layer \
  --zip-file fileb://../assets/pandas_pyarrow_layer.zip \
  --compatible-runtimes python3.9

# Update Lambda to use new layer
aws lambda update-function-configuration \
  --function-name datalake-pipeline-ingestion-dev \
  --layers <new-layer-arn>
```

### Update via Terraform

```bash
cd terraform
terraform apply  # Terraform will detect changes and update
```

## 📈 Performance Optimization

### Current Performance
- **Small files (<1MB)**: ~2-3 seconds
- **Medium files (1-10MB)**: ~5-15 seconds
- **Large files (10-100MB)**: ~30-90 seconds

### Optimization Tips

1. **Increase Memory**: More memory = faster CPU
2. **Chunked Processing**: For files >100MB, process in chunks
3. **S3 Transfer Acceleration**: Enable for faster uploads
4. **Compression**: Snappy (fast) vs Gzip (smaller)
5. **Concurrent Executions**: Adjust reserved concurrency

## 🔐 Security Best Practices

1. **Least Privilege**: IAM role has minimal permissions
2. **Encryption**: S3 buckets use SSE-AES256
3. **No Secrets in Code**: Use environment variables
4. **VPC Configuration**: Consider VPC endpoints for S3
5. **CloudTrail Logging**: Enable for audit trail

## 📚 References

- [AWS Lambda with S3](https://docs.aws.amazon.com/lambda/latest/dg/with-s3.html)
- [Pandas Documentation](https://pandas.pydata.org/docs/)
- [PyArrow Parquet](https://arrow.apache.org/docs/python/parquet.html)
- [Lambda Layers](https://docs.aws.amazon.com/lambda/latest/dg/configuration-layers.html)

## 📞 Support

For issues or questions:
1. Check CloudWatch Logs
2. Review Terraform state: `terraform show`
3. Test locally with sample data
4. Contact DevOps team

---

**Last Updated**: $(Get-Date -Format "yyyy-MM-dd")
**Version**: 1.0.0
**Status**: Production Ready
