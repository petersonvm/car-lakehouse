# terraform/workflow.tf

# ===================================================================
# Workflow Principal
# ===================================================================
resource "aws_glue_workflow" "silver_gold_pipeline" {
  name = "datalake-pipeline-silver-gold-workflow-dev"
  description = "Workflow to orchestrate the Silver to Gold ETL pipeline."
}

# ===================================================================
# Gatilho 1: Início do Workflow (Agendado)
# Aciona o job de consolidação Silver.
# ===================================================================
resource "aws_glue_trigger" "trigger_start_silver_job" {
  name          = "trigger-start-silver-job"
  workflow_name = aws_glue_workflow.silver_gold_pipeline.name
  type          = "SCHEDULED"
  schedule      = "cron(0 2 * * ? *)" # Todo dia às 02:00 UTC

  actions {
    job_name = "datalake-pipeline-silver-consolidation-dev"
  }
}

# ===================================================================
# Gatilho 2: Do Job Silver para o Crawler Silver
# Aciona o crawler da tabela car_silver após o sucesso do job.
# ===================================================================
resource "aws_glue_trigger" "trigger_silver_job_to_crawler" {
  name          = "trigger-silver-job-to-crawler"
  workflow_name = aws_glue_workflow.silver_gold_pipeline.name
  type          = "CONDITIONAL"

  predicate {
    conditions {
      job_name = "datalake-pipeline-silver-consolidation-dev"
      state    = "SUCCEEDED"
    }
  }

  actions {
    crawler_name = aws_glue_crawler.car_silver_crawler.name
  }
}

# ===================================================================
# Gatilho 3: Do Crawler Silver para os Jobs Gold (Fan-Out)
# Aciona os 3 jobs Gold em paralelo após o sucesso do crawler Silver.
# ===================================================================
resource "aws_glue_trigger" "trigger_silver_crawler_to_gold_jobs" {
  name          = "trigger-silver-crawler-to-gold-jobs"
  workflow_name = aws_glue_workflow.silver_gold_pipeline.name
  type          = "CONDITIONAL"

  predicate {
    conditions {
      crawler_name = aws_glue_crawler.car_silver_crawler.name
      state        = "SUCCEEDED"
    }
  }

  # Ações em paralelo (Fan-Out)
  actions {
    job_name = "datalake-pipeline-gold-car-current-state-dev"
  }
  actions {
    job_name = "datalake-pipeline-gold-fuel-efficiency-dev"
  }
  actions {
    job_name = "datalake-pipeline-gold-performance-alerts-slim-dev"
  }
}

# ===================================================================
# Gatilhos 4, 5, 6: Dos Jobs Gold para seus respectivos Crawlers
# ===================================================================

# Gatilho 4: Job Current State -> Crawler Current State
resource "aws_glue_trigger" "trigger_gold_current_state_to_crawler" {
  name          = "trigger-gold-current-state-to-crawler"
  workflow_name = aws_glue_workflow.silver_gold_pipeline.name
  type          = "CONDITIONAL"

  predicate {
    conditions {
      job_name = "datalake-pipeline-gold-car-current-state-dev"
      state    = "SUCCEEDED"
    }
  }

  actions {
    crawler_name = aws_glue_crawler.gold_car_current_state_crawler.name
  }
}

# Gatilho 5: Job Fuel Efficiency -> Crawler Fuel Efficiency
resource "aws_glue_trigger" "trigger_gold_fuel_efficiency_to_crawler" {
  name          = "trigger-gold-fuel-efficiency-to-crawler"
  workflow_name = aws_glue_workflow.silver_gold_pipeline.name
  type          = "CONDITIONAL"

  predicate {
    conditions {
      job_name = "datalake-pipeline-gold-fuel-efficiency-dev"
      state    = "SUCCEEDED"
    }
  }

  actions {
    crawler_name = aws_glue_crawler.gold_fuel_efficiency_crawler.name
  }
}

# Gatilho 6: Job Alerts Slim -> Crawler Alerts Slim
resource "aws_glue_trigger" "trigger_gold_alerts_to_crawler" {
  name          = "trigger-gold-alerts-to-crawler"
  workflow_name = aws_glue_workflow.silver_gold_pipeline.name
  type          = "CONDITIONAL"

  predicate {
    conditions {
      job_name = "datalake-pipeline-gold-performance-alerts-slim-dev"
      state    = "SUCCEEDED"
    }
  }

  actions {
    crawler_name = aws_glue_crawler.gold_alerts_slim_crawler.name
  }
}
