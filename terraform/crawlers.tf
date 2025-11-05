# terraform/crawlers.tf

# ===================================================================
# Silver Layer Crawler
# ===================================================================
resource "aws_glue_crawler" "car_silver_crawler" {
  name          = "car_silver_crawler"
  database_name = aws_glue_catalog_database.data_lake_database.name
  role          = aws_iam_role.glue_crawler_role.arn

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake["silver"].bucket}/car_silver/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
  })
}

# ===================================================================
# Gold Layer Crawlers
# ===================================================================
resource "aws_glue_crawler" "gold_car_current_state_crawler" {
  name          = "gold_car_current_state_crawler"
  database_name = aws_glue_catalog_database.data_lake_database.name
  role          = aws_iam_role.glue_crawler_role.arn

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake["gold"].bucket}/gold_car_current_state_new/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }
}

resource "aws_glue_crawler" "gold_fuel_efficiency_crawler" {
  name          = "gold_fuel_efficiency_crawler"
  database_name = aws_glue_catalog_database.data_lake_database.name
  role          = aws_iam_role.glue_crawler_role.arn

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake["gold"].bucket}/gold_fuel_efficiency/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }
}

resource "aws_glue_crawler" "gold_alerts_slim_crawler" {
  name          = "gold_alerts_slim_crawler"
  database_name = aws_glue_catalog_database.data_lake_database.name
  role          = aws_iam_role.glue_crawler_role.arn

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake["gold"].bucket}/gold_performance_alerts_slim/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }
}
