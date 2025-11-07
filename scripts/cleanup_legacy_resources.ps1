# Automated Legacy Resources Cleanup Script
# Author: Senior DevOps Engineer
# Date: November 6, 2025
# Version: 1.0

param(
    [Parameter(Mandatory=$false)]
    [switch]$DryRun = $false,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipBackup = $false,
    
    [Parameter(Mandatory=$false)]
    [string]$Environment = "dev",
    
    [Parameter(Mandatory=$false)]
    [string]$ProjectName = "datalake-pipeline"
)

# Colors for output
$Green = "Green"
$Yellow = "Yellow"
$Red = "Red"
$Cyan = "Cyan"
$Gray = "Gray"

Write-Host "`n" -ForegroundColor $Green
Write-Host "        LEGACY RESOURCES CLEANUP - CAR LAKEHOUSE               " -ForegroundColor $Green
Write-Host "`n" -ForegroundColor $Green

Write-Host " CONFIGURATION:" -ForegroundColor $Cyan
Write-Host "   Mode: $(if($DryRun){'DRY RUN (simulation)'}else{'REAL EXECUTION'})" -ForegroundColor $(if($DryRun){$Yellow}else{$Red})
Write-Host "   Environment: $Environment" -ForegroundColor $Gray
Write-Host "   Project: $ProjectName" -ForegroundColor $Gray
Write-Host "   Backup: $(if($SkipBackup){'Disabled'}else{'Enabled'})`n" -ForegroundColor $Gray

# Validate terraform directory
if (-not (Test-Path "terraform")) {
    Write-Host " ERROR: Directory 'terraform' not found!" -ForegroundColor $Red
    Write-Host "   Run this script from project root.`n" -ForegroundColor $Red
    exit 1
}

Set-Location terraform

# ============================================
# PHASE 1: STATE BACKUP
# ============================================
if (-not $SkipBackup) {
    Write-Host " PHASE 1: TERRAFORM STATE BACKUP" -ForegroundColor $Yellow
    
    $BackupFile = "terraform.tfstate.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    
    if ($DryRun) {
        Write-Host "   [DRY RUN] terraform state pull > $BackupFile" -ForegroundColor $Cyan
    } else {
        try {
            terraform state pull > $BackupFile
            Write-Host "    Backup created: $BackupFile" -ForegroundColor $Green
        } catch {
            Write-Host "    ERROR creating backup: $_" -ForegroundColor $Red
            exit 1
        }
    }
    Write-Host ""
}

# ============================================
# PHASE 2: REMOVE RESOURCES FROM STATE
# ============================================
Write-Host "  PHASE 2: REMOVE RESOURCES FROM TERRAFORM STATE" -ForegroundColor $Yellow

$ResourcesToRemove = @(
    "aws_lambda_function.cleansing",
    'aws_lambda_function.etl["analysis"]',
    'aws_lambda_function.etl["compliance"]',
    "aws_glue_crawler.gold_alerts_slim_crawler",
    "aws_glue_crawler.gold_fuel_efficiency_crawler",
    "aws_iam_role.gold_alerts_slim_crawler_role",
    "aws_iam_role_policy.gold_alerts_slim_crawler_catalog",
    "aws_iam_role_policy.gold_alerts_slim_crawler_cloudwatch",
    "aws_iam_role_policy.gold_alerts_slim_crawler_s3"
)

$RemovedCount = 0
$ErrorCount = 0

foreach ($Resource in $ResourcesToRemove) {
    Write-Host "   Removing: $Resource..." -ForegroundColor $Gray -NoNewline
    
    if ($DryRun) {
        Write-Host " [DRY RUN]" -ForegroundColor $Cyan
        $RemovedCount++
    } else {
        try {
            $Output = terraform state rm $Resource 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host " " -ForegroundColor $Green
                $RemovedCount++
            } else {
                Write-Host "  (não encontrado)" -ForegroundColor $Yellow
            }
        } catch {
            Write-Host " " -ForegroundColor $Red
            $ErrorCount++
        }
    }
}

Write-Host "`n   Resultado: $RemovedCount recursos removidos do state" -ForegroundColor $Cyan
if ($ErrorCount -gt 0) {
    Write-Host "   Avisos: $ErrorCount recursos não encontrados (já removidos?)" -ForegroundColor $Yellow
}
Write-Host ""

# ============================================
# PHASE 3: DESTROY RESOURCES IN AWS
# ============================================
Write-Host " FASE 3: DESTRUIR RECURSOS NA AWS" -ForegroundColor $Yellow

Write-Host "   3.1. Removendo Lambdas legadas..." -ForegroundColor $Gray

$LambdasToDelete = @(
    "$ProjectName-cleansing-$Environment",
    "$ProjectName-analysis-$Environment",
    "$ProjectName-compliance-$Environment"
)

foreach ($Lambda in $LambdasToDelete) {
    Write-Host "      - $Lambda..." -ForegroundColor $Gray -NoNewline
    
    if ($DryRun) {
        Write-Host " [DRY RUN]" -ForegroundColor $Cyan
    } else {
        try {
            aws lambda delete-function --function-name $Lambda 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host " " -ForegroundColor $Green
            } else {
                Write-Host "  (não encontrado)" -ForegroundColor $Yellow
            }
        } catch {
            Write-Host " " -ForegroundColor $Yellow
        }
    }
}

Write-Host "`n   3.2. Removendo Crawlers duplicados..." -ForegroundColor $Gray

$CrawlersToDelete = @(
    "gold_alerts_slim_crawler",
    "gold_fuel_efficiency_crawler"
)

foreach ($Crawler in $CrawlersToDelete) {
    Write-Host "      - $Crawler..." -ForegroundColor $Gray -NoNewline
    
    if ($DryRun) {
        Write-Host " [DRY RUN]" -ForegroundColor $Cyan
    } else {
        try {
            aws glue delete-crawler --name $Crawler 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host " " -ForegroundColor $Green
            } else {
                Write-Host "  (não encontrado)" -ForegroundColor $Yellow
            }
        } catch {
            Write-Host " " -ForegroundColor $Yellow
        }
    }
}

Write-Host "`n   3.3. Removendo IAM Role órfã..." -ForegroundColor $Gray

$RoleName = "gold_alerts_slim_crawler_role"
$PoliciesToDelete = @(
    "catalog_access",
    "cloudwatch_access",
    "s3_access"
)

foreach ($Policy in $PoliciesToDelete) {
    Write-Host "      - Policy: $Policy..." -ForegroundColor $Gray -NoNewline
    
    if ($DryRun) {
        Write-Host " [DRY RUN]" -ForegroundColor $Cyan
    } else {
        try {
            aws iam delete-role-policy --role-name $RoleName --policy-name $Policy 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host " " -ForegroundColor $Green
            } else {
                Write-Host " " -ForegroundColor $Yellow
            }
        } catch {
            Write-Host " " -ForegroundColor $Yellow
        }
    }
}

Write-Host "      - Role: $RoleName..." -ForegroundColor $Gray -NoNewline

if ($DryRun) {
    Write-Host " [DRY RUN]" -ForegroundColor $Cyan
} else {
    try {
        aws iam delete-role --role-name $RoleName 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host " " -ForegroundColor $Green
        } else {
            Write-Host " " -ForegroundColor $Yellow
        }
    } catch {
        Write-Host " " -ForegroundColor $Yellow
    }
}

Write-Host ""

# ============================================
# PHASE 4: VALIDATION
# ============================================
if (-not $DryRun) {
    Write-Host " FASE 4: VALIDAÇÃO PÓS-LIMPEZA" -ForegroundColor $Yellow
    
    Write-Host "`n   4.1. Active Lambdas (expected: 1):" -ForegroundColor $Gray
    $Lambdas = aws lambda list-functions --query "Functions[?starts_with(FunctionName, '$ProjectName')].FunctionName" --output text 2>$null
    if ($Lambdas) {
        $LambdaCount = ($Lambdas -split "`t").Count
        Write-Host "       $LambdaCount Lambda(s) ativa(s)" -ForegroundColor $Green
        $Lambdas -split "`t" | ForEach-Object { Write-Host "         - $_" -ForegroundColor $Gray }
    }
    
    Write-Host "`n   4.2. Active Crawlers (expected: 6):" -ForegroundColor $Gray
    $Crawlers = aws glue get-crawlers --query "Crawlers[?starts_with(Name, '$ProjectName') || starts_with(Name, 'gold') || starts_with(Name, 'silver')].Name" --output text 2>$null
    if ($Crawlers) {
        $CrawlerCount = ($Crawlers -split "`t").Count
        Write-Host "       $CrawlerCount Crawler(s) ativo(s)" -ForegroundColor $Green
        $Crawlers -split "`t" | ForEach-Object { Write-Host "         - $_" -ForegroundColor $Gray }
    }
    
    Write-Host "`n   4.3. Jobs Glue ativos (esperado: 4):" -ForegroundColor $Gray
    $Jobs = aws glue get-jobs --query "Jobs[?starts_with(Name, '$ProjectName')].Name" --output text 2>$null
    if ($Jobs) {
        $JobCount = ($Jobs -split "`t").Count
        Write-Host "       $JobCount Job(s) ativo(s)" -ForegroundColor $Green
        $Jobs -split "`t" | ForEach-Object { Write-Host "         - $_" -ForegroundColor $Gray }
    }
    
    Write-Host ""
}

# ============================================
# RESUMO
# ============================================
Write-Host " RESUMO DA LIMPEZA:" -ForegroundColor $Cyan

if ($DryRun) {
    Write-Host "     MODO DRY RUN - Nenhuma alteração foi feita" -ForegroundColor $Yellow
    Write-Host "   Execute sem --DryRun para aplicar as mudanças`n" -ForegroundColor $Yellow
} else {
    Write-Host "    Limpeza concluída!" -ForegroundColor $Green
    Write-Host "    $RemovedCount recursos removidos do Terraform state" -ForegroundColor $Green
    Write-Host "    Recursos destruídos na AWS" -ForegroundColor $Green
    
    if (-not $SkipBackup) {
        Write-Host "    Backup salvo: $BackupFile`n" -ForegroundColor $Green
    }
}

Write-Host " PRÓXIMOS PASSOS:" -ForegroundColor $Yellow

if ($DryRun) {
    Write-Host "   1. Revisar as ações planejadas acima" -ForegroundColor $Gray
    Write-Host "   2. Executar sem --DryRun: .\cleanup_legacy_resources.ps1" -ForegroundColor $Cyan
} else {
    Write-Host "   1. Limpar código Terraform (remover definições):" -ForegroundColor $Gray
    Write-Host "      - terraform/lambda.tf (remover cleansing)" -ForegroundColor $Cyan
    Write-Host "      - terraform/variables.tf (remover analysis, compliance, cleansing_*)" -ForegroundColor $Cyan
    Write-Host "      - terraform/crawlers.tf (remover gold_fuel_efficiency_crawler, gold_alerts_slim_crawler)" -ForegroundColor $Cyan
    
    Write-Host "`n   2. Validar Terraform:" -ForegroundColor $Gray
    Write-Host "      terraform fmt" -ForegroundColor $Cyan
    Write-Host "      terraform validate" -ForegroundColor $Cyan
    Write-Host "      terraform plan" -ForegroundColor $Cyan
    
    Write-Host "`n   3. Executar Workflow para validar pipeline:" -ForegroundColor $Gray
    Write-Host "      aws glue start-workflow-run --name $ProjectName-silver-gold-workflow-$Environment" -ForegroundColor $Cyan
    
    Write-Host "`n   4. Commit das mudanças:" -ForegroundColor $Gray
    Write-Host "      git add terraform/ docs/" -ForegroundColor $Cyan
    Write-Host "      git commit -m 'chore: Remover recursos legados do Terraform'" -ForegroundColor $Cyan
    Write-Host "      git push origin gold" -ForegroundColor $Cyan
}

Write-Host "`n ROLLBACK (se necessário):" -ForegroundColor $Yellow
if (-not $SkipBackup) {
    Write-Host "   cp $BackupFile terraform.tfstate" -ForegroundColor $Cyan
    Write-Host "   terraform apply`n" -ForegroundColor $Cyan
}

Set-Location ..

Write-Host " Script concluído!`n" -ForegroundColor $Green
