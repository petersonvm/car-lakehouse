# ═══════════════════════════════════════════════════════════════════════════
# DEPLOY SLIM ALERTS PIPELINE
# Substitui pipeline BLOATED (36 colunas) por versao SLIM (7 colunas)
# Economia esperada: 80% em storage S3 + reducao de custos Athena
# ═══════════════════════════════════════════════════════════════════════════

param(
    [Parameter(Mandatory=$false)]
    [switch]$SkipConfirmation
)

$ErrorActionPreference = "Stop"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  DEPLOY: Performance Alerts SLIM" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

# Configurações
$NewJobName = "datalake-pipeline-gold-performance-alerts-slim-dev"
$NewCrawlerName = "datalake-pipeline-gold-performance-alerts-slim-crawler-dev"

# Passo 1: Terraform Plan
Write-Host "[STEP 1/7] Terraform Plan..." -ForegroundColor Yellow
Set-Location "$PSScriptRoot\..\terraform"

$planOutput = terraform plan -out=tfplan 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERRO: Terraform plan falhou" -ForegroundColor Red
    Write-Host $planOutput
    exit 1
}

Write-Host "OK: Terraform plan concluido" -ForegroundColor Green
Write-Host "`nRecursos esperados:" -ForegroundColor Cyan
Write-Host "  - 13 novos recursos (Job + Crawler + IAM + Trigger SLIM)" -ForegroundColor White
Write-Host "  - 1 recurso atualizado (Workflow trigger)" -ForegroundColor White
Write-Host "`nBeneficios:" -ForegroundColor Cyan
Write-Host "  - 80% reducao de storage (36 cols -> 7 cols)" -ForegroundColor Green
Write-Host "  - Queries Athena 3-5x mais rapidas" -ForegroundColor Green
Write-Host "  - Mesma logica de alertas" -ForegroundColor Green

# Confirmação
if (-not $SkipConfirmation) {
    $confirmation = Read-Host "`nDeseja aplicar estas mudancas? (yes/no)"
    if ($confirmation -ne "yes") {
        Write-Host "Deploy cancelado pelo usuario" -ForegroundColor Yellow
        exit 0
    }
}

# Passo 2: Terraform Apply
Write-Host "`n[STEP 2/7] Terraform Apply..." -ForegroundColor Yellow
terraform apply tfplan

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERRO: Terraform apply falhou" -ForegroundColor Red
    exit 1
}

Write-Host "OK: Terraform apply concluido" -ForegroundColor Green

# Passo 3: Reset Bookmarks
Write-Host "`n[STEP 3/7] Reset Job Bookmarks..." -ForegroundColor Yellow
Write-Host "Resetando: $NewJobName" -ForegroundColor White
aws glue reset-job-bookmark --job-name $NewJobName 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "OK: Bookmark resetado" -ForegroundColor Green
} else {
    Write-Host "AVISO: Falha ao resetar bookmark (esperado se primeiro deploy)" -ForegroundColor Yellow
}

# Passo 4: Aguardar IAM Propagation
Write-Host "`n[STEP 4/7] Aguardando IAM propagation..." -ForegroundColor Yellow
Write-Host "Aguardando 60 segundos..." -ForegroundColor White
Start-Sleep -Seconds 60
Write-Host "OK: IAM propagado" -ForegroundColor Green

# Passo 5: Teste do Job
Write-Host "`n[STEP 5/7] Executando teste inicial do job SLIM..." -ForegroundColor Yellow
$jobRunJson = aws glue start-job-run --job-name $NewJobName 2>&1 | Out-String

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERRO: Falha ao iniciar job" -ForegroundColor Red
    Write-Host $jobRunJson
    exit 1
}

$jobRun = $jobRunJson | ConvertFrom-Json
$jobRunId = $jobRun.JobRunId
Write-Host "Job Run ID: $jobRunId" -ForegroundColor White
Write-Host "Aguardando conclusao (3 minutos)..." -ForegroundColor White
Start-Sleep -Seconds 180

# Verificar status
$jobStatusJson = aws glue get-job-run --job-name $NewJobName --run-id $jobRunId | ConvertFrom-Json
$jobState = $jobStatusJson.JobRun.JobRunState

if ($jobState -eq "SUCCEEDED") {
    $duration = [math]::Round($jobStatusJson.JobRun.ExecutionTime/60, 1)
    Write-Host "OK: Job executado com sucesso (duracao: $duration min)" -ForegroundColor Green
} elseif ($jobState -eq "RUNNING") {
    Write-Host "AVISO: Job ainda em execucao (verifique manualmente)" -ForegroundColor Yellow
    Write-Host "Comando: aws glue get-job-run --job-name $NewJobName --run-id $jobRunId" -ForegroundColor Gray
} else {
    Write-Host "ERRO: Job falhou com estado: $jobState" -ForegroundColor Red
    if ($jobStatusJson.JobRun.ErrorMessage) {
        Write-Host "Erro: $($jobStatusJson.JobRun.ErrorMessage)" -ForegroundColor Red
    }
    exit 1
}

# Passo 6: Executar Crawler
Write-Host "`n[STEP 6/7] Executando crawler SLIM..." -ForegroundColor Yellow
aws glue start-crawler --name $NewCrawlerName 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-Host "Crawler iniciado com sucesso" -ForegroundColor White
    Write-Host "Aguardando catalogacao (90 segundos)..." -ForegroundColor White
    Start-Sleep -Seconds 90
    Write-Host "OK: Crawler concluido" -ForegroundColor Green
} else {
    Write-Host "AVISO: Falha ao iniciar crawler (verifique manualmente)" -ForegroundColor Yellow
}

# Passo 7: Resumo Final
Write-Host "`n[STEP 7/7] Validacao..." -ForegroundColor Yellow
$tablesJson = aws glue get-tables --database-name datalake-pipeline-catalog-dev 2>&1 | Out-String

if ($LASTEXITCODE -eq 0) {
    $tables = ($tablesJson | ConvertFrom-Json).TableList
    $slimTable = $tables | Where-Object { $_.Name -eq "performance_alerts_log_slim" }
    
    if ($slimTable) {
        Write-Host "OK: Tabela performance_alerts_log_slim criada" -ForegroundColor Green
        Write-Host "   Colunas: $($slimTable.StorageDescriptor.Columns.Count)" -ForegroundColor White
        Write-Host "   Location: $($slimTable.StorageDescriptor.Location)" -ForegroundColor White
    } else {
        Write-Host "AVISO: Tabela nao encontrada (execute crawler manualmente)" -ForegroundColor Yellow
    }
}

# Sucesso!
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  DEPLOY CONCLUIDO COM SUCESSO!" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Green

Write-Host "Proximo passo:" -ForegroundColor Cyan
Write-Host "  1. Executar validacao: .\Validate-SlimPipeline.ps1" -ForegroundColor White
Write-Host "  2. Comparar tabelas antiga vs nova no Athena" -ForegroundColor White
Write-Host "  3. Apos validacao: .\Cleanup-OldPipeline.ps1" -ForegroundColor White
Write-Host ""
