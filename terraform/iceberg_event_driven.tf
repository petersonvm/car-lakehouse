# ============================================================================
# Event-Driven Workflow Configuration
# ============================================================================
# Purpose: Replace scheduled triggers with event-driven architecture
# Benefits:
#   - Near real-time data processing (triggered by Bronze crawler success)
#   - Eliminates unnecessary scheduled runs when no new data exists
#   - Reduces costs by running only when data is available
#   - Simplifies workflow by removing Silver/Gold crawlers
# ============================================================================

# ============================================================================
# GLUE JOB: Silver Consolidation (Event-Driven Pipeline)
# ============================================================================

resource "aws_glue_job" "silver_consolidation_eventdriven" {
  name              = "${var.project_name}-silver-consolidation-eventdriven-${var.environment}"
  role_arn          = aws_iam_role.glue_job.arn
  glue_version      = "4.0"
  worker_type       = var.glue_worker_type
  number_of_workers = var.glue_number_of_workers
  timeout           = var.glue_job_timeout_minutes
  max_retries       = 1
  
  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.bucket}/glue_jobs/silver_consolidation_job_eventdriven.py"
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
      Name        = "${var.project_name}-silver-consolidation-eventdriven-${var.environment}"
      Layer       = "Silver"
      Format      = "Iceberg"
      Pipeline    = "EventDriven"
    }
  )
}

# ============================================================================
# EVENT-DRIVEN WORKFLOW (Without Crawlers)
# ============================================================================

resource "aws_glue_workflow" "silver_gold_pipeline_eventdriven" {
  name        = "${var.workflow_name}-eventdriven"
  description = "Event-driven workflow for Silver to Gold processing (no crawlers, Iceberg atomic updates)"
  
  default_run_properties = {
    environment = var.environment
    project     = "datalake-pipeline"
    layer       = "silver-gold"
    mode        = "event-driven"
    format      = "iceberg"
  }

  tags = merge(
    local.common_tags,
    {
      Name        = "${var.workflow_name}-eventdriven"
      Mode        = "EventDriven"
      Format      = "Iceberg"
      Version     = "3.0"
    }
  )
}

# ============================================================================
# TRIGGER 1: Silver Job Direct Start (Triggered by EventBridge)
# ============================================================================
# This trigger will be invoked by EventBridge rule when Bronze crawler succeeds
# It starts the Silver Consolidation job immediately

resource "aws_glue_trigger" "eventdriven_start_silver" {
  name          = "${var.workflow_name}-trigger-eventdriven-silver"
  description   = "Event-driven trigger - Starts Silver job (triggered by EventBridge on Bronze crawler success)"
  type          = "ON_DEMAND"
  workflow_name = aws_glue_workflow.silver_gold_pipeline_eventdriven.name
  enabled       = true

  actions {
    job_name = aws_glue_job.silver_consolidation_eventdriven.name
    timeout  = var.job_timeout_minutes
    
    notification_property {
      notify_delay_after = 5
    }
  }

  tags = {
    Name        = "${var.workflow_name}-trigger-eventdriven-silver"
    TriggerType = "ON_DEMAND"
    Stage       = "silver-start"
    Invoker     = "EventBridge"
  }
}

# ============================================================================
# TRIGGER 2: Silver Success → Gold Job 1 (Sequential Chain - Step 1)
# ============================================================================
# MODIFIED: Changed from parallel fan-out to sequential execution
# Reason: Test race condition hypothesis - parallel Gold jobs may cause
#         Glue Catalog deadlock when all try to create tables simultaneously
# Pattern: Silver SUCCESS → Start ONLY Gold Car Current State

resource "aws_glue_trigger" "eventdriven_silver_to_gold_job1" {
  name          = "${var.workflow_name}-trigger-eventdriven-gold-job1"
  description   = "Sequential Step 1 - Starts Gold Car Current State after Silver success"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.silver_gold_pipeline_eventdriven.name
  enabled       = true

  predicate {
    logical = "ANY"

    conditions {
      job_name = aws_glue_job.silver_consolidation_eventdriven.name
      state    = "SUCCEEDED"
    }
  }

  # Action: Start ONLY the first Gold job
  actions {
    job_name = aws_glue_job.gold_car_current_state_iceberg.name
    timeout  = var.job_timeout_minutes
    
    notification_property {
      notify_delay_after = 5
    }
  }

  tags = {
    Name        = "${var.workflow_name}-trigger-eventdriven-gold-job1"
    TriggerType = "CONDITIONAL"
    Stage       = "gold-sequential-step1"
    Pattern     = "sequential-chain"
    JobCount    = "1"
  }

  depends_on = [aws_glue_trigger.eventdriven_start_silver]
}

# ============================================================================
# TRIGGER 3: Gold Job 1 Success → Gold Job 2 (Sequential Chain - Step 2)
# ============================================================================
# NEW: Chain Gold Car Current State → Gold Fuel Efficiency
# This trigger ensures Job 2 only starts after Job 1 completes successfully

resource "aws_glue_trigger" "eventdriven_gold_job1_to_job2" {
  name          = "${var.workflow_name}-trigger-eventdriven-gold-job2"
  description   = "Sequential Step 2 - Starts Gold Fuel Efficiency after Gold Car Current State success"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.silver_gold_pipeline_eventdriven.name
  enabled       = true

  predicate {
    logical = "ANY"

    conditions {
      job_name = aws_glue_job.gold_car_current_state_iceberg.name
      state    = "SUCCEEDED"
    }
  }

  actions {
    job_name = aws_glue_job.gold_fuel_efficiency_iceberg.name
    timeout  = var.job_timeout_minutes
    
    notification_property {
      notify_delay_after = 5
    }
  }

  tags = {
    Name        = "${var.workflow_name}-trigger-eventdriven-gold-job2"
    TriggerType = "CONDITIONAL"
    Stage       = "gold-sequential-step2"
    Pattern     = "sequential-chain"
    JobCount    = "1"
  }

  depends_on = [aws_glue_trigger.eventdriven_silver_to_gold_job1]
}

# ============================================================================
# TRIGGER 4: Gold Job 2 Success → Gold Job 3 (Sequential Chain - Step 3)
# ============================================================================
# NEW: Chain Gold Fuel Efficiency → Gold Performance Alerts
# Final step in the sequential chain - completes all Gold layer processing

resource "aws_glue_trigger" "eventdriven_gold_job2_to_job3" {
  name          = "${var.workflow_name}-trigger-eventdriven-gold-job3"
  description   = "Sequential Step 3 - Starts Gold Performance Alerts after Gold Fuel Efficiency success"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.silver_gold_pipeline_eventdriven.name
  enabled       = true

  predicate {
    logical = "ANY"

    conditions {
      job_name = aws_glue_job.gold_fuel_efficiency_iceberg.name
      state    = "SUCCEEDED"
    }
  }

  actions {
    job_name = aws_glue_job.gold_performance_alerts_iceberg.name
    timeout  = var.job_timeout_minutes
    
    notification_property {
      notify_delay_after = 5
    }
  }

  tags = {
    Name        = "${var.workflow_name}-trigger-eventdriven-gold-job3"
    TriggerType = "CONDITIONAL"
    Stage       = "gold-sequential-step3"
    Pattern     = "sequential-chain"
    JobCount    = "1"
  }

  depends_on = [aws_glue_trigger.eventdriven_gold_job1_to_job2]
}

# ============================================================================
# EVENTBRIDGE RULE - Bronze Crawler Success → Start Workflow
# ============================================================================
# Listens for Glue Crawler State Change events
# When Bronze crawler succeeds, triggers the workflow

resource "aws_cloudwatch_event_rule" "bronze_crawler_success" {
  name        = "${var.project_name}-bronze-crawler-success-${var.environment}"
  description = "Trigger workflow when Bronze crawler successfully completes"
  
  event_pattern = jsonencode({
    source      = ["aws.glue"]
    detail-type = ["Glue Crawler State Change"]
    detail = {
      crawlerName = ["${var.project_name}-bronze-car-data-crawler-${var.environment}"]
      state       = ["SUCCEEDED"]
    }
  })
}

# EventBridge Target - Start Glue Workflow
resource "aws_cloudwatch_event_target" "start_workflow_on_bronze_success" {
  rule      = aws_cloudwatch_event_rule.bronze_crawler_success.name
  target_id = "StartGlueWorkflow"
  arn       = "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:workflow/${aws_glue_workflow.silver_gold_pipeline_eventdriven.name}"
  role_arn  = aws_iam_role.eventbridge_glue_workflow.arn
}

# ============================================================================
# IAM ROLE - EventBridge to Start Glue Workflow
# ============================================================================

resource "aws_iam_role" "eventbridge_glue_workflow" {
  name        = "${var.project_name}-eventbridge-glue-workflow-${var.environment}"
  description = "IAM role for EventBridge to start Glue Workflow"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name    = "${var.project_name}-eventbridge-glue-workflow-${var.environment}"
    Purpose = "EventBridgeIntegration"
  }
}

# IAM Policy - Allow EventBridge to start Glue Workflow
resource "aws_iam_role_policy" "eventbridge_start_workflow" {
  name = "AllowStartGlueWorkflow"
  role = aws_iam_role.eventbridge_glue_workflow.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "glue:StartWorkflowRun",
          "glue:notifyEvent"
        ]
        Resource = [
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:workflow/${aws_glue_workflow.silver_gold_pipeline_eventdriven.name}"
        ]
      }
    ]
  })
}

# ============================================================================
# IAM POLICY ATTACHMENT - Lambda Permissions for Event-Driven Pipeline
# ============================================================================
# Add permissions for Lambda to start Bronze crawler and Glue workflow

resource "aws_iam_role_policy" "lambda_start_crawler_and_workflow" {
  name = "AllowStartCrawlerAndWorkflow"
  role = aws_iam_role.lambda_execution.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "glue:StartCrawler",
          "glue:GetCrawler"
        ]
        Resource = [
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:crawler/${var.project_name}-bronze-car-data-crawler-${var.environment}"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "glue:StartWorkflowRun",
          "glue:GetWorkflowRun"
        ]
        Resource = [
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:workflow/${aws_glue_workflow.silver_gold_pipeline_eventdriven.name}"
        ]
      }
    ]
  })
}

# ============================================================================
# DATA SOURCES
# ============================================================================

data "aws_region" "current" {}

# ============================================================================
# OUTPUTS
# ============================================================================

output "eventdriven_workflow_name" {
  description = "Name of the event-driven Glue Workflow"
  value       = aws_glue_workflow.silver_gold_pipeline_eventdriven.name
}

output "eventbridge_rule_name" {
  description = "Name of the EventBridge rule for Bronze crawler success"
  value       = aws_cloudwatch_event_rule.bronze_crawler_success.name
}

output "workflow_trigger_flow" {
  description = "Event-driven workflow trigger flow"
  value = <<-EOT
    Event-Driven Pipeline Flow:
    ===========================
    1. Lambda copies file to Bronze S3
    2. Lambda starts Bronze Crawler
    3. Bronze Crawler catalogs new data
    4. EventBridge detects Crawler SUCCESS event
    5. EventBridge starts Glue Workflow
    6. Workflow runs Silver Job (Iceberg write, no crawler)
    7. Workflow fan-out: 3 Gold Jobs in parallel (Iceberg MERGE/INSERT, no crawlers)
    8. Pipeline complete (~3 minutes vs ~12 minutes with crawlers)
    
    Time Savings: ~9 minutes per run (eliminated 5 crawlers)
    Mode: Real-time (event-driven vs scheduled batch)
  EOT
}

output "manual_workflow_start_command" {
  description = "Command to manually start the event-driven workflow"
  value       = "aws glue start-workflow-run --name ${aws_glue_workflow.silver_gold_pipeline_eventdriven.name}"
}
