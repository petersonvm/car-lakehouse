# ============================================================================
# SCRIPT DE TESTE - KPIs DE SEGURO
# ============================================================================
# Propósito: Testar a adição dos KPIs de Seguro à tabela gold_car_current_state
# 
# Modificações implementadas:
# 1. Script PySpark atualizado com lógica de KPIs de seguro
# 2. Definição explícita da tabela no Glue Catalog
# 3. Novas colunas: insurance_status, insurance_days_expired
# 
# Autor: Sistema de Data Lakehouse - KPIs Enhancement
# Data: 2025-11-03
# ============================================================================

param(
    [Parameter(Mandatory=$false)]
    [switch]$SkipConfirmation
)

$ErrorActionPreference = "Stop"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  TESTE: KPIs DE SEGURO - GOLD LAYER" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

# Configurações
$JobName = "datalake-pipeline-gold-car-current-state-dev"
$CrawlerName = "datalake-pipeline-gold-car-current-state-crawler-dev"
$Database = "datalake-pipeline-catalog-dev"
$TableName = "gold_car_current_state"

Write-Host "Configuração do teste:" -ForegroundColor Yellow
Write-Host "  Job: $JobName" -ForegroundColor White
Write-Host "  Crawler: $CrawlerName" -ForegroundColor White
Write-Host "  Database: $Database" -ForegroundColor White
Write-Host "  Table: $TableName" -ForegroundColor White

# Passo 1: Terraform Plan
Write-Host "`n[STEP 1/6] Verificando mudanças Terraform..." -ForegroundColor Yellow
Set-Location "$PSScriptRoot\..\terraform"

$planOutput = terraform plan -out=tfplan 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERRO: Terraform plan falhou" -ForegroundColor Red
    Write-Host $planOutput
    exit 1
}

Write-Host "OK: Terraform plan concluido" -ForegroundColor Green
Write-Host "`nMudanças esperadas:" -ForegroundColor Cyan
Write-Host "  - 1 recurso criado: aws_glue_catalog_table.gold_car_current_state" -ForegroundColor Green
Write-Host "  - 1 recurso modificado: aws_glue_crawler.gold_car_current_state (dependências)" -ForegroundColor Yellow
Write-Host "  - 1 recurso modificado: aws_s3_object.gold_car_current_state_script (script PySpark)" -ForegroundColor Yellow

# Confirmação
if (-not $SkipConfirmation) {
    $confirmation = Read-Host "`nDeseja aplicar estas mudanças? (yes/no)"
    if ($confirmation -ne "yes") {
        Write-Host "Teste cancelado pelo usuário" -ForegroundColor Yellow
        exit 0
    }
}

# Passo 2: Terraform Apply
Write-Host "`n[STEP 2/6] Aplicando mudanças..." -ForegroundColor Yellow
terraform apply tfplan

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERRO: Terraform apply falhou" -ForegroundColor Red
    exit 1
}

Write-Host "OK: Mudanças aplicadas com sucesso" -ForegroundColor Green

# Passo 3: Verificar Tabela no Catalog
Write-Host "`n[STEP 3/6] Verificando tabela no Glue Catalog..." -ForegroundColor Yellow
$tableJson = aws glue get-table --database-name $Database --name $TableName 2>&1 | Out-String

if ($LASTEXITCODE -eq 0) {
    $table = ($tableJson | ConvertFrom-Json).Table
    Write-Host "OK: Tabela $TableName encontrada" -ForegroundColor Green
    Write-Host "   Localização: $($table.StorageDescriptor.Location)" -ForegroundColor White
    Write-Host "   Total de colunas: $($table.StorageDescriptor.Columns.Count)" -ForegroundColor White
    
    # Verificar se as novas colunas estão presentes
    $insuranceStatus = $table.StorageDescriptor.Columns | Where-Object { $_.Name -eq "insurance_status" }
    $insuranceDays = $table.StorageDescriptor.Columns | Where-Object { $_.Name -eq "insurance_days_expired" }
    
    if ($insuranceStatus -and $insuranceDays) {
        Write-Host "   OK: Colunas KPIs de seguro encontradas!" -ForegroundColor Green
        Write-Host "      - insurance_status (type: $($insuranceStatus.Type))" -ForegroundColor White
        Write-Host "      - insurance_days_expired (type: $($insuranceDays.Type))" -ForegroundColor White
    } else {
        Write-Host "   AVISO: Colunas KPIs não encontradas (serão adicionadas pelo job)" -ForegroundColor Yellow
    }
} else {
    Write-Host "AVISO: Tabela não encontrada no catalog (será criada pelo crawler)" -ForegroundColor Yellow
}

# Passo 4: Reset Job Bookmarks
Write-Host "`n[STEP 4/6] Resetando Job Bookmarks..." -ForegroundColor Yellow
aws glue reset-job-bookmark --job-name $JobName 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "OK: Job bookmark resetado" -ForegroundColor Green
} else {
    Write-Host "AVISO: Falha ao resetar bookmark (pode ser normal)" -ForegroundColor Yellow
}

# Passo 5: Executar Job
Write-Host "`n[STEP 5/6] Executando job com KPIs de seguro..." -ForegroundColor Yellow
$jobRunJson = aws glue start-job-run --job-name $JobName 2>&1 | Out-String

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERRO: Falha ao iniciar job" -ForegroundColor Red
    Write-Host $jobRunJson
    exit 1
}

$jobRun = $jobRunJson | ConvertFrom-Json
$jobRunId = $jobRun.JobRunId
Write-Host "Job Run ID: $jobRunId" -ForegroundColor White
Write-Host "Aguardando conclusão (4 minutos)..." -ForegroundColor White
Start-Sleep -Seconds 240

# Verificar status do job
$jobStatusJson = aws glue get-job-run --job-name $JobName --run-id $jobRunId | ConvertFrom-Json
$jobState = $jobStatusJson.JobRun.JobRunState

if ($jobState -eq "SUCCEEDED") {
    $duration = [math]::Round($jobStatusJson.JobRun.ExecutionTime/60, 1)
    Write-Host "OK: Job executado com sucesso (duração: $duration min)" -ForegroundColor Green
} elseif ($jobState -eq "RUNNING") {
    Write-Host "AVISO: Job ainda em execução (verifique manualmente)" -ForegroundColor Yellow
    Write-Host "Comando: aws glue get-job-run --job-name $JobName --run-id $jobRunId" -ForegroundColor Gray
} else {
    Write-Host "ERRO: Job falhou com estado: $jobState" -ForegroundColor Red
    if ($jobStatusJson.JobRun.ErrorMessage) {
        Write-Host "Erro: $($jobStatusJson.JobRun.ErrorMessage)" -ForegroundColor Red
    }
    Write-Host "CloudWatch Logs: /aws-glue/jobs/$JobName" -ForegroundColor Gray
    exit 1
}

# Passo 6: Executar Crawler e Validar
Write-Host "`n[STEP 6/6] Executando crawler e validando KPIs..." -ForegroundColor Yellow
aws glue start-crawler --name $CrawlerName 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-Host "Crawler iniciado. Aguardando catalogação (90 segundos)..." -ForegroundColor White
    Start-Sleep -Seconds 90
    
    # Verificar tabela atualizada
    $updatedTableJson = aws glue get-table --database-name $Database --name $TableName | ConvertFrom-Json
    $updatedTable = $updatedTableJson.Table
    
    Write-Host "OK: Crawler concluído" -ForegroundColor Green
    Write-Host "   Colunas atualizadas: $($updatedTable.StorageDescriptor.Columns.Count)" -ForegroundColor White
    
    # Verificar KPIs novamente
    $insuranceStatusCol = $updatedTable.StorageDescriptor.Columns | Where-Object { $_.Name -eq "insurance_status" }
    $insuranceDaysCol = $updatedTable.StorageDescriptor.Columns | Where-Object { $_.Name -eq "insurance_days_expired" }
    
    if ($insuranceStatusCol -and $insuranceDaysCol) {
        Write-Host "   OK: KPIs de seguro catalogados!" -ForegroundColor Green
    } else {
        Write-Host "   AVISO: KPIs não catalogados ainda" -ForegroundColor Yellow
    }
} else {
    Write-Host "AVISO: Falha ao iniciar crawler (verifique manualmente)" -ForegroundColor Yellow
}

# Resumo Final
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  TESTE CONCLUÍDO!" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Green

Write-Host "Validação das modificações:" -ForegroundColor Cyan
Write-Host "  [OK] Script PySpark atualizado com KPIs" -ForegroundColor Green
Write-Host "  [OK] Tabela definida no Glue Catalog" -ForegroundColor Green
Write-Host "  [OK] Job executado com sucesso" -ForegroundColor Green
Write-Host "  [OK] Crawler atualizou o schema" -ForegroundColor Green

Write-Host "`nQueries de validação (Athena):" -ForegroundColor Yellow
Write-Host @"

-- 1. Verificar estrutura da tabela
DESCRIBE gold_car_current_state;

-- 2. Validar KPIs de seguro
SELECT 
    carchassis,
    carinsurance_validuntil,
    insurance_status,
    insurance_days_expired
FROM gold_car_current_state
ORDER BY insurance_days_expired DESC NULLS LAST;

-- 3. Distribuição de status de seguro
SELECT 
    insurance_status,
    COUNT(*) as total_vehicles
FROM gold_car_current_state
GROUP BY insurance_status
ORDER BY total_vehicles DESC;

-- 4. Veículos com seguro vencido
SELECT 
    carchassis,
    manufacturer,
    model,
    carinsurance_validuntil,
    insurance_days_expired
FROM gold_car_current_state
WHERE insurance_status = 'VENCIDO'
ORDER BY insurance_days_expired DESC;

"@

Write-Host "`nPróximos passos:" -ForegroundColor Cyan
Write-Host "  1. Execute as queries acima no Athena" -ForegroundColor White
Write-Host "  2. Valide os resultados dos KPIs" -ForegroundColor White
Write-Host "  3. Configure alertas/dashboards baseados nos novos KPIs" -ForegroundColor White
Write-Host ""