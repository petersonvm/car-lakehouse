# ============================================================================
# Local Values - Common configurations used across resources
# ============================================================================

locals {
  # Common tags applied to all resources
  common_tags = merge(
    var.common_tags,
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Region      = var.aws_region
    }
  )

  # Resource naming prefix
  name_prefix = "${var.project_name}-${var.environment}"

  # S3 bucket names
  bucket_names = {
    for k, v in var.s3_buckets : k => "${var.project_name}-${v.name_suffix}-${var.environment}"
  }
}
