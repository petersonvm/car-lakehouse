# Script para adicionar permissões ao usuário wsas-terraform
# Necessário para criar CloudWatch Log Groups e EventBridge Scheduler

Write-Host "Adicionando permissões CloudWatch Logs e EventBridge Scheduler..." -ForegroundColor Cyan

# Política para CloudWatch Logs
$cloudwatchPolicy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "logs:PutRetentionPolicy",
        "logs:DeleteLogGroup",
        "logs:TagLogGroup"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:/aws/lambda/*"
    }
  ]
}
"@

# Política para EventBridge Scheduler
$schedulerPolicy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "scheduler:CreateSchedule",
        "scheduler:GetSchedule",
        "scheduler:UpdateSchedule",
        "scheduler:DeleteSchedule",
        "scheduler:ListSchedules",
        "scheduler:TagResource"
      ],
      "Resource": "arn:aws:scheduler:*:*:schedule/*/*"
    }
  ]
}
"@

# Salvar políticas em arquivos temporários
$cloudwatchPolicy | Out-File -FilePath "temp_cloudwatch_policy.json" -Encoding UTF8
$schedulerPolicy | Out-File -FilePath "temp_scheduler_policy.json" -Encoding UTF8

# Criar políticas no IAM
Write-Host "`nCriando política CloudWatch Logs..." -ForegroundColor Yellow
aws iam create-policy `
  --policy-name TerraformCloudWatchLogsAccess `
  --policy-document file://temp_cloudwatch_policy.json `
  --description "Permite criar e gerenciar CloudWatch Log Groups"

Write-Host "`nCriando política EventBridge Scheduler..." -ForegroundColor Yellow
aws iam create-policy `
  --policy-name TerraformEventBridgeSchedulerAccess `
  --policy-document file://temp_scheduler_policy.json `
  --description "Permite criar e gerenciar EventBridge Schedulers"

# Obter Account ID
$accountId = (aws sts get-caller-identity --query 'Account' --output text)

# Anexar políticas ao usuário wsas-terraform
Write-Host "`nAnexando políticas ao usuário wsas-terraform..." -ForegroundColor Yellow
aws iam attach-user-policy `
  --user-name wsas-terraform `
  --policy-arn "arn:aws:iam::${accountId}:policy/TerraformCloudWatchLogsAccess"

aws iam attach-user-policy `
  --user-name wsas-terraform `
  --policy-arn "arn:aws:iam::${accountId}:policy/TerraformEventBridgeSchedulerAccess"

# Limpar arquivos temporários
Remove-Item temp_cloudwatch_policy.json -ErrorAction SilentlyContinue
Remove-Item temp_scheduler_policy.json -ErrorAction SilentlyContinue

Write-Host "`n Permissões adicionadas com sucesso!" -ForegroundColor Green
Write-Host "`nAgora execute: terraform apply -auto-approve" -ForegroundColor Cyan
