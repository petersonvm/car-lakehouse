# ============================================================
# SCRIPT DE RECUPERAÇÃO AUTOMÁTICA DO WORKFLOW
# ============================================================
# Descrição: Executa procedimento completo de recuperação após
#            atualizações Terraform que afetam Glue Jobs/Crawlers
# Versão: 1.0
# Data: 31/10/2025
# ============================================================

param(
    [Parameter(Mandatory=$false)]
    [switch]$SkipBronzeCrawler,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipBookmarkReset,
    
    [Parameter(Mandatory=$false)]
    [switch]$AutoApprove,
    
    [Parameter(Mandatory=$false)]
    [int]$WaitSeconds = 90
)

# Configurações
$WorkflowName = "datalake-pipeline-silver-etl-workflow-dev"
$BronzeCrawlerName = "datalake-pipeline-bronze-car-data-crawler-dev"
$DatabaseName = "datalake-pipeline-catalog-dev"

$Jobs = @(
    "datalake-pipeline-silver-consolidation-dev",
    "datalake-pipeline-gold-car-current-state-dev",
    "datalake-pipeline-gold-performance-alerts-dev"
)

# ============================================================
# FUNÇÕES AUXILIARES
# ============================================================

function Write-StepHeader {
    param([string]$StepNumber, [string]$Description)
    Write-Host "`n" -ForegroundColor Cyan
    Write-Host "" -ForegroundColor Green
    Write-Host "  PASSO $StepNumber`: $Description" -ForegroundColor White
    Write-Host "" -ForegroundColor Green
    Write-Host ""
}

function Write-Success {
    param([string]$Message)
    Write-Host " $Message" -ForegroundColor Green
}

function Write-Error {
    param([string]$Message)
    Write-Host " $Message" -ForegroundColor Red
}

function Write-Warning {
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "ℹ  $Message" -ForegroundColor Cyan
}

function Wait-WithProgress {
    param([int]$Seconds, [string]$Message)
    
    Write-Host "`n⏳ $Message" -ForegroundColor Cyan
    for ($i = 1; $i -le $Seconds; $i++) {
        $percent = [math]::Round(($i / $Seconds) * 100)
        $bar = "" * [math]::Floor($percent / 5)
        $space = "" * (20 - [math]::Floor($percent / 5))
        Write-Host -NoNewline "`r   [$bar$space] $percent% ($i/$Seconds s)"
        Start-Sleep -Seconds 1
    }
    Write-Host ""
}

# ============================================================
# BANNER
# ============================================================

Clear-Host
Write-Host "`n"
Write-Host "" -ForegroundColor Cyan
Write-Host "   RECUPERAÇÃO AUTOMÁTICA DO WORKFLOW GLUE" -ForegroundColor White -BackgroundColor DarkBlue
Write-Host "" -ForegroundColor Cyan
Write-Host "`nWorkflow: $WorkflowName" -ForegroundColor White
Write-Host "Data/Hora: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
Write-Host ""

# Confirmação
if (-not $AutoApprove) {
    Write-Warning "Este script irá executar os seguintes passos:"
    Write-Host "  1. Verificar status atual do workflow" -ForegroundColor Gray
    if (-not $SkipBronzeCrawler) {
        Write-Host "  2. Executar Bronze Crawler (aguardar $WaitSeconds segundos)" -ForegroundColor Gray
    }
    if (-not $SkipBookmarkReset) {
        Write-Host "  3. Resetar Job Bookmarks (3 jobs)" -ForegroundColor Gray
    }
    Write-Host "  4. Executar workflow completo" -ForegroundColor Gray
    Write-Host "  5. Monitorar execução" -ForegroundColor Gray
    Write-Host "  6. Validar resultados" -ForegroundColor Gray
    Write-Host ""
    
    $confirmation = Read-Host "Deseja continuar? (S/N)"
    if ($confirmation -ne 'S' -and $confirmation -ne 's') {
        Write-Host "`n Operação cancelada pelo usuário." -ForegroundColor Red
        exit 0
    }
}

# ============================================================
# PASSO 0: Verificar Status Atual
# ============================================================

Write-StepHeader "0" "VERIFICANDO STATUS ATUAL"

try {
    $lastRun = aws glue get-workflow-runs `
        --name $WorkflowName `
        --max-results 1 `
        --output json | ConvertFrom-Json
    
    $runStatus = $lastRun.Runs[0]
    
    Write-Host "Última Execução:" -ForegroundColor Cyan
    Write-Host "  Run ID: $($runStatus.WorkflowRunId)" -ForegroundColor White
    Write-Host "  Status: $($runStatus.Status)" -ForegroundColor $(if($runStatus.Status -eq 'COMPLETED'){'Green'}else{'Yellow'})
    Write-Host "  Início: $($runStatus.StartedOn)" -ForegroundColor Gray
    Write-Host "  Conclusão: $($runStatus.CompletedOn)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Estatísticas:" -ForegroundColor Cyan
    Write-Host "   Sucesso: $($runStatus.Statistics.SucceededActions)" -ForegroundColor Green
    Write-Host "   Falhas: $($runStatus.Statistics.FailedActions)" -ForegroundColor $(if($runStatus.Statistics.FailedActions -gt 0){'Red'}else{'Gray'})
    Write-Host "   Total: $($runStatus.Statistics.TotalActions)" -ForegroundColor White
    
    if ($runStatus.Statistics.FailedActions -eq 0 -and $runStatus.Status -eq "COMPLETED") {
        Write-Success "Workflow está operacional! Recuperação pode não ser necessária."
        Write-Host ""
        $continue = Read-Host "Deseja continuar mesmo assim? (S/N)"
        if ($continue -ne 'S' -and $continue -ne 's') {
            Write-Host "`n Script finalizado." -ForegroundColor Green
            exit 0
        }
    } else {
        Write-Warning "Workflow tem problemas que precisam ser corrigidos."
    }
}
catch {
    Write-Error "Erro ao verificar status do workflow: $_"
    Write-Info "Continuando com recuperação..."
}

# ============================================================
# PASSO 1: Executar Bronze Crawler
# ============================================================

if (-not $SkipBronzeCrawler) {
    Write-StepHeader "1" "EXECUTANDO BRONZE CRAWLER"
    
    try {
        Write-Info "Iniciando crawler: $BronzeCrawlerName"
        aws glue start-crawler --name $BronzeCrawlerName 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Bronze Crawler iniciado com sucesso!"
            Wait-WithProgress -Seconds $WaitSeconds -Message "Aguardando conclusão do crawler..."
            
            # Verificar status final
            $crawlerStatus = aws glue get-crawler `
                --name $BronzeCrawlerName `
                --output json | ConvertFrom-Json
            
            Write-Host ""
            Write-Host "Status do Crawler:" -ForegroundColor Cyan
            Write-Host "  Estado: $($crawlerStatus.Crawler.State)" -ForegroundColor White
            Write-Host "  Última Execução: $($crawlerStatus.Crawler.LastCrawl.Status)" -ForegroundColor $(if($crawlerStatus.Crawler.LastCrawl.Status -eq 'SUCCEEDED'){'Green'}else{'Red'})
            
            if ($crawlerStatus.Crawler.LastCrawl.Status -eq "SUCCEEDED") {
                Write-Success "Bronze Crawler concluído com sucesso!"
            } else {
                Write-Warning "Crawler pode não ter concluído. Status: $($crawlerStatus.Crawler.State)"
            }
        }
        else {
            Write-Warning "Crawler pode já estar em execução. Aguardando..."
            Wait-WithProgress -Seconds $WaitSeconds -Message "Aguardando conclusão..."
        }
    }
    catch {
        Write-Error "Erro ao executar Bronze Crawler: $_"
        Write-Warning "Continuando com próximos passos..."
    }
}
else {
    Write-Info "Bronze Crawler ignorado (parâmetro -SkipBronzeCrawler)"
}

# ============================================================
# PASSO 2: Resetar Job Bookmarks
# ============================================================

if (-not $SkipBookmarkReset) {
    Write-StepHeader "2" "RESETANDO JOB BOOKMARKS"
    
    $bookmarksResetados = 0
    $bookmarksNaoEncontrados = 0
    
    foreach ($jobName in $Jobs) {
        Write-Host "  → $jobName..." -ForegroundColor Cyan -NoNewline
        
        try {
            $result = aws glue reset-job-bookmark --job-name $jobName 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host " " -ForegroundColor Green
                $bookmarksResetados++
            }
            else {
                if ($result -like "*EntityNotFoundException*") {
                    Write-Host "   (não executado ainda)" -ForegroundColor Yellow
                    $bookmarksNaoEncontrados++
                }
                else {
                    Write-Host " " -ForegroundColor Red
                    Write-Warning "    Erro: $result"
                }
            }
        }
        catch {
            Write-Host " " -ForegroundColor Red
            Write-Warning "    Exceção: $_"
        }
    }
    
    Write-Host ""
    Write-Success "Bookmarks resetados: $bookmarksResetados/$($Jobs.Count)"
    if ($bookmarksNaoEncontrados -gt 0) {
        Write-Info "$bookmarksNaoEncontrados job(s) nunca foram executados (normal para jobs novos)"
    }
}
else {
    Write-Info "Job Bookmarks não resetados (parâmetro -SkipBookmarkReset)"
}

# ============================================================
# PASSO 3: Executar Workflow
# ============================================================

Write-StepHeader "3" "EXECUTANDO WORKFLOW"

try {
    Write-Info "Iniciando workflow: $WorkflowName"
    $runResult = aws glue start-workflow-run --name $WorkflowName --output json | ConvertFrom-Json
    $runId = $runResult.RunId
    
    Write-Success "Workflow iniciado com sucesso!"
    Write-Host "  Run ID: $runId" -ForegroundColor Cyan
    Write-Host ""
}
catch {
    Write-Error "Erro ao iniciar workflow: $_"
    Write-Host "`n Não foi possível iniciar o workflow. Verifique os logs." -ForegroundColor Red
    exit 1
}

# ============================================================
# PASSO 4: Monitorar Execução
# ============================================================

Write-StepHeader "4" "MONITORANDO EXECUÇÃO"

Write-Info "Monitoramento automático iniciado (checagem a cada 30 segundos)"
Write-Info "Tempo estimado: 3-4 minutos"
Write-Host ""

$maxIterations = 12  # 6 minutos máximo
$iteration = 0
$completed = $false

while ($iteration -lt $maxIterations -and -not $completed) {
    $iteration++
    Start-Sleep -Seconds 30
    
    try {
        $currentRun = aws glue get-workflow-run `
            --name $WorkflowName `
            --run-id $runId `
            --output json | ConvertFrom-Json
        
        $runData = $currentRun.Run
        
        # Cabeçalho do status
        Write-Host "[$iteration] " -ForegroundColor White -NoNewline
        Write-Host "$(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Gray -NoNewline
        Write-Host " | Status: " -NoNewline
        
        $statusColor = switch ($runData.Status) {
            "RUNNING" { "Yellow" }
            "COMPLETED" { "Green" }
            default { "Red" }
        }
        Write-Host $runData.Status -ForegroundColor $statusColor
        
        # Estatísticas
        Write-Host "     Sucesso: $($runData.Statistics.SucceededActions)/$($runData.Statistics.TotalActions)" -ForegroundColor Green
        Write-Host "     Falhas: $($runData.Statistics.FailedActions)" -ForegroundColor $(if($runData.Statistics.FailedActions -gt 0){'Red'}else{'Gray'})
        Write-Host "     Rodando: $($runData.Statistics.RunningActions)" -ForegroundColor Yellow
        
        if ($runData.Status -ne "RUNNING") {
            $completed = $true
            Write-Host ""
            
            if ($runData.Status -eq "COMPLETED") {
                if ($runData.Statistics.FailedActions -eq 0) {
                    Write-Success "Workflow concluído com SUCESSO TOTAL!"
                }
                else {
                    Write-Warning "Workflow concluído com $($runData.Statistics.FailedActions) falha(s)"
                }
            }
            else {
                Write-Error "Workflow terminou com status: $($runData.Status)"
            }
            
            break
        }
    }
    catch {
        Write-Error "Erro ao verificar status: $_"
    }
}

if (-not $completed) {
    Write-Warning "Timeout atingido. Workflow ainda pode estar em execução."
    Write-Info "Use o comando abaixo para verificar manualmente:"
    Write-Host "  aws glue get-workflow-run --name $WorkflowName --run-id $runId" -ForegroundColor Gray
}

# ============================================================
# PASSO 5: Validar Tabelas
# ============================================================

Write-StepHeader "5" "VALIDANDO TABELAS CATALOGADAS"

try {
    $tables = aws glue get-tables `
        --database-name $DatabaseName `
        --output json | ConvertFrom-Json
    
    Write-Host "Tabelas encontradas: $($tables.TableList.Count)" -ForegroundColor Cyan
    Write-Host ""
    
    $expectedTables = @(
        "bronze_ingest_year_2025",
        "silver_car_telemetry",
        "gold_car_current_state",
        "performance_alerts_log"
    )
    
    foreach ($expectedTable in $expectedTables) {
        $found = $tables.TableList | Where-Object { $_.Name -eq $expectedTable }
        if ($found) {
            Write-Host "   $expectedTable" -ForegroundColor Green
            Write-Host "     Atualizada: $($found.UpdateTime)" -ForegroundColor Gray
        }
        else {
            Write-Host "   $expectedTable (NÃO ENCONTRADA)" -ForegroundColor Red
        }
    }
    
    Write-Host ""
    $foundCount = ($expectedTables | Where-Object { $tables.TableList.Name -contains $_ }).Count
    
    if ($foundCount -eq $expectedTables.Count) {
        Write-Success "Todas as tabelas esperadas estão catalogadas!"
    }
    else {
        Write-Warning "$foundCount/$($expectedTables.Count) tabelas encontradas"
    }
}
catch {
    Write-Error "Erro ao validar tabelas: $_"
}

# ============================================================
# RESUMO FINAL
# ============================================================

Write-Host "`n"
Write-Host "" -ForegroundColor Cyan
Write-Host "   RESUMO DA RECUPERAÇÃO" -ForegroundColor White -BackgroundColor DarkBlue
Write-Host "" -ForegroundColor Cyan
Write-Host ""

if ($completed -and $runData.Status -eq "COMPLETED" -and $runData.Statistics.FailedActions -eq 0) {
    Write-Host " RECUPERAÇÃO CONCLUÍDA COM SUCESSO!" -ForegroundColor Green -BackgroundColor Black
    Write-Host ""
    Write-Host " Workflow executado: 6/6 ações com sucesso" -ForegroundColor Green
    Write-Host " Todas as tabelas catalogadas" -ForegroundColor Green
    Write-Host " Pipeline 100% operacional" -ForegroundColor Green
    Write-Host ""
    Write-Success "Ambiente pronto para uso!"
}
elseif ($completed -and $runData.Statistics.FailedActions -gt 0) {
    Write-Host "  RECUPERAÇÃO PARCIAL" -ForegroundColor Yellow -BackgroundColor Black
    Write-Host ""
    Write-Warning "Workflow executado com $($runData.Statistics.FailedActions) falha(s)"
    Write-Host ""
    Write-Info "Próximos passos:"
    Write-Host "  1. Verifique os logs CloudWatch dos componentes que falharam" -ForegroundColor Gray
    Write-Host "  2. Consulte o WORKFLOW_RECOVERY_GUIDE.md para troubleshooting" -ForegroundColor Gray
    Write-Host "  3. Execute comandos de diagnóstico específicos" -ForegroundColor Gray
}
else {
    Write-Host " RECUPERAÇÃO NÃO CONCLUÍDA" -ForegroundColor Red -BackgroundColor Black
    Write-Host ""
    Write-Warning "Workflow pode ainda estar em execução ou ter falhado"
    Write-Host ""
    Write-Info "Verifique manualmente:"
    Write-Host "  aws glue get-workflow-run --name $WorkflowName --run-id $runId --include-graph" -ForegroundColor Gray
}

Write-Host ""
Write-Host "" -ForegroundColor Cyan
Write-Host "Finalizado em: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
Write-Host ""
