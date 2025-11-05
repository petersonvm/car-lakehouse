# ============================================================================
# REFATORAÇÃO: Renomeação da Tabela Silver
# De: silver_car_telemetry_new → Para: car_silver
# ============================================================================

# 1. NOVA TABELA SILVER COM NOME PADRONIZADO
resource "aws_glue_catalog_table" "car_silver" {
  name          = "car_silver"
  database_name = var.database_name
  description   = "Tabela Silver principal - Dados processados e flattened dos veículos"

  table_type = "EXTERNAL_TABLE"

  parameters = {
    "classification"        = "parquet"
    "compressionType"       = "snappy"
    "typeOfData"           = "file"
    "has_encrypted_data"   = "false"
    "projection.enabled"   = "true"
    "projection.event_year.type"   = "integer"
    "projection.event_year.range"  = "2024,2030"
    "projection.event_month.type"  = "integer"
    "projection.event_month.range" = "1,12"
    "projection.event_month.digits" = "2"
    "projection.event_day.type"    = "integer"
    "projection.event_day.range"   = "1,31"
    "projection.event_day.digits"  = "2"
    "projection.event_year.format" = "yyyy"
    "projection.event_month.format" = "MM"
    "projection.event_day.format"  = "dd"
    "storage.location.template" = "s3://${aws_s3_bucket.data_lake["silver"].bucket}/car_silver/event_year=$${event_year}/event_month=$${event_month}/event_day=$${event_day}/"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.data_lake["silver"].bucket}/car_silver/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      name                  = "ParquetHiveSerDe"
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    # Schema atualizado para refletir os campos Silver atuais
    columns {
      name = "event_id"
      type = "string"
    }
    columns {
      name = "event_timestamp"
      type = "timestamp"
    }
    columns {
      name = "car_chassis"
      type = "string"
    }
    columns {
      name = "manufacturer"
      type = "string"
    }
    columns {
      name = "model"
      type = "string"
    }
    columns {
      name = "year"
      type = "int"
    }
    columns {
      name = "model_year"
      type = "int"
    }
    columns {
      name = "gas_type"
      type = "string"
    }
    columns {
      name = "fuel_capacity_liters"
      type = "int"
    }
    columns {
      name = "color"
      type = "string"
    }
    columns {
      name = "insurance_provider"
      type = "string"
    }
    columns {
      name = "insurance_policy_number"
      type = "string"
    }
    columns {
      name = "insurance_valid_until"
      type = "string"
    }
    columns {
      name = "last_service_date"
      type = "string"
    }
    columns {
      name = "last_service_mileage_km"
      type = "int"
    }
    columns {
      name = "oil_life_percentage"
      type = "double"
    }
    columns {
      name = "rental_agreement_id"
      type = "string"
    }
    columns {
      name = "rental_customer_id"
      type = "string"
    }
    columns {
      name = "rental_start_date"
      type = "string"
    }
    columns {
      name = "trip_start_timestamp"
      type = "string"
    }
    columns {
      name = "trip_end_timestamp"
      type = "string"
    }
    columns {
      name = "trip_mileage_km"
      type = "double"
    }
    columns {
      name = "trip_time_minutes"
      type = "int"
    }
    columns {
      name = "trip_fuel_liters"
      type = "double"
    }
    columns {
      name = "trip_max_speed_kmh"
      type = "int"
    }
    columns {
      name = "current_mileage_km"
      type = "int"
    }
    columns {
      name = "fuel_available_liters"
      type = "double"
    }
    columns {
      name = "engine_temp_celsius"
      type = "int"
    }
    columns {
      name = "oil_temp_celsius"
      type = "int"
    }
    columns {
      name = "battery_charge_percentage"
      type = "int"
    }
    columns {
      name = "tire_pressure_front_left_psi"
      type = "double"
    }
    columns {
      name = "tire_pressure_front_right_psi"
      type = "double"
    }
    columns {
      name = "tire_pressure_rear_left_psi"
      type = "double"
    }
    columns {
      name = "tire_pressure_rear_right_psi"
      type = "double"
    }
  }

  partition_keys {
    name = "event_year"
    type = "string"
  }
  partition_keys {
    name = "event_month"
    type = "string"
  }
  partition_keys {
    name = "event_day"
    type = "string"
  }
}

# 2. REMOÇÃO DA TABELA ANTIGA (OPCIONAL - EXECUTAR APÓS MIGRAÇÃO)
# Descomente após confirmar que todos os jobs estão funcionando com a nova tabela
/*
resource "null_resource" "remove_old_silver_table" {
  depends_on = [aws_glue_catalog_table.car_silver]
  
  provisioner "local-exec" {
    command = <<-EOT
      aws glue delete-table \
        --database-name ${var.database_name} \
        --name silver_car_telemetry_new \
        --region ${var.aws_region}
    EOT
  }
  
  triggers = {
    table_name = aws_glue_catalog_table.car_silver.name
  }
}
*/

# 3. ATUALIZAÇÃO DOS JOBS GLUE (PARÂMETROS)
resource "aws_glue_job" "silver_consolidation_updated" {
  name     = "${var.project_name}-silver-consolidation-${var.environment}"
  role_arn = aws_iam_role.glue_job.arn

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.bucket}/glue_jobs/silver_consolidation_job_refactored.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--job-bookmark-option"              = "job-bookmark-enable"
    "--enable-metrics"                   = "true"
    "--enable-spark-ui"                  = "true"
    "--spark-event-logs-path"           = "s3://${aws_s3_bucket.glue_temp.bucket}/sparkHistoryLogs/"
    "--enable-job-insights"             = "true"
    "--additional-python-modules"       = "pyarrow>=2.0.0"
    "--TempDir"                         = "s3://${aws_s3_bucket.glue_temp.bucket}/temp/"
    
    # PARÂMETROS ATUALIZADOS PARA NOVA ESTRUTURA
    "--bronze_bucket"                   = aws_s3_bucket.data_lake["bronze"].bucket
    "--bronze_path"                     = "bronze/car_data_new"
    "--silver_bucket"                   = aws_s3_bucket.data_lake["silver"].bucket
    "--silver_path"                     = "car_silver"  # NOVO CAMINHO
    "--database_name"                   = var.database_name
  }

  glue_version      = "4.0"
  max_retries       = 1
  timeout           = 10
  number_of_workers = 2
  worker_type       = "G.1X"

  tags = var.common_tags
}

# 4. OUTPUTS
output "silver_table_name_new" {
  description = "Nome da nova tabela Silver padronizada"
  value       = aws_glue_catalog_table.car_silver.name
}

output "silver_table_location_new" {
  description = "Localização S3 da nova tabela Silver"
  value       = aws_glue_catalog_table.car_silver.storage_descriptor[0].location
}

# 5. VARIÁVEIS NECESSÁRIAS
variable "database_name" {
  description = "Nome do database Glue"
  type        = string
  default     = "datalake-pipeline-catalog-dev"
}

# Variables moved to variables.tf to avoid duplication