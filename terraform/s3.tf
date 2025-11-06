# S3 Buckets for Data Lake (Medallion Architecture)
resource "aws_s3_bucket" "data_lake" {
  for_each = var.s3_buckets

  bucket = "${var.project_name}-${each.value.name_suffix}-${var.environment}"

  tags = {
    Name  = "${var.project_name}-${each.value.name_suffix}-${var.environment}"
    Layer = each.key
  }
}

# Enable versioning for S3 buckets
resource "aws_s3_bucket_versioning" "data_lake" {
  for_each = var.s3_buckets

  bucket = aws_s3_bucket.data_lake[each.key].id

  versioning_configuration {
    status = each.value.versioning ? "Enabled" : "Disabled"
  }
}

# Enable server-side encryption for S3 buckets
resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  for_each = var.s3_buckets

  bucket = aws_s3_bucket.data_lake[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block public access for S3 buckets
resource "aws_s3_bucket_public_access_block" "data_lake" {
  for_each = var.s3_buckets

  bucket = aws_s3_bucket.data_lake[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle policies for S3 buckets
resource "aws_s3_bucket_lifecycle_configuration" "data_lake" {
  for_each = {
    for k, v in var.s3_buckets : k => v
    if v.lifecycle_rules.enabled
  }

  bucket = aws_s3_bucket.data_lake[each.key].id

  rule {
    id     = "transition-and-expiration"
    status = "Enabled"
    
    filter {
      prefix = ""
    }

    transition {
      days          = each.value.lifecycle_rules.transition_to_glacier_days
      storage_class = "GLACIER"
    }

    transition {
      days          = each.value.lifecycle_rules.transition_to_deep_archive_days
      storage_class = "DEEP_ARCHIVE"
    }

    expiration {
      days = each.value.lifecycle_rules.expiration_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}
