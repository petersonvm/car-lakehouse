# AWS Configuration
variable "aws_region" {
  description = "AWS region where resources will be created"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name to be used as prefix for resource naming"
  type        = string
  default     = "datalake-pipeline"
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
  default     = "dev"
}

# S3 Buckets Configuration (Medallion Architecture)
variable "s3_buckets" {
  description = "Map of S3 buckets for the Data Lake (Medallion Architecture)"
  type = map(object({
    name_suffix = string
    versioning  = bool
    lifecycle_rules = object({
      enabled                         = bool
      transition_to_glacier_days      = number
      transition_to_deep_archive_days = number
      expiration_days                 = number
    })
  }))
  default = {
    landing = {
      name_suffix = "landing"
      versioning  = true
      lifecycle_rules = {
        enabled                         = true
        transition_to_glacier_days      = 90
        transition_to_deep_archive_days = 180
        expiration_days                 = 365
      }
    }
    bronze = {
      name_suffix = "bronze"
      versioning  = true
      lifecycle_rules = {
        enabled                         = true
        transition_to_glacier_days      = 180
        transition_to_deep_archive_days = 365
        expiration_days                 = 730
      }
    }
    silver = {
      name_suffix = "silver"
      versioning  = true
      lifecycle_rules = {
        enabled                         = true
        transition_to_glacier_days      = 365
        transition_to_deep_archive_days = 730
        expiration_days                 = 1095
      }
    }
    gold = {
      name_suffix = "gold"
      versioning  = true
      lifecycle_rules = {
        enabled                         = false
        transition_to_glacier_days      = 0
        transition_to_deep_archive_days = 0
        expiration_days                 = 0
      }
    }
  }
}

# Lambda Functions Configuration (Generic/Dummy Functions)
# Note: ingestion function is now defined separately with real implementation
variable "lambda_functions" {
  description = "Map of Lambda functions for data processing/ETL (generic implementations)"
  type = map(object({
    name_suffix      = string
    description      = string
    handler          = string
    runtime          = string
    timeout          = number
    memory_size      = number
    environment_vars = map(string)
  }))
  default = {
    analysis = {
      name_suffix = "analysis"
      description = "Lambda function for data analysis (Silver to Gold)"
      handler     = "main.handler"
      runtime     = "python3.9"
      timeout     = 600
      memory_size = 1024
      environment_vars = {
        STAGE = "analysis"
      }
    }
    compliance = {
      name_suffix = "compliance"
      description = "Lambda function for compliance validation (Gold layer)"
      handler     = "main.handler"
      runtime     = "python3.9"
      timeout     = 300
      memory_size = 512
      environment_vars = {
        STAGE = "compliance"
      }
    }
  }
}

# Ingestion Lambda Configuration (Dedicated Function)
variable "ingestion_lambda_config" {
  description = "Configuration for the dedicated ingestion Lambda function"
  type = object({
    function_name    = string
    description      = string
    handler          = string
    runtime          = string
    timeout          = number
    memory_size      = number
    environment_vars = map(string)
  })
  default = {
    function_name = "ingestion"
    description   = "Lambda function for data ingestion - Converts CSV/JSON to Parquet (Landing to Bronze)"
    handler       = "lambda_function.lambda_handler"
    runtime       = "python3.9"
    timeout       = 120
    memory_size   = 512
    environment_vars = {
      STAGE = "ingestion"
    }
  }
}

variable "lambda_package_path" {
  description = "Path to the Lambda function deployment package (for generic functions)"
  type        = string
  default     = "../assets/dummy_package.zip"
}

variable "ingestion_package_path" {
  description = "Path to the ingestion Lambda deployment package"
  type        = string
  default     = "../assets/ingestion_package.zip"
}

variable "cleansing_lambda_config" {
  description = "Configuration for the dedicated cleansing Lambda function (Silver Layer)"
  type = object({
    function_name    = string
    description      = string
    handler          = string
    runtime          = string
    timeout          = number
    memory_size      = number
    environment_vars = map(string)
  })
  default = {
    function_name = "cleansing"
    description   = "Lambda function for data cleansing - Transforms Bronze Parquet (nested) to Silver Parquet (flattened)"
    handler       = "lambda_function.lambda_handler"
    runtime       = "python3.9"
    timeout       = 300
    memory_size   = 1024
    environment_vars = {
      STAGE = "cleansing"
    }
  }
}

variable "cleansing_package_path" {
  description = "Path to the cleansing Lambda deployment package"
  type        = string
  default     = "../assets/cleansing_package.zip"
}

variable "pandas_layer_path" {
  description = "Path to the Pandas/PyArrow Lambda Layer package"
  type        = string
  default     = "../assets/pandas_pyarrow_layer.zip"
}

# AWS Glue Configuration
variable "glue_crawler_schedule" {
  description = "Cron expression for Glue Crawler schedule (optional). Leave empty for manual execution. Format: cron(Minutes Hours Day-of-month Month Day-of-week Year)"
  type        = string
  default     = "cron(0 0 * * ? *)"  # Daily at midnight UTC (00:00). Empty = manual execution only
}

variable "bronze_crawler_schedule" {
  description = "Cron expression for Bronze car_data Glue Crawler schedule. Format: cron(Minutes Hours Day-of-month Month Day-of-week Year)"
  type        = string
  default     = "cron(0 0 * * ? *)"  # Daily at midnight UTC (00:00)
}

variable "silver_crawler_schedule" {
  description = "Cron expression for Silver Glue Crawler schedule. Format: cron(Minutes Hours Day-of-month Month Day-of-week Year)"
  type        = string
  default     = "cron(0 1 * * ? *)"  # Daily at 01:00 UTC
}

# Silver Layer Lambda Configuration
variable "silver_lambda_memory" {
  description = "Memory allocation for Silver layer Lambda function (MB)"
  type        = number
  default     = 1024
}

variable "silver_lambda_timeout" {
  description = "Timeout for Silver layer Lambda function (seconds)"
  type        = number
  default     = 600  # 10 minutes
}

variable "silver_etl_schedule" {
  description = "EventBridge Scheduler expression for Silver ETL Lambda. Examples: rate(1 hour), rate(30 minutes)"
  type        = string
  default     = "rate(1 hour)"  # Runs every hour
}

variable "lambda_log_retention_days" {
  description = "CloudWatch log retention period in days"
  type        = number
  default     = 7
}

variable "log_level" {
  description = "Log level for Lambda functions (DEBUG, INFO, WARNING, ERROR)"
  type        = string
  default     = "INFO"
}

# Amazon Athena Configuration
variable "athena_bytes_scanned_cutoff" {
  description = "Maximum bytes scanned per query (cost control). Set to 0 for no limit."
  type        = number
  default     = 100000000000  # 100 GB limit
}

# ============================================
# AWS Glue Job Configuration
# ============================================

variable "glue_silver_script_path" {
  description = "Local path to the Silver consolidation PySpark script"
  type        = string
  default     = "../glue_jobs/silver_consolidation_job.py"
}

variable "glue_version" {
  description = "AWS Glue version to use for ETL jobs"
  type        = string
  default     = "4.0"  # Latest version with Spark 3.3 and Python 3
}

variable "glue_worker_type" {
  description = "Worker type for Glue Job (G.1X, G.2X, G.025X, etc.)"
  type        = string
  default     = "G.1X"  # 4 vCPU, 16 GB RAM
}

variable "glue_number_of_workers" {
  description = "Number of workers for Glue Job"
  type        = number
  default     = 2
}

variable "glue_job_timeout_minutes" {
  description = "Timeout for Glue Job in minutes"
  type        = number
  default     = 60
}

variable "glue_job_max_retries" {
  description = "Maximum number of retries for Glue Job on failure"
  type        = number
  default     = 1
}

variable "glue_max_concurrent_runs" {
  description = "Maximum number of concurrent runs for Glue Job"
  type        = number
  default     = 1
}

variable "glue_trigger_schedule" {
  description = "Cron expression for Glue Job trigger. Format: cron(Minutes Hours Day-of-month Month Day-of-week Year)"
  type        = string
  default     = "cron(0 */1 * * ? *)"  # Every hour
}

variable "glue_trigger_enabled" {
  description = "Enable or disable the Glue Job trigger"
  type        = bool
  default     = true
}

# AWS Glue Workflow Schedule
# Orchestrates Job → Crawler sequence automatically to reduce Athena catalog latency
variable "glue_workflow_schedule" {
  description = "Cron expression for Glue Workflow trigger (orchestrates Job → Crawler sequence). Format: cron(Minutes Hours Day-of-month Month Day-of-week Year)"
  type        = string
  default     = "cron(0 */1 * * ? *)"  # Every hour (matches Job schedule for seamless migration)
}

variable "bronze_table_name" {
  description = "Name of the Bronze table in Glue Catalog"
  type        = string
  default     = "car_bronze"
}

variable "silver_table_name" {
  description = "Name of the Silver table in Glue Catalog"
  type        = string
  default     = "silver_car_telemetry"  # Tabela Silver com schema snake_case
}

variable "silver_path" {
  description = "Path within Silver S3 bucket for data storage"
  type        = string
  default     = "car_telemetry/"
}

variable "cloudwatch_log_retention_days" {
  description = "CloudWatch log retention period in days for Glue Job"
  type        = number
  default     = 14
}

# Silver Table Refactoring Variables
variable "silver_bucket_name" {
  description = "Nome do bucket Silver (computed from data_lake bucket)"
  type        = string
  default     = ""  # Will be computed from aws_s3_bucket.data_lake["silver"].bucket
}

variable "bronze_bucket_name" {
  description = "Nome do bucket Bronze (computed from data_lake bucket)"
  type        = string
  default     = ""  # Will be computed from aws_s3_bucket.data_lake["bronze"].bucket
}

variable "glue_scripts_bucket" {
  description = "Bucket para scripts Glue"
  type        = string
  default     = ""  # Will be computed from aws_s3_bucket.glue_scripts.bucket
}

variable "glue_temp_bucket" {
  description = "Bucket temporário do Glue"
  type        = string
  default     = ""  # Will be computed from aws_s3_bucket.glue_temp.bucket
}

variable "glue_role_arn" {
  description = "ARN da role do Glue (computed from existing role)"
  type        = string
  default     = ""  # Will be computed from aws_iam_role resource
}

# Common Tags
variable "common_tags" {
  description = "Common tags to be applied to all resources"
  type        = map(string)
  default = {
    Project     = "DataLake-Pipeline"
    ManagedBy   = "Terraform"
    Environment = "dev"
  }
}
