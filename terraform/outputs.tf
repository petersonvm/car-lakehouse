# S3 Buckets Outputs
output "s3_bucket_names" {
  description = "Map of S3 bucket names"
  value = {
    for k, v in aws_s3_bucket.data_lake : k => v.id
  }
}

output "s3_bucket_arns" {
  description = "Map of S3 bucket ARNs"
  value = {
    for k, v in aws_s3_bucket.data_lake : k => v.arn
  }
}

output "s3_bucket_regional_domain_names" {
  description = "Map of S3 bucket regional domain names"
  value = {
    for k, v in aws_s3_bucket.data_lake : k => v.bucket_regional_domain_name
  }
}

# Lambda Functions Outputs (Generic Functions)
output "lambda_function_names" {
  description = "Map of generic Lambda function names"
  value = {
    for k, v in aws_lambda_function.etl : k => v.function_name
  }
}

output "lambda_function_arns" {
  description = "Map of generic Lambda function ARNs"
  value = {
    for k, v in aws_lambda_function.etl : k => v.arn
  }
}

output "lambda_function_invoke_arns" {
  description = "Map of generic Lambda function invoke ARNs"
  value = {
    for k, v in aws_lambda_function.etl : k => v.invoke_arn
  }
}

# Ingestion Lambda Outputs (Dedicated Function)
output "ingestion_lambda_name" {
  description = "Name of the ingestion Lambda function"
  value       = aws_lambda_function.ingestion.function_name
}

output "ingestion_lambda_arn" {
  description = "ARN of the ingestion Lambda function"
  value       = aws_lambda_function.ingestion.arn
}

output "ingestion_lambda_invoke_arn" {
  description = "Invoke ARN of the ingestion Lambda function"
  value       = aws_lambda_function.ingestion.invoke_arn
}

output "ingestion_lambda_version" {
  description = "Version of the ingestion Lambda function"
  value       = aws_lambda_function.ingestion.version
}

# Cleansing Lambda Outputs (Silver Layer - Dedicated Function)
output "cleansing_lambda_name" {
  description = "Name of the cleansing Lambda function (Silver Layer)"
  value       = aws_lambda_function.cleansing.function_name
}

output "cleansing_lambda_arn" {
  description = "ARN of the cleansing Lambda function"
  value       = aws_lambda_function.cleansing.arn
}

output "cleansing_lambda_invoke_arn" {
  description = "Invoke ARN of the cleansing Lambda function"
  value       = aws_lambda_function.cleansing.invoke_arn
}

output "cleansing_lambda_version" {
  description = "Version of the cleansing Lambda function"
  value       = aws_lambda_function.cleansing.version
}

# Lambda Layer Outputs
output "pandas_layer_arn" {
  description = "ARN of the Pandas/PyArrow Lambda Layer"
  value       = aws_lambda_layer_version.pandas_pyarrow.arn
}

output "pandas_layer_version" {
  description = "Version of the Pandas/PyArrow Lambda Layer"
  value       = aws_lambda_layer_version.pandas_pyarrow.version
}

output "lambda_layers_bucket" {
  description = "S3 bucket used for Lambda Layer storage"
  value       = aws_s3_bucket.lambda_layers.id
}

# IAM Role Output
output "lambda_execution_role_arn" {
  description = "ARN of the Lambda execution IAM role"
  value       = aws_iam_role.lambda_execution.arn
}

output "lambda_execution_role_name" {
  description = "Name of the Lambda execution IAM role"
  value       = aws_iam_role.lambda_execution.name
}

# Project Information
output "project_name" {
  description = "Project name"
  value       = var.project_name
}

output "environment" {
  description = "Environment name"
  value       = var.environment
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

# S3 Trigger Information
output "s3_trigger_info" {
  description = "Information about S3 triggers for Lambda functions"
  value = {
    ingestion = {
      bucket_name     = aws_s3_bucket.data_lake["landing"].id
      lambda_function = aws_lambda_function.ingestion.function_name
      lambda_arn      = aws_lambda_function.ingestion.arn
      events          = ["s3:ObjectCreated:*"]
      filter_suffixes = [".csv", ".json"]
      description     = "Ingestion Lambda is triggered automatically when CSV/JSON files are uploaded to the landing bucket"
    }
    cleansing = {
      bucket_name     = aws_s3_bucket.data_lake["bronze"].id
      lambda_function = aws_lambda_function.cleansing.function_name
      lambda_arn      = aws_lambda_function.cleansing.arn
      events          = ["s3:ObjectCreated:*"]
      filter_suffix   = ".parquet"
      description     = "Cleansing Lambda is triggered automatically when Parquet files are created in the Bronze bucket"
    }
  }
}

# Complete Pipeline Summary
output "pipeline_summary" {
  description = "Summary of the complete data pipeline"
  value = {
    landing_bucket = aws_s3_bucket.data_lake["landing"].id
    bronze_bucket  = aws_s3_bucket.data_lake["bronze"].id
    silver_bucket  = aws_s3_bucket.data_lake["silver"].id
    gold_bucket    = aws_s3_bucket.data_lake["gold"].id
    ingestion_lambda = {
      name        = aws_lambda_function.ingestion.function_name
      handler     = var.ingestion_lambda_config.handler
      runtime     = var.ingestion_lambda_config.runtime
      memory      = var.ingestion_lambda_config.memory_size
      timeout     = var.ingestion_lambda_config.timeout
      has_layer   = true
      layer_name  = aws_lambda_layer_version.pandas_pyarrow.layer_name
      trigger     = "S3 Event (*.csv, *.json)"
      description = "Converts CSV/JSON to Parquet with nested structures (Landing → Bronze)"
    }
    cleansing_lambda = {
      name        = aws_lambda_function.cleansing.function_name
      handler     = var.cleansing_lambda_config.handler
      runtime     = var.cleansing_lambda_config.runtime
      memory      = var.cleansing_lambda_config.memory_size
      timeout     = var.cleansing_lambda_config.timeout
      has_layer   = true
      layer_name  = aws_lambda_layer_version.pandas_pyarrow.layer_name
      trigger     = "S3 Event (*.parquet)"
      description = "Flattens nested structures, cleanses, enriches data (Bronze → Silver)"
    }
    generic_lambdas = {
      for k, v in aws_lambda_function.etl : k => {
        name        = v.function_name
        description = v.description
      }
    }
  }
}

# ============================================================================
# AWS Glue Outputs
# ============================================================================

output "glue_catalog_database_name" {
  description = "Name of the Glue Catalog database"
  value       = aws_glue_catalog_database.data_lake_database.name
}

output "glue_catalog_database_arn" {
  description = "ARN of the Glue Catalog database"
  value       = aws_glue_catalog_database.data_lake_database.arn
}

output "glue_crawler_names" {
  description = "Map of Glue Crawler names by layer"
  value = {
    bronze_car_data = aws_glue_crawler.bronze_car_data_crawler.name
    silver          = aws_glue_crawler.silver_crawler.name
    gold            = aws_glue_crawler.gold_crawler.name
  }
}

output "glue_crawler_arns" {
  description = "Map of Glue Crawler ARNs by layer"
  value = {
    bronze_car_data = aws_glue_crawler.bronze_car_data_crawler.arn
    silver          = aws_glue_crawler.silver_crawler.arn
    gold            = aws_glue_crawler.gold_crawler.arn
  }
}

output "glue_crawler_schedule" {
  description = "Crawler schedule configuration"
  value       = var.glue_crawler_schedule != "" ? var.glue_crawler_schedule : "Manual execution only (no schedule)"
}

output "glue_crawler_role_arn" {
  description = "ARN of the IAM role used by Glue Crawlers"
  value       = aws_iam_role.glue_crawler_role.arn
}

# ============================================================================
# Amazon Athena Outputs
# ============================================================================

output "athena_workgroup_name" {
  description = "Name of the Athena workgroup"
  value       = aws_athena_workgroup.data_lake.name
}

output "athena_workgroup_arn" {
  description = "ARN of the Athena workgroup"
  value       = aws_athena_workgroup.data_lake.arn
}

output "athena_results_bucket" {
  description = "S3 bucket for Athena query results"
  value       = aws_s3_bucket.athena_results.id
}

output "athena_results_bucket_arn" {
  description = "ARN of the Athena results bucket"
  value       = aws_s3_bucket.athena_results.arn
}

output "athena_execution_role_arn" {
  description = "ARN of the IAM role for Athena query execution"
  value       = aws_iam_role.athena_execution_role.arn
}

output "athena_query_results_path" {
  description = "S3 path for Athena query results"
  value       = "s3://${aws_s3_bucket.athena_results.id}/query-results/"
}

# ============================================================================
# Lakehouse Stack Summary
# ============================================================================

output "lakehouse_summary" {
  description = "Complete summary of the Lakehouse infrastructure"
  value = {
    glue = {
      database_name = aws_glue_catalog_database.data_lake_database.name
      database_arn  = aws_glue_catalog_database.data_lake_database.arn
      schedule      = var.glue_crawler_schedule != "" ? var.glue_crawler_schedule : "Manual execution only"
      crawlers = {
        bronze_car_data = {
          name   = aws_glue_crawler.bronze_car_data_crawler.name
          path   = "s3://${aws_s3_bucket.data_lake["bronze"].id}/bronze/car_data/"
          status = var.bronze_crawler_schedule != "" ? "Scheduled (Daily at 00:00 UTC)" : "Ready (Manual execution required)"
          table_prefix = "bronze_"
          features = "Preserves nested structures (structs) from JSON"
        }
        silver = {
          name   = aws_glue_crawler.silver_crawler.name
          path   = "s3://${aws_s3_bucket.data_lake["silver"].id}/car_telemetry/"
          status = var.silver_crawler_schedule != "" ? "Scheduled (Daily at 01:00 UTC)" : "Ready (Manual execution required)"
          table_prefix = "silver_"
          features = "Flattened data with event-based partitions (event_year/month/day)"
        }
        gold = {
          name   = aws_glue_crawler.gold_crawler.name
          path   = "s3://${aws_s3_bucket.data_lake["gold"].id}/gold/"
          status = var.glue_crawler_schedule != "" ? "Scheduled (Daily at 00:00 UTC)" : "Ready (Manual execution required)"
        }
      }
    }
    athena = {
      workgroup_name     = aws_athena_workgroup.data_lake.name
      results_bucket     = aws_s3_bucket.athena_results.id
      query_results_path = "s3://${aws_s3_bucket.athena_results.id}/query-results/"
      console_url        = "https://${var.aws_region}.console.aws.amazon.com/athena/home?region=${var.aws_region}#/query-editor"
    }
    data_catalog = {
      database      = aws_glue_catalog_database.data_lake_database.name
      glue_console  = "https://${var.aws_region}.console.aws.amazon.com/glue/home?region=${var.aws_region}#/v2/data-catalog/databases/${aws_glue_catalog_database.data_lake_database.name}"
      tables_status = "Empty - Run crawlers to populate"
    }
    next_steps = {
      step_1 = "Upload JSON file to Landing bucket to trigger Bronze ingestion"
      step_2 = "Bronze Lambda preserves nested structures and saves as Parquet"
      step_3 = "Cleansing Lambda automatically flattens structs and creates Silver layer"
      step_4 = "Run crawlers to catalog data: '${aws_glue_crawler.bronze_car_data_crawler.name}' and '${aws_glue_crawler.silver_crawler.name}'"
      step_5 = "Query Bronze with nested fields: SELECT metrics.engineTempCelsius FROM bronze_*"
      step_6 = "Query Silver with flat fields: SELECT metrics_engineTempCelsius FROM silver_car_telemetry"
      step_7 = "Analyze enriched metrics (fuel_level_percentage, km_per_liter) in Athena"
    }
  }
}

