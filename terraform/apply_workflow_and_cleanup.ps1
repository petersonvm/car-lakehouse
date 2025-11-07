# ===================================================================
# SCRIPT DE EXECUÇÃO: WORKFLOW COMPLETION & CLEANUP
# ===================================================================
# Arquivo: apply_workflow_and_cleanup.ps1
# Autor: GitHub Copilot
# Data: 2025-11-06
# Objetivo: Automatizar criação de triggers do workflow e cleanup de recursos legados
# ===================================================================

# ===================================================================
# CONFIGURAÇÕES
# ===================================================================
$AWS_REGION = "us-east-1"
$TERRAFORM_DIR = "c:\dev\HP\wsas\Poc\terraform"
$WORKFLOW_NAME = "datalake-pipeline-silver-gold-workflow-dev"

Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host "WORKFLOW COMPLETION & CLEANUP - AUTOMAÇÃO" -ForegroundColor Cyan
Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host ""

# ===================================================================
# FUNÇÃO: VALIDAR PREREQUISITOS
# ===================================================================
function Test-Prerequisites {
    Write-Host "  Validando pré-requisitos..." -ForegroundColor Yellow
    
    # Verificar AWS CLI
    try {
        $awsVersion = aws --version 2>&1
        Write-Host "   AWS CLI instalado: $awsVersion" -ForegroundColor Green
    } catch {
        Write-Host "   AWS CLI não encontrado. Instale antes de continuar." -ForegroundColor Red
        exit 1
    }
    
    # Verificar Terraform
    try {
        $tfVersion = terraform version -json | ConvertFrom-Json
        Write-Host "   Terraform instalado: $($tfVersion.terraform_version)" -ForegroundColor Green
    } catch {
        Write-Host "   Terraform não encontrado. Instale antes de continuar." -ForegroundColor Red
        exit 1
    }
    
    # Verificar credenciais AWS
    try {
        $identity = aws sts get-caller-identity 2>&1 | ConvertFrom-Json
        Write-Host "   Credenciais AWS configuradas: $($identity.UserId)" -ForegroundColor Green
    } catch {
        Write-Host "   Credenciais AWS inválidas. Configure via 'aws configure'." -ForegroundColor Red
        exit 1
    }
    
    Write-Host ""
}

# ===================================================================
# FUNÇÃO: VERIFICAR STATUS DO WORKFLOW NA AWS
# ===================================================================
function Get-WorkflowStatus {
    Write-Host " Verificando status do workflow na AWS..." -ForegroundColor Yellow
    
    try {
        $workflow = aws glue get-workflow --name $WORKFLOW_NAME --region $AWS_REGION 2>&1 | ConvertFrom-Json
        
        if ($workflow.Workflow) {
            Write-Host "   Workflow existe: $WORKFLOW_NAME" -ForegroundColor Green
            
            # Contar triggers
            $triggers = aws glue get-workflow --name $WORKFLOW_NAME --region $AWS_REGION `
                --query "Workflow.Graph.Nodes[?Type=='TRIGGER'].Name" --output json | ConvertFrom-Json
            
            Write-Host "   Triggers encontrados: $($triggers.Count)" -ForegroundColor Cyan
            
            # Listar triggers
            foreach ($trigger in $triggers) {
                Write-Host "     - $trigger" -ForegroundColor Gray
            }
            
            return $triggers.Count
        }
    } catch {
        Write-Host "   Workflow não encontrado na AWS" -ForegroundColor Red
        return 0
    }
    
    Write-Host ""
}

# ===================================================================
# FUNÇÃO: LISTAR RECURSOS LEGADOS EXISTENTES
# ===================================================================
function Get-LegacyResources {
    Write-Host "  Verificando recursos legados..." -ForegroundColor Yellow
    
    # Crawlers legados
    $legacyCrawlers = @(
        "car_silver_crawler",
        "datalake-pipeline-gold-crawler-dev",
        "datalake-pipeline-gold-performance-alerts-crawler-dev",
        "datalake-pipeline-gold-performance-alerts-slim-crawler-dev",
        "datalake-pipeline-gold-fuel-efficiency-crawler-dev",
        "datalake-pipeline-silver-crawler-dev"
    )
    
    $existingCrawlers = @()
    foreach ($crawler in $legacyCrawlers) {
        try {
            aws glue get-crawler --name $crawler --region $AWS_REGION 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $existingCrawlers += $crawler
                Write-Host "    Crawler legado encontrado: $crawler" -ForegroundColor Yellow
            }
        } catch {}
    }
    
    # Lambdas legadas
    $legacyLambdas = @(
        "datalake-pipeline-cleansing-dev",
        "datalake-pipeline-analysis-dev",
        "datalake-pipeline-compliance-dev"
    )
    
    $existingLambdas = @()
    foreach ($lambda in $legacyLambdas) {
        try {
            aws lambda get-function --function-name $lambda --region $AWS_REGION 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $existingLambdas += $lambda
                Write-Host "    Lambda legada encontrada: $lambda" -ForegroundColor Yellow
            }
        } catch {}
    }
    
    # Job legado
    $legacyJob = "datalake-pipeline-gold-performance-alerts-dev"
    try {
        aws glue get-job --job-name $legacyJob --region $AWS_REGION 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Job legado encontrado: $legacyJob" -ForegroundColor Yellow
        }
    } catch {}
    
    Write-Host ""
    return @{
        Crawlers = $existingCrawlers
        Lambdas = $existingLambdas
        Jobs = @($legacyJob)
        Total = $existingCrawlers.Count + $existingLambdas.Count + 1
    }
}

# ===================================================================
# ETAPA 1: APLICAR TRIGGERS DO WORKFLOW
# ===================================================================
function Invoke-WorkflowTriggers {
    Write-Host "=====================================================================" -ForegroundColor Cyan
    Write-Host "ETAPA 1: CRIAR TRIGGERS DO WORKFLOW (4, 5 e 6)" -ForegroundColor Cyan
    Write-Host "=====================================================================" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host " Triggers a serem criados:" -ForegroundColor Yellow
    Write-Host "  1. trigger-gold-current-state-to-crawler" -ForegroundColor Gray
    Write-Host "  2. trigger-gold-fuel-efficiency-to-crawler" -ForegroundColor Gray
    Write-Host "  3. trigger-gold-alerts-to-crawler" -ForegroundColor Gray
    Write-Host ""
    
    $confirm = Read-Host "Deseja prosseguir? (S/N)"
    if ($confirm -ne "S" -and $confirm -ne "s") {
        Write-Host " Operação cancelada pelo usuário." -ForegroundColor Red
        return $false
    }
    
    Write-Host ""
    Write-Host " Executando terraform plan..." -ForegroundColor Cyan
    
    Set-Location $TERRAFORM_DIR
    
    terraform plan `
        -target=aws_glue_trigger.trigger_gold_current_state_to_crawler `
        -target=aws_glue_trigger.trigger_gold_fuel_efficiency_to_crawler `
        -target=aws_glue_trigger.trigger_gold_alerts_to_crawler
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host " Terraform plan falhou. Verifique os erros acima." -ForegroundColor Red
        return $false
    }
    
    Write-Host ""
    $confirm = Read-Host "Plan validado. Executar terraform apply? (S/N)"
    if ($confirm -ne "S" -and $confirm -ne "s") {
        Write-Host " Operação cancelada pelo usuário." -ForegroundColor Red
        return $false
    }
    
    Write-Host ""
    Write-Host " Executando terraform apply..." -ForegroundColor Cyan
    
    terraform apply -auto-approve `
        -target=aws_glue_trigger.trigger_gold_current_state_to_crawler `
        -target=aws_glue_trigger.trigger_gold_fuel_efficiency_to_crawler `
        -target=aws_glue_trigger.trigger_gold_alerts_to_crawler
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host " Triggers criados com sucesso!" -ForegroundColor Green
        return $true
    } else {
        Write-Host " Terraform apply falhou." -ForegroundColor Red
        return $false
    }
}

# ===================================================================
# ETAPA 2: EXECUTAR CLEANUP DE RECURSOS LEGADOS
# ===================================================================
function Invoke-Cleanup {
    param (
        [hashtable]$LegacyResources
    )
    
    Write-Host ""
    Write-Host "=====================================================================" -ForegroundColor Cyan
    Write-Host "ETAPA 2: CLEANUP DE RECURSOS LEGADOS" -ForegroundColor Cyan
    Write-Host "=====================================================================" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "  Recursos marcados para remoção:" -ForegroundColor Yellow
    Write-Host "   Crawlers: $($LegacyResources.Crawlers.Count)" -ForegroundColor Gray
    Write-Host "  λ  Lambdas: $($LegacyResources.Lambdas.Count)" -ForegroundColor Gray
    Write-Host "   Jobs: $($LegacyResources.Jobs.Count)" -ForegroundColor Gray
    Write-Host "   Total: $($LegacyResources.Total)" -ForegroundColor Gray
    Write-Host ""
    Write-Host " Economia estimada: $15-20/mês" -ForegroundColor Green
    Write-Host ""
    
    $confirm = Read-Host "  ATENÇÃO: Esta operação é IRREVERSÍVEL. Confirmar remoção? (S/N)"
    if ($confirm -ne "S" -and $confirm -ne "s") {
        Write-Host " Operação cancelada pelo usuário." -ForegroundColor Red
        return $false
    }
    
    Write-Host ""
    Write-Host " Executando terraform apply para cleanup..." -ForegroundColor Cyan
    
    Set-Location $TERRAFORM_DIR
    
    terraform apply -auto-approve `
        -target=null_resource.cleanup_car_silver_crawler `
        -target=null_resource.cleanup_gold_crawler_generic `
        -target=null_resource.cleanup_gold_performance_alerts_crawler `
        -target=null_resource.cleanup_gold_performance_alerts_slim_crawler_long `
        -target=null_resource.cleanup_gold_fuel_efficiency_crawler_long `
        -target=null_resource.cleanup_silver_crawler_generic `
        -target=null_resource.cleanup_lambda_cleansing `
        -target=null_resource.cleanup_lambda_analysis `
        -target=null_resource.cleanup_lambda_compliance `
        -target=null_resource.cleanup_job_performance_alerts
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host " Cleanup executado com sucesso!" -ForegroundColor Green
        return $true
    } else {
        Write-Host " Cleanup falhou parcialmente. Verifique logs acima." -ForegroundColor Red
        return $false
    }
}

# ===================================================================
# ETAPA 3: VALIDAR RESULTADO FINAL
# ===================================================================
function Test-FinalState {
    Write-Host ""
    Write-Host "=====================================================================" -ForegroundColor Cyan
    Write-Host "ETAPA 3: VALIDAÇÃO FINAL" -ForegroundColor Cyan
    Write-Host "=====================================================================" -ForegroundColor Cyan
    Write-Host ""
    
    # Verificar triggers do workflow
    Write-Host " Verificando triggers do workflow..." -ForegroundColor Yellow
    $triggersCount = Get-WorkflowStatus
    
    if ($triggersCount -ge 6) {
        Write-Host "   Workflow completo: $triggersCount triggers encontrados" -ForegroundColor Green
    } else {
        Write-Host "    Triggers insuficientes: $triggersCount/6" -ForegroundColor Yellow
    }
    
    Write-Host ""
    
    # Verificar recursos legados restantes
    Write-Host "  Verificando recursos legados restantes..." -ForegroundColor Yellow
    $remainingResources = Get-LegacyResources
    
    if ($remainingResources.Total -eq 0) {
        Write-Host "   Todos os recursos legados foram removidos!" -ForegroundColor Green
    } else {
        Write-Host "    $($remainingResources.Total) recursos ainda existem" -ForegroundColor Yellow
    }
    
    Write-Host ""
}

# ===================================================================
# MAIN EXECUTION
# ===================================================================
Test-Prerequisites

$currentTriggers = Get-WorkflowStatus
$legacyResources = Get-LegacyResources

Write-Host ""
Write-Host " RESUMO DO ESTADO ATUAL:" -ForegroundColor Cyan
Write-Host "  - Triggers no workflow: $currentTriggers" -ForegroundColor Gray
Write-Host "  - Recursos legados: $($legacyResources.Total)" -ForegroundColor Gray
Write-Host ""

# Menu de opções
Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host "SELECIONE A OPERAÇÃO:" -ForegroundColor Cyan
Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host "1. Executar apenas ETAPA 1 (Criar triggers do workflow)" -ForegroundColor White
Write-Host "2. Executar apenas ETAPA 2 (Cleanup de recursos legados)" -ForegroundColor White
Write-Host "3. Executar ETAPA 1 + ETAPA 2 (Fluxo completo)" -ForegroundColor White
Write-Host "4. Apenas validar estado final (sem alterações)" -ForegroundColor White
Write-Host "0. Sair" -ForegroundColor White
Write-Host ""

$option = Read-Host "Digite a opção desejada"

switch ($option) {
    "1" {
        Invoke-WorkflowTriggers
        Test-FinalState
    }
    "2" {
        Invoke-Cleanup -LegacyResources $legacyResources
        Test-FinalState
    }
    "3" {
        $step1Success = Invoke-WorkflowTriggers
        if ($step1Success) {
            Invoke-Cleanup -LegacyResources $legacyResources
        }
        Test-FinalState
    }
    "4" {
        Test-FinalState
    }
    "0" {
        Write-Host " Saindo..." -ForegroundColor Yellow
        exit 0
    }
    default {
        Write-Host " Opção inválida." -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "=====================================================================" -ForegroundColor Green
Write-Host " EXECUÇÃO CONCLUÍDA" -ForegroundColor Green
Write-Host "=====================================================================" -ForegroundColor Green
Write-Host ""
Write-Host " Próximos passos recomendados:" -ForegroundColor Cyan
Write-Host "  1. Executar teste E2E do pipeline Bronze→Silver→Gold" -ForegroundColor Gray
Write-Host "  2. Validar tabelas no Athena (4 tabelas esperadas)" -ForegroundColor Gray
Write-Host "  3. Monitorar custos no AWS Cost Explorer" -ForegroundColor Gray
Write-Host ""
