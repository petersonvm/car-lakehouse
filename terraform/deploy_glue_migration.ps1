# Deploy Script - Glue Job Migration
# Aplica a migracao de Lambda para Glue Job

Write-Host "`n=====================================================================" -ForegroundColor Cyan
Write-Host "   MIGRACAO: LAMBDA -> GLUE JOB (SILVER LAYER CONSOLIDATION)" -ForegroundColor Cyan
Write-Host "=====================================================================" -ForegroundColor Cyan

Write-Host "`n[1/5] Validando pre-requisitos..." -ForegroundColor Yellow

# Verificar Terraform
if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    Write-Host "X Terraform nao encontrado!" -ForegroundColor Red
    exit 1
}
Write-Host "  OK Terraform encontrado" -ForegroundColor Green

# Verificar AWS CLI
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Host "X AWS CLI nao encontrado!" -ForegroundColor Red
    exit 1
}
Write-Host "  OK AWS CLI encontrado" -ForegroundColor Green

# Verificar credenciais AWS
$identity = aws sts get-caller-identity 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "X Credenciais AWS invalidas!" -ForegroundColor Red
    exit 1
}
Write-Host "  OK Credenciais AWS validas" -ForegroundColor Green

# Verificar script PySpark
$scriptPath = "..\glue_jobs\silver_consolidation_job.py"
if (-not (Test-Path $scriptPath)) {
    Write-Host "X Script PySpark nao encontrado: $scriptPath" -ForegroundColor Red
    exit 1
}
Write-Host "  OK Script PySpark encontrado" -ForegroundColor Green

Write-Host "`n[2/5] Criando backup do estado atual..." -ForegroundColor Yellow

$backupDir = ".\terraform-backups"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupPath = "$backupDir\terraform-state-$timestamp"

if (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}

if (Test-Path ".\terraform.tfstate") {
    Copy-Item ".\terraform.tfstate" "$backupPath.tfstate"
    Write-Host "  OK Backup criado: $backupPath.tfstate" -ForegroundColor Green
}
else {
    Write-Host "  ! Arquivo terraform.tfstate nao encontrado (primeira execucao?)" -ForegroundColor Yellow
}

Write-Host "`n[3/5] Gerando plano de execucao..." -ForegroundColor Yellow

terraform plan -detailed-exitcode | Out-Null
$planExit = $LASTEXITCODE

if ($planExit -eq 0) {
    Write-Host "  ! Nenhuma mudanca detectada" -ForegroundColor Cyan
}
elseif ($planExit -eq 2) {
    Write-Host "  OK Mudancas detectadas" -ForegroundColor Green
}
else {
    Write-Host "X Erro ao gerar plano Terraform!" -ForegroundColor Red
    exit 1
}

Write-Host "`n[4/5] Revisao do plano de execucao" -ForegroundColor Yellow
Write-Host "=====================================================================" -ForegroundColor Gray

Write-Host "`nRecursos que serao CRIADOS:" -ForegroundColor Green
Write-Host "  - aws_s3_bucket.glue_scripts" -ForegroundColor White
Write-Host "  - aws_s3_bucket.glue_temp" -ForegroundColor White
Write-Host "  - aws_s3_object.silver_consolidation_script" -ForegroundColor White
Write-Host "  - aws_iam_role.glue_job" -ForegroundColor White
Write-Host "  - aws_iam_role_policy.glue_s3_access" -ForegroundColor White
Write-Host "  - aws_iam_role_policy.glue_catalog_access" -ForegroundColor White
Write-Host "  - aws_iam_role_policy.glue_cloudwatch_logs" -ForegroundColor White
Write-Host "  - aws_glue_job.silver_consolidation" -ForegroundColor White
Write-Host "  - aws_glue_trigger.silver_consolidation_schedule" -ForegroundColor White
Write-Host "  - aws_cloudwatch_log_group.glue_job_logs" -ForegroundColor White

Write-Host "`nRecursos que serao REMOVIDOS:" -ForegroundColor Red
Write-Host "  - aws_lambda_permission.allow_s3_invoke_cleansing" -ForegroundColor White
Write-Host "  - aws_s3_bucket_notification.bronze_bucket_notification" -ForegroundColor White

Write-Host "`n=====================================================================" -ForegroundColor Gray

Write-Host "`nDeseja APLICAR essas mudancas? (S/N): " -NoNewline -ForegroundColor Yellow
$confirmation = Read-Host

if ($confirmation -ne "S" -and $confirmation -ne "s") {
    Write-Host "`nDeploy cancelado pelo usuario." -ForegroundColor Yellow
    exit 0
}

Write-Host "`n[5/5] Aplicando mudancas..." -ForegroundColor Yellow

terraform apply -auto-approve

if ($LASTEXITCODE -ne 0) {
    Write-Host "`nX Erro ao aplicar mudancas!" -ForegroundColor Red
    Write-Host "`nDeseja fazer ROLLBACK? (S/N): " -NoNewline -ForegroundColor Yellow
    $rollback = Read-Host
    
    if ($rollback -eq "S" -or $rollback -eq "s") {
        if (Test-Path "$backupPath.tfstate") {
            Copy-Item "$backupPath.tfstate" ".\terraform.tfstate" -Force
            Write-Host "OK Rollback concluido" -ForegroundColor Green
        }
        else {
            Write-Host "X Backup nao encontrado!" -ForegroundColor Red
        }
    }
    exit 1
}

Write-Host "`n=====================================================================" -ForegroundColor Green
Write-Host "              MIGRACAO CONCLUIDA COM SUCESSO!" -ForegroundColor Green
Write-Host "=====================================================================" -ForegroundColor Green

Write-Host "`n PROXIMOS PASSOS:" -ForegroundColor Yellow
Write-Host "  1. Testar execucao manual do Glue Job:" -ForegroundColor White
Write-Host "     aws glue start-job-run --job-name datalake-pipeline-silver-consolidation-dev`n" -ForegroundColor Cyan

Write-Host "  2. Monitorar logs do Glue Job:" -ForegroundColor White
Write-Host "     aws logs tail /aws-glue/jobs/datalake-pipeline-silver-consolidation-dev --follow`n" -ForegroundColor Cyan

Write-Host "  3. Upload dados de teste:" -ForegroundColor White
Write-Host "     aws s3 cp test_data/car_raw.json s3://datalake-pipeline-landing-dev/`n" -ForegroundColor Cyan

Write-Host "=====================================================================" -ForegroundColor Green
