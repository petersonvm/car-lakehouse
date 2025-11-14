# ============================================================================
# Apache Iceberg Migration - Catalog Tables and Job Configurations
# ============================================================================
# Purpose: Migrate Silver and Gold tables to Apache Iceberg format
# Benefits:
#   - Eliminates 5 crawlers (Silver + 3 Gold) - saves ~9 minutes per execution
#   - Atomic catalog updates (schema evolution, partition management)
#   - ACID transactions with MERGE INTO and time travel capabilities
#   - Faster query performance with metadata optimization
# ============================================================================

# ============================================================================
# ICEBERG CATALOG TABLES
# ============================================================================

# ----------------------------------------------------------------------------
# Silver Table: silver_car_telemetry (Iceberg)
# ----------------------------------------------------------------------------
resource "aws_glue_catalog_table" "silver_car_telemetry_iceberg" {
  name          = "silver_car_telemetry"
  database_name = aws_glue_catalog_database.data_lake_database.name
  description   = "Silver layer - Cleaned and standardized vehicle telemetry data (Iceberg format)"
  
  table_type = "EXTERNAL_TABLE"
  
  parameters = {
    "table_type"                      = "ICEBERG"
    "write.format.default"            = "parquet"
    "write.parquet.compression-codec" = "snappy"
  }
  
  storage_descriptor {
    location      = "s3://${aws_s3_bucket.data_lake["silver"].bucket}/car_telemetry/"
    input_format  = "org.apache.hadoop.mapred.FileInputFormat"
    output_format = "org.apache.hadoop.mapred.FileOutputFormat"
    
    ser_de_info {
      name                  = "IcebergSerDe"
      serialization_library = "org.apache.iceberg.mr.hive.HiveIcebergSerDe"
    }
    
    columns {
      name = "event_id"
      type = "string"
      comment = "Unique event identifier"
    }
    
    columns {
      name = "car_chassis"
      type = "string"
      comment = "Vehicle chassis number (business key)"
    }
    
    columns {
      name = "event_primary_timestamp"
      type = "string"
      comment = "Primary event timestamp"
    }
    
    columns {
      name = "telemetry_timestamp"
      type = "timestamp"
      comment = "Telemetry reading timestamp"
    }
    
    columns {
      name = "current_mileage_km"
      type = "double"
      comment = "Current odometer reading in kilometers"
    }
    
    columns {
      name = "fuel_available_liters"
      type = "double"
      comment = "Current fuel level in liters"
    }
    
    columns {
      name = "manufacturer"
      type = "string"
      comment = "Vehicle manufacturer"
    }
    
    columns {
      name = "model"
      type = "string"
      comment = "Vehicle model"
    }
    
    columns {
      name = "year"
      type = "int"
      comment = "Manufacturing year"
    }
    
    columns {
      name = "gas_type"
      type = "string"
      comment = "Fuel type (gasoline, diesel, electric, hybrid)"
    }
    
    columns {
      name = "insurance_provider"
      type = "string"
      comment = "Insurance company name"
    }
    
    columns {
      name = "insurance_valid_until"
      type = "string"
      comment = "Insurance expiration date (YYYY-MM-DD)"
    }
    
    columns {
      name = "event_year"
      type = "int"
      comment = "Event year (partition key)"
    }
    
    columns {
      name = "event_month"
      type = "int"
      comment = "Event month (partition key)"
    }
    
    columns {
      name = "event_day"
      type = "int"
      comment = "Event day (partition key)"
    }
  }
  
  partition_keys {
    name = "event_year"
    type = "int"
  }
  
  partition_keys {
    name = "event_month"
    type = "int"
  }
  
  partition_keys {
    name = "event_day"
    type = "int"
  }
}

# ----------------------------------------------------------------------------
# Gold Table 1: gold_car_current_state_new (Iceberg)
# ----------------------------------------------------------------------------
resource "aws_glue_catalog_table" "gold_car_current_state_iceberg" {
  name          = "gold_car_current_state_new"
  database_name = aws_glue_catalog_database.data_lake_database.name
  description   = "Gold layer - Current vehicle state with insurance KPIs (Iceberg format, 1 row per car_chassis)"
  
  table_type = "EXTERNAL_TABLE"
  
  parameters = {
    "table_type"                      = "ICEBERG"
    "write.format.default"            = "parquet"
    "write.parquet.compression-codec" = "snappy"
    "write.merge.mode"                = "merge-on-read"
  }
  
  storage_descriptor {
    location      = "s3://${aws_s3_bucket.data_lake["gold"].bucket}/gold_car_current_state_new/"
    input_format  = "org.apache.hadoop.mapred.FileInputFormat"
    output_format = "org.apache.hadoop.mapred.FileOutputFormat"
    
    ser_de_info {
      name                  = "IcebergSerDe"
      serialization_library = "org.apache.iceberg.mr.hive.HiveIcebergSerDe"
    }
    
    columns {
      name = "car_chassis"
      type = "string"
      comment = "Vehicle chassis number (primary key)"
    }
    
    columns {
      name = "manufacturer"
      type = "string"
      comment = "Vehicle manufacturer"
    }
    
    columns {
      name = "model"
      type = "string"
      comment = "Vehicle model"
    }
    
    columns {
      name = "year"
      type = "int"
      comment = "Manufacturing year"
    }
    
    columns {
      name = "current_mileage_km"
      type = "double"
      comment = "Most recent mileage reading"
    }
    
    columns {
      name = "fuel_available_liters"
      type = "double"
      comment = "Most recent fuel level"
    }
    
    columns {
      name = "telemetry_timestamp"
      type = "timestamp"
      comment = "Timestamp of most recent telemetry"
    }
    
    columns {
      name = "insurance_provider"
      type = "string"
      comment = "Insurance company name"
    }
    
    columns {
      name = "insurance_valid_until"
      type = "string"
      comment = "Insurance expiration date"
    }
    
    columns {
      name = "insurance_status"
      type = "string"
      comment = "Insurance status: EXPIRED, EXPIRING_IN_90_DAYS, ACTIVE"
    }
    
    columns {
      name = "insurance_days_expired"
      type = "int"
      comment = "Days since expiration (null if active)"
    }
    
    columns {
      name = "event_timestamp"
      type = "timestamp"
      comment = "Event timestamp for merge conflict resolution"
    }
    
    columns {
      name = "gold_processing_timestamp"
      type = "timestamp"
      comment = "Timestamp when Gold processing occurred"
    }
  }
}

# ----------------------------------------------------------------------------
# Gold Table 2: fuel_efficiency_monthly (Iceberg)
# ----------------------------------------------------------------------------
resource "aws_glue_catalog_table" "gold_fuel_efficiency_iceberg" {
  name          = "fuel_efficiency_monthly"
  database_name = aws_glue_catalog_database.data_lake_database.name
  description   = "Gold layer - Monthly fuel efficiency metrics by vehicle (Iceberg format)"
  
  table_type = "EXTERNAL_TABLE"
  
  parameters = {
    "table_type"                      = "ICEBERG"
    "write.format.default"            = "parquet"
    "write.parquet.compression-codec" = "snappy"
    "write.merge.mode"                = "merge-on-read"
  }
  
  storage_descriptor {
    location      = "s3://${aws_s3_bucket.data_lake["gold"].bucket}/gold_fuel_efficiency/"
    input_format  = "org.apache.hadoop.mapred.FileInputFormat"
    output_format = "org.apache.hadoop.mapred.FileOutputFormat"
    
    ser_de_info {
      name                  = "IcebergSerDe"
      serialization_library = "org.apache.iceberg.mr.hive.HiveIcebergSerDe"
    }
    
    columns {
      name = "car_chassis"
      type = "string"
      comment = "Vehicle chassis number"
    }
    
    columns {
      name = "manufacturer"
      type = "string"
      comment = "Vehicle manufacturer"
    }
    
    columns {
      name = "model"
      type = "string"
      comment = "Vehicle model"
    }
    
    columns {
      name = "year_month"
      type = "string"
      comment = "Month in YYYY-MM format"
    }
    
    columns {
      name = "total_km_driven"
      type = "double"
      comment = "Total kilometers driven in month"
    }
    
    columns {
      name = "total_fuel_liters"
      type = "double"
      comment = "Total fuel consumed in liters"
    }
    
    columns {
      name = "avg_fuel_efficiency_kmpl"
      type = "double"
      comment = "Average fuel efficiency (km/L)"
    }
    
    columns {
      name = "trip_count"
      type = "bigint"
      comment = "Number of trips in month"
    }
    
    columns {
      name = "processing_timestamp"
      type = "timestamp"
      comment = "Timestamp when aggregation was calculated"
    }
  }
}

# ----------------------------------------------------------------------------
# Gold Table 3: performance_alerts_log_slim (Iceberg)
# ----------------------------------------------------------------------------
resource "aws_glue_catalog_table" "gold_performance_alerts_iceberg" {
  name          = "performance_alerts_log_slim"
  database_name = aws_glue_catalog_database.data_lake_database.name
  description   = "Gold layer - Performance alerts and anomaly detection log (Iceberg format, append-only)"
  
  table_type = "EXTERNAL_TABLE"
  
  parameters = {
    "table_type"                      = "ICEBERG"
    "write.format.default"            = "parquet"
    "write.parquet.compression-codec" = "snappy"
  }
  
  storage_descriptor {
    location      = "s3://${aws_s3_bucket.data_lake["gold"].bucket}/gold_performance_alerts_slim/"
    input_format  = "org.apache.hadoop.mapred.FileInputFormat"
    output_format = "org.apache.hadoop.mapred.FileOutputFormat"
    
    ser_de_info {
      name                  = "IcebergSerDe"
      serialization_library = "org.apache.iceberg.mr.hive.HiveIcebergSerDe"
    }
    
    columns {
      name = "alert_id"
      type = "string"
      comment = "Unique alert identifier (UUID)"
    }
    
    columns {
      name = "car_chassis"
      type = "string"
      comment = "Vehicle chassis number"
    }
    
    columns {
      name = "alert_type"
      type = "string"
      comment = "Alert type: LOW_FUEL, HIGH_MILEAGE, ANOMALY"
    }
    
    columns {
      name = "alert_severity"
      type = "string"
      comment = "Severity: WARNING, CRITICAL"
    }
    
    columns {
      name = "alert_message"
      type = "string"
      comment = "Human-readable alert description"
    }
    
    columns {
      name = "current_mileage_km"
      type = "double"
      comment = "Mileage at time of alert"
    }
    
    columns {
      name = "fuel_available_liters"
      type = "double"
      comment = "Fuel level at time of alert"
    }
    
    columns {
      name = "telemetry_timestamp"
      type = "timestamp"
      comment = "Telemetry timestamp when alert triggered"
    }
    
    columns {
      name = "alert_generated_timestamp"
      type = "timestamp"
      comment = "Timestamp when alert was generated"
    }
  }
  
  partition_keys {
    name = "alert_date"
    type = "date"
    comment = "Alert generation date for efficient querying"
  }
}

# ============================================================================
# ICEBERG-ENABLED GLUE JOBS CONFIGURATION
# ============================================================================

# ----------------------------------------------------------------------------
# Job 1: Silver Consolidation (Iceberg Write)
# ----------------------------------------------------------------------------
resource "aws_glue_job" "silver_consolidation_iceberg" {
  name              = "${var.project_name}-silver-consolidation-iceberg-${var.environment}"
  role_arn          = aws_iam_role.glue_job.arn
  glue_version      = "4.0"
  worker_type       = var.glue_worker_type
  number_of_workers = var.glue_number_of_workers
  timeout           = var.glue_job_timeout_minutes
  max_retries       = 1
  
  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.bucket}/glue_jobs/silver_consolidation_job_iceberg.py"
    python_version  = "3"
  }
  
  default_arguments = {
    "--job-language"                      = "python"
    "--job-bookmark-option"               = "job-bookmark-enable"
    "--enable-metrics"                    = "true"
    "--enable-spark-ui"                   = "true"
    "--enable-continuous-cloudwatch-log"  = "true"
    "--spark-event-logs-path"             = "s3://${aws_s3_bucket.glue_temp.bucket}/spark-logs/"
    "--TempDir"                           = "s3://${aws_s3_bucket.glue_temp.bucket}/temp/"
    
    # Iceberg-specific configurations
    "--enable-glue-datacatalog"           = "true"
    "--datalake-formats"                  = "iceberg"
    
    # Job parameters
    "--bronze_database"                   = aws_glue_catalog_database.data_lake_database.name
    "--bronze_table"                      = "bronze_car_data"
    "--silver_database"                   = aws_glue_catalog_database.data_lake_database.name
    "--silver_table"                      = "silver_car_telemetry"
  }
  
  execution_property {
    max_concurrent_runs = 1
  }
  
  tags = merge(
    local.common_tags,
    {
      Name        = "${var.project_name}-silver-consolidation-iceberg-${var.environment}"
      Layer       = "silver"
      Format      = "iceberg"
      Description = "Bronze to Silver ETL with Iceberg atomic writes"
    }
  )
}

# ----------------------------------------------------------------------------
# Job 2: Gold Car Current State (Iceberg MERGE INTO)
# ----------------------------------------------------------------------------
resource "aws_glue_job" "gold_car_current_state_iceberg" {
  name              = "${var.project_name}-gold-car-current-state-iceberg-${var.environment}"
  role_arn          = aws_iam_role.glue_job.arn
  glue_version      = "4.0"
  worker_type       = var.glue_worker_type
  number_of_workers = var.glue_number_of_workers
  timeout           = var.glue_job_timeout_minutes
  max_retries       = 1
  
  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.bucket}/glue_jobs/gold_car_current_state_job_iceberg.py"
    python_version  = "3"
  }
  
  default_arguments = {
    "--job-language"                      = "python"
    "--job-bookmark-option"               = "job-bookmark-disable"
    "--enable-metrics"                    = "true"
    "--enable-spark-ui"                   = "true"
    "--enable-continuous-cloudwatch-log"  = "true"
    "--spark-event-logs-path"             = "s3://${aws_s3_bucket.glue_temp.bucket}/spark-ui-logs/"
    "--TempDir"                           = "s3://${aws_s3_bucket.glue_temp.bucket}/temp/"
    
    # Iceberg-specific configurations
    "--enable-glue-datacatalog"           = "true"
    "--datalake-formats"                  = "iceberg"
    
    # Job parameters
    "--silver_database"                   = aws_glue_catalog_database.data_lake_database.name
    "--silver_table"                      = "silver_car_telemetry"
    "--gold_database"                     = aws_glue_catalog_database.data_lake_database.name
    "--gold_table"                        = "gold_car_current_state_new"
  }
  
  execution_property {
    max_concurrent_runs = 1
  }
  
  tags = merge(
    local.common_tags,
    {
      Name        = "${var.project_name}-gold-car-current-state-iceberg-${var.environment}"
      Layer       = "gold"
      Format      = "iceberg"
      Description = "Current vehicle state with MERGE INTO upsert logic"
    }
  )
}

# ----------------------------------------------------------------------------
# Job 3: Gold Fuel Efficiency (Iceberg MERGE INTO)
# ----------------------------------------------------------------------------
resource "aws_glue_job" "gold_fuel_efficiency_iceberg" {
  name              = "${var.project_name}-gold-fuel-efficiency-iceberg-${var.environment}"
  role_arn          = aws_iam_role.glue_job.arn
  glue_version      = "4.0"
  worker_type       = var.glue_worker_type
  number_of_workers = var.glue_number_of_workers
  timeout           = var.glue_job_timeout_minutes
  max_retries       = 1
  
  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.bucket}/glue_jobs/gold_fuel_efficiency_job_iceberg.py"
    python_version  = "3"
  }
  
  default_arguments = {
    "--job-language"                      = "python"
    "--job-bookmark-option"               = "job-bookmark-disable"
    "--enable-metrics"                    = "true"
    "--enable-spark-ui"                   = "true"
    "--enable-continuous-cloudwatch-log"  = "true"
    "--spark-event-logs-path"             = "s3://${aws_s3_bucket.glue_temp.bucket}/spark-ui-logs/"
    "--TempDir"                           = "s3://${aws_s3_bucket.glue_temp.bucket}/temp/"
    
    # Iceberg-specific configurations
    "--enable-glue-datacatalog"           = "true"
    "--datalake-formats"                  = "iceberg"
    
    # Job parameters
    "--silver_database"                   = aws_glue_catalog_database.data_lake_database.name
    "--silver_table"                      = "silver_car_telemetry"
    "--gold_database"                     = aws_glue_catalog_database.data_lake_database.name
    "--gold_table"                        = "fuel_efficiency_monthly"
  }
  
  execution_property {
    max_concurrent_runs = 1
  }
  
  tags = merge(
    local.common_tags,
    {
      Name        = "${var.project_name}-gold-fuel-efficiency-iceberg-${var.environment}"
      Layer       = "gold"
      Format      = "iceberg"
      Description = "Monthly fuel efficiency metrics with MERGE INTO"
    }
  )
}

# ----------------------------------------------------------------------------
# Job 4: Gold Performance Alerts (Iceberg INSERT INTO)
# ----------------------------------------------------------------------------
resource "aws_glue_job" "gold_performance_alerts_iceberg" {
  name              = "${var.project_name}-gold-performance-alerts-iceberg-${var.environment}"
  role_arn          = aws_iam_role.glue_job.arn
  glue_version      = "4.0"
  worker_type       = var.glue_worker_type
  number_of_workers = var.glue_number_of_workers
  timeout           = var.glue_job_timeout_minutes
  max_retries       = 1
  
  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.bucket}/glue_jobs/gold_performance_alerts_job_iceberg.py"
    python_version  = "3"
  }
  
  default_arguments = {
    "--job-language"                      = "python"
    "--job-bookmark-option"               = "job-bookmark-enable"
    "--enable-metrics"                    = "true"
    "--enable-spark-ui"                   = "true"
    "--enable-continuous-cloudwatch-log"  = "true"
    "--spark-event-logs-path"             = "s3://${aws_s3_bucket.glue_temp.bucket}/spark-ui-logs/"
    "--TempDir"                           = "s3://${aws_s3_bucket.glue_temp.bucket}/temp/"
    
    # Iceberg-specific configurations
    "--enable-glue-datacatalog"           = "true"
    "--datalake-formats"                  = "iceberg"
    
    # Job parameters
    "--silver_database"                   = aws_glue_catalog_database.data_lake_database.name
    "--silver_table"                      = "silver_car_telemetry"
    "--gold_database"                     = aws_glue_catalog_database.data_lake_database.name
    "--gold_table"                        = "performance_alerts_log_slim"
  }
  
  execution_property {
    max_concurrent_runs = 1
  }
  
  tags = merge(
    local.common_tags,
    {
      Name        = "${var.project_name}-gold-performance-alerts-iceberg-${var.environment}"
      Layer       = "gold"
      Format      = "iceberg"
      Description = "Performance alerts detection with INSERT INTO append"
    }
  )
}
