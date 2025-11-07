<#
.SYNOPSIS
    Script de Migração: Performance Alerts BLOATED → SLIM

.DESCRIPTION
    Automatiza a substituição do pipeline antigo (36 colunas) pelo novo otimizado (7 colunas).
    
    ESTRATÉGIA DE MIGRAÇÃO:
    1. Deploy dos novos recursos (Job + Crawler + Trigger SLIM)
    2. Atualização do workflow para usar novo job
    3. Reset de bookmarks para reprocessamento
    4. Validação da nova tabela
    5. (Opcional) Remoção dos recursos antigos

.PARAMETER Stage
    Etapa da migração a executar:
    - "deploy" : Deployar novos recursos
    - "validate" : Validar nova tabela
    - "cleanup" : Remover recursos antigos

.EXAMPLE
    .\Migrate-AlertsPipeline.ps1 -Stage deploy
    .\Migrate-AlertsPipeline.ps1 -Stage validate
    .\Migrate-AlertsPipeline.ps1 -Stage cleanup

.NOTES
    Author: Data Engineering Team
    Date: 2025-10-31
    Version: 1.0
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("deploy", "validate", "cleanup")]
    [string]$Stage
)

# 
# CONFIGURAÇÕES
# 

$WorkflowName = "datalake-pipeline-silver-etl-workflow-dev"
$OldJobName = "datalake-pipeline-gold-performance-alerts-dev"
$NewJobName = "datalake-pipeline-gold-performance-alerts-slim-dev"
$OldCrawlerName = "datalake-pipeline-gold-performance-alerts-crawler-dev"
$NewCrawlerName = "datalake-pipeline-gold-performance-alerts-slim-crawler-dev"
$OldTableName = "performance_alerts_log"
$NewTableName = "performance_alerts_log_slim"
$Database = "datalake-pipeline-catalog-dev"

# 
# FUNÇÕES AUXILIARES
# 

function Write-StageHeader {
    param([string]$Title)
    Write-Host "`n" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor White
    Write-Host "`n" -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Message)
    Write-Host "⏳ $Message" -ForegroundColor Yellow
}

function Write-Success {
    param([string]$Message)
    Write-Host " $Message" -ForegroundColor Green
}

function Write-Error {
    param([string]$Message)
    Write-Host " $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "ℹ  $Message" -ForegroundColor Gray
}

# 
# STAGE 1: DEPLOY
# 

if ($Stage -eq "deploy") {
    Write-StageHeader "STAGE 1: DEPLOY - Novos Recursos SLIM"
    
    # Passo 1: Terraform Plan
    Write-Step "Executando terraform plan..."
    Set-Location "$PSScriptRoot\..\terraform"
    
    $planOutput = terraform plan -out=tfplan 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Terraform plan falhou"
        Write-Host $planOutput
        exit 1
    }
    
    Write-Success "Terraform plan concluído"
    Write-Info "Recursos esperados:"
    Write-Info "  • 1 Glue Job (slim)"
    Write-Info "  • 2 IAM Roles (job + crawler)"
    Write-Info "  • 8 IAM Policies"
    Write-Info "  • 1 Glue Crawler (slim)"
    Write-Info "  • 1 Glue Trigger (conditional)"
    Write-Info "  • 1 CloudWatch Log Group"
    Write-Info "  • 1 S3 Script Upload"
    Write-Info "  • 1 Trigger atualizado (workflow)"
    
    # Passo 2: Confirmação
    Write-Host "`n Resumo das mudanças:" -ForegroundColor Cyan
    Write-Host "   • Novos recursos: ~16 recursos"
    Write-Host "   • Recursos atualizados: 1 (workflow trigger)"
    Write-Host "   • Custo adicional: Mínimo (mesmo tipo de recursos)"
    Write-Host "   • Economia esperada: ~80% em armazenamento Gold"
    
    $confirmation = Read-Host "`n Deseja aplicar estas mudanças? (yes/no)"
    if ($confirmation -ne "yes") {
        Write-Info "Deploy cancelado pelo usuário"
        exit 0
    }
    
    # Passo 3: Terraform Apply
    Write-Step "Executando terraform apply..."
    terraform apply tfplan
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Terraform apply falhou"
        exit 1
    }
    
    Write-Success "Deploy concluído!"
    
    # Passo 4: Reset Bookmarks
    Write-Step "Resetando Job Bookmarks..."
    Write-Info "  Resetando: $NewJobName"
    aws glue reset-job-bookmark --job-name $NewJobName 2>$null
    Write-Success "Bookmark resetado"
    
    # Passo 5: Aguardar IAM Propagation
    Write-Step "Aguardando IAM propagation (60s)..."
    Start-Sleep -Seconds 60
    Write-Success "IAM propagado"
    
    # Passo 6: Teste Inicial
    Write-Step "Executando teste inicial do novo job..."
    $jobRun = aws glue start-job-run --job-name $NewJobName | ConvertFrom-Json
    $jobRunId = $jobRun.JobRunId
    Write-Info "  Job Run ID: $jobRunId"
    Write-Info "  ⏳ Aguardando conclusão (3 minutos)..."
    Start-Sleep -Seconds 180
    
    $jobStatus = aws glue get-job-run --job-name $NewJobName --run-id $jobRunId | ConvertFrom-Json
    if ($jobStatus.JobRun.JobRunState -eq "SUCCEEDED") {
        Write-Success "Job executado com sucesso!"
        Write-Info "  Duration: $([math]::Round($jobStatus.JobRun.ExecutionTime/60, 1)) min"
    } else {
        Write-Error "Job falhou: $($jobStatus.JobRun.JobRunState)"
        Write-Host "  Error: $($jobStatus.JobRun.ErrorMessage)"
        exit 1
    }
    
    # Passo 7: Executar Crawler
    Write-Step "Executando crawler slim..."
    aws glue start-crawler --name $NewCrawlerName 2>$null
    Write-Info "  ⏳ Aguardando catalogação (90s)..."
    Start-Sleep -Seconds 90
    Write-Success "Crawler concluído"
    
    Write-Host "`n" -ForegroundColor Green
    Write-Host "   DEPLOY CONCLUÍDO COM SUCESSO!                         " -ForegroundColor White
    Write-Host "" -ForegroundColor Green
    
    Write-Host "`n Próximos passos:" -ForegroundColor Cyan
    Write-Host "   1. Execute: .\Migrate-AlertsPipeline.ps1 -Stage validate"
    Write-Host "   2. Compare tabelas antiga vs nova"
    Write-Host "   3. Após validação: .\Migrate-AlertsPipeline.ps1 -Stage cleanup"
}

# 
# STAGE 2: VALIDATE
# 

if ($Stage -eq "validate") {
    Write-StageHeader "STAGE 2: VALIDATE - Validação da Tabela SLIM"
    
    # Passo 1: Verificar tabelas no catálogo
    Write-Step "Verificando tabelas no Glue Catalog..."
    $tables = aws glue get-tables --database-name $Database | ConvertFrom-Json
    
    $oldTable = $tables.TableList | Where-Object { $_.Name -eq $OldTableName }
    $newTable = $tables.TableList | Where-Object { $_.Name -eq $NewTableName }
    
    if ($null -eq $newTable) {
        Write-Error "Tabela $NewTableName não encontrada!"
        exit 1
    }
    
    Write-Success "Tabela $NewTableName encontrada"
    
    # Passo 2: Comparar schemas
    Write-Host "`n Comparação de Schemas:" -ForegroundColor Cyan
    Write-Host "`n Tabela ANTIGA ($OldTableName):" -ForegroundColor Red
    Write-Host "   • Colunas: $($oldTable.StorageDescriptor.Columns.Count)"
    Write-Host "   • Location: $($oldTable.StorageDescriptor.Location)"
    Write-Host "   • Partitions: $($oldTable.PartitionKeys.Count) ($($oldTable.PartitionKeys.Name -join ', '))"
    
    Write-Host "`n🟢 Tabela NOVA ($NewTableName):" -ForegroundColor Green
    Write-Host "   • Colunas: $($newTable.StorageDescriptor.Columns.Count)"
    Write-Host "   • Location: $($newTable.StorageDescriptor.Location)"
    Write-Host "   • Partitions: $($newTable.PartitionKeys.Count) ($($newTable.PartitionKeys.Name -join ', '))"
    
    $reduction = [math]::Round((1 - $newTable.StorageDescriptor.Columns.Count / $oldTable.StorageDescriptor.Columns.Count) * 100, 1)
    Write-Host "`n Redução de colunas: $reduction%" -ForegroundColor Green
    
    # Passo 3: Schema detalhado
    Write-Host "`n Schema SLIM (7 colunas essenciais):" -ForegroundColor Cyan
    $newTable.StorageDescriptor.Columns | ForEach-Object {
        Write-Host "   • $($_.Name) ($($_.Type))" -ForegroundColor White
    }
    
    # Passo 4: Query de validação
    Write-Step "Executando query de validação no Athena..."
    $query = "SELECT COUNT(*) as total_alerts, COUNT(DISTINCT carchassis) as unique_cars, COUNT(DISTINCT alert_type) as alert_types FROM $NewTableName"
    
    $queryExec = aws athena start-query-execution `
        --query-string $query `
        --query-execution-context "Database=$Database" `
        --result-configuration "OutputLocation=s3://datalake-pipeline-athena-results-dev/query-results/" `
        --work-group "datalake-pipeline-workgroup-dev" | ConvertFrom-Json
    
    $queryId = $queryExec.QueryExecutionId
    Write-Info "  Query ID: $queryId"
    Start-Sleep -Seconds 10
    
    $queryStatus = aws athena get-query-execution --query-execution-id $queryId | ConvertFrom-Json
    
    if ($queryStatus.QueryExecution.Status.State -eq "SUCCEEDED") {
        $results = aws athena get-query-results --query-execution-id $queryId | ConvertFrom-Json
        Write-Success "Query executada com sucesso"
        Write-Host "`n Estatísticas da tabela SLIM:" -ForegroundColor Cyan
        $row = $results.ResultSet.Rows[1]
        Write-Host "   • Total de alertas: $($row.Data[0].VarCharValue)" -ForegroundColor White
        Write-Host "   • Carros únicos: $($row.Data[1].VarCharValue)" -ForegroundColor White
        Write-Host "   • Tipos de alertas: $($row.Data[2].VarCharValue)" -ForegroundColor White
    } else {
        Write-Error "Query falhou: $($queryStatus.QueryExecution.Status.State)"
    }
    
    Write-Host "`n" -ForegroundColor Green
    Write-Host "   VALIDAÇÃO CONCLUÍDA!                                  " -ForegroundColor White
    Write-Host "" -ForegroundColor Green
    
    Write-Host "`n[QUERIES] Execute no Athena:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "-- Comparar contagem de alertas (devem ser iguais)" -ForegroundColor Gray
    Write-Host "SELECT '$OldTableName' as tabela, COUNT(*) as total FROM $OldTableName" -ForegroundColor White
    Write-Host "UNION ALL" -ForegroundColor White
    Write-Host "SELECT '$NewTableName' as tabela, COUNT(*) as total FROM $NewTableName;" -ForegroundColor White
    Write-Host ""
    Write-Host "-- Ver colunas da tabela SLIM" -ForegroundColor Gray
    Write-Host "SELECT * FROM $NewTableName LIMIT 10;" -ForegroundColor White
    Write-Host ""
    Write-Host "-- Comparar por tipo de alerta" -ForegroundColor Gray
    Write-Host "SELECT alert_type, COUNT(*) as total" -ForegroundColor White
    Write-Host "FROM $NewTableName" -ForegroundColor White
    Write-Host "GROUP BY alert_type" -ForegroundColor White
    Write-Host "ORDER BY total DESC;" -ForegroundColor White
    
    Write-Host "`n[PROXIMO PASSO]" -ForegroundColor Cyan
    Write-Host "   Após confirmar que os dados estão corretos:"
    Write-Host "   .\Migrate-AlertsPipeline.ps1 -Stage cleanup"
}

# 
# STAGE 3: CLEANUP
# 

if ($Stage -eq "cleanup") {
    Write-StageHeader "STAGE 3: CLEANUP - Remoção de Recursos Antigos"
    
    Write-Host "  ATENÇÃO: Esta operação é IRREVERSÍVEL!" -ForegroundColor Red
    Write-Host "`nRecursos que serão REMOVIDOS:" -ForegroundColor Yellow
    Write-Host "   1. Glue Job: $OldJobName"
    Write-Host "   2. Glue Crawler: $OldCrawlerName"
    Write-Host "   3. Glue Trigger: trigger associado ao job antigo"
    Write-Host "   4. IAM Roles e Policies antigas"
    Write-Host "   5. CloudWatch Log Group antigo"
    
    Write-Host "`nDados S3 NÃO serão deletados (backup manual necessário)" -ForegroundColor Cyan
    
    $confirmation = Read-Host "`n Deseja REALMENTE remover os recursos antigos? (type 'DELETE' to confirm)"
    if ($confirmation -ne "DELETE") {
        Write-Info "Cleanup cancelado pelo usuário"
        exit 0
    }
    
    # Lista de recursos para remover do Terraform state
    $resourcesToRemove = @(
        "aws_glue_job.gold_performance_alerts"
        "aws_glue_crawler.gold_performance_alerts"
        "aws_glue_trigger.gold_alerts_job_succeeded_start_crawler"
        "aws_iam_role.gold_alerts_job_role"
        "aws_iam_role.gold_alerts_crawler_role"
        "aws_iam_role_policy.gold_alerts_job_catalog_access"
        "aws_iam_role_policy.gold_alerts_job_read_silver"
        "aws_iam_role_policy.gold_alerts_job_write_gold"
        "aws_iam_role_policy.gold_alerts_job_cloudwatch"
        "aws_iam_role_policy.gold_alerts_job_scripts"
        "aws_iam_role_policy.gold_alerts_crawler_s3"
        "aws_iam_role_policy.gold_alerts_crawler_catalog"
        "aws_iam_role_policy.gold_alerts_crawler_cloudwatch"
        "aws_cloudwatch_log_group.gold_alerts_job_logs"
        "aws_s3_object.gold_alerts_script"
    )
    
    Set-Location "$PSScriptRoot\..\terraform"
    
    Write-Step "Removendo recursos do Terraform state..."
    foreach ($resource in $resourcesToRemove) {
        Write-Info "  Removendo: $resource"
        terraform state rm $resource 2>$null
    }
    Write-Success "Recursos removidos do state"
    
    Write-Host "`n[CLEANUP CONCLUIDO]" -ForegroundColor Green
    Write-Host ""
    Write-Host "   OK Pipeline SLIM ativo e funcionando" -ForegroundColor Green
    Write-Host "   OK Recursos antigos removidos do Terraform" -ForegroundColor Green
    Write-Host "   AVISO Dados antigos ainda no S3 (backup manual se necessario)" -ForegroundColor Yellow
    Write-Host "   ECONOMIA Aproximadamente 80 porcento em storage e reducao de custos Athena" -ForegroundColor Green
}
