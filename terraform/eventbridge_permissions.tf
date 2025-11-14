# ============================================================================
# EventBridge Permissions for Terraform User
# ============================================================================
# This policy grants necessary EventBridge permissions to create and manage
# EventBridge rules for the event-driven Iceberg pipeline.
#
# To apply these permissions to the wsas-terraform user, run:
# aws iam attach-user-policy \
#   --user-name wsas-terraform \
#   --policy-arn $(terraform output -raw eventbridge_policy_arn)
# ============================================================================

resource "aws_iam_policy" "terraform_eventbridge_permissions" {
  name        = "${var.project_name}-terraform-eventbridge-policy-${var.environment}"
  description = "EventBridge permissions for Terraform user to manage event-driven pipeline"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EventBridgeRuleManagement"
        Effect = "Allow"
        Action = [
          "events:PutRule",
          "events:DeleteRule",
          "events:DescribeRule",
          "events:EnableRule",
          "events:DisableRule",
          "events:ListRules",
          "events:ListTargetsByRule"
        ]
        Resource = [
          "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:rule/${var.project_name}-*"
        ]
      },
      {
        Sid    = "EventBridgeTargetManagement"
        Effect = "Allow"
        Action = [
          "events:PutTargets",
          "events:RemoveTargets"
        ]
        Resource = [
          "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:rule/${var.project_name}-*"
        ]
      },
      {
        Sid    = "EventBridgeTagManagement"
        Effect = "Allow"
        Action = [
          "events:TagResource",
          "events:UntagResource",
          "events:ListTagsForResource"
        ]
        Resource = [
          "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:rule/${var.project_name}-*"
        ]
      },
      {
        Sid    = "IAMPassRoleForEventBridge"
        Effect = "Allow"
        Action = [
          "iam:PassRole"
        ]
        Resource = [
          aws_iam_role.eventbridge_glue_workflow.arn
        ]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "events.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-terraform-eventbridge-policy-${var.environment}"
    Purpose     = "TerraformPermissions"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ============================================================================
# OUTPUTS
# ============================================================================

output "eventbridge_policy_arn" {
  description = "ARN of the EventBridge policy for Terraform user"
  value       = aws_iam_policy.terraform_eventbridge_permissions.arn
}

output "eventbridge_policy_attachment_command" {
  description = "Command to attach EventBridge policy to wsas-terraform user"
  value       = "aws iam attach-user-policy --user-name wsas-terraform --policy-arn ${aws_iam_policy.terraform_eventbridge_permissions.arn}"
}

output "eventbridge_permissions_summary" {
  description = "Summary of EventBridge permissions granted"
  value = {
    policy_name = aws_iam_policy.terraform_eventbridge_permissions.name
    policy_arn  = aws_iam_policy.terraform_eventbridge_permissions.arn
    permissions = [
      "events:PutRule - Create EventBridge rules",
      "events:DeleteRule - Delete EventBridge rules",
      "events:DescribeRule - View rule details",
      "events:EnableRule/DisableRule - Enable/disable rules",
      "events:PutTargets/RemoveTargets - Manage rule targets",
      "events:TagResource - Add tags to rules",
      "iam:PassRole - Pass EventBridge role to Glue"
    ]
    scope = "Limited to resources with prefix: ${var.project_name}-*"
    attach_command = "aws iam attach-user-policy --user-name wsas-terraform --policy-arn ${aws_iam_policy.terraform_eventbridge_permissions.arn}"
  }
}
