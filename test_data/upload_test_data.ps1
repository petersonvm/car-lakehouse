# Script to upload test data to Car Lakehouse Pipeline
# Author: Peterson VM
# Date: November 6, 2025

param(
    [Parameter(Mandatory=$false)]
    [string]$Environment = "dev",
    
    [Parameter(Mandatory=$false)]
    [string]$ProjectName = "datalake-pipeline",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("all", "001", "002", "003", "004", "005")]
    [string]$SampleFile = "all"
)

# Colors for output
$Green = "Green"
$Yellow = "Yellow"
$Red = "Red"
$Cyan = "Cyan"
$Gray = "Gray"

# Configuration
$LandingBucket = "$ProjectName-landing-$Environment"
$TestDataDir = "test_data"

Write-Host "`n" -ForegroundColor $Green
Write-Host "           TEST DATA UPLOAD - CAR LAKEHOUSE                " -ForegroundColor $Green
Write-Host "`n" -ForegroundColor $Green

Write-Host " CONFIGURAÇÃO:" -ForegroundColor $Cyan
Write-Host "   Landing Bucket: $LandingBucket" -ForegroundColor $Gray
Write-Host "   Directory: $TestDataDir" -ForegroundColor $Gray
Write-Host "   Arquivo(s): $SampleFile`n" -ForegroundColor $Gray

# Verificar se diretório existe
if (-not (Test-Path $TestDataDir)) {
    Write-Host " ERRO: Diretório '$TestDataDir' não encontrado!" -ForegroundColor $Red
    Write-Host "   Execute este script da raiz do projeto.`n" -ForegroundColor $Red
    exit 1
}

# Definir arquivos para upload
$FilesToUpload = @()

if ($SampleFile -eq "all") {
    $FilesToUpload = Get-ChildItem -Path $TestDataDir -Filter "sample_car_telemetry_*.json"
} else {
    $FileName = "sample_car_telemetry_$SampleFile.json"
    $FilePath = Join-Path $TestDataDir $FileName
    
    if (Test-Path $FilePath) {
        $FilesToUpload = @(Get-Item $FilePath)
    } else {
        Write-Host " ERRO: Arquivo '$FileName' não encontrado!" -ForegroundColor $Red
        exit 1
    }
}

Write-Host " FAZENDO UPLOAD DE $($FilesToUpload.Count) ARQUIVO(S)...`n" -ForegroundColor $Yellow

$SuccessCount = 0
$FailCount = 0

foreach ($File in $FilesToUpload) {
    Write-Host "   Uploading: $($File.Name)..." -ForegroundColor $Gray -NoNewline
    
    try {
        # Upload para S3
        aws s3 cp $File.FullName "s3://$LandingBucket/" --only-show-errors
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host " " -ForegroundColor $Green
            $SuccessCount++
        } else {
            Write-Host " " -ForegroundColor $Red
            $FailCount++
        }
    }
    catch {
        Write-Host "  ERRO: $_" -ForegroundColor $Red
        $FailCount++
    }
}

Write-Host "`n RESULTADO:" -ForegroundColor $Cyan
Write-Host "   Sucesso: $SuccessCount arquivo(s)" -ForegroundColor $Green
Write-Host "   Falha: $FailCount arquivo(s)" -ForegroundColor $(if ($FailCount -gt 0) { $Red } else { $Gray })

if ($SuccessCount -gt 0) {
    Write-Host "`n PRÓXIMOS PASSOS:" -ForegroundColor $Yellow
    Write-Host "   1. Check Lambda Ingestion logs:" -ForegroundColor $Gray
    Write-Host "      aws logs tail /aws/lambda/$ProjectName-ingestion-$Environment --follow`n" -ForegroundColor $Cyan
    
    Write-Host "   2. Verificar arquivos no Bronze:" -ForegroundColor $Gray
    Write-Host "      aws s3 ls s3://$ProjectName-bronze-$Environment/bronze/car_data/ --recursive`n" -ForegroundColor $Cyan
    
    Write-Host "   3. Executar Workflow completo:" -ForegroundColor $Gray
    Write-Host "      aws glue start-workflow-run --name $ProjectName-silver-gold-workflow-$Environment`n" -ForegroundColor $Cyan
    
    Write-Host "   4. Query data in Athena:" -ForegroundColor $Gray
    Write-Host "      SELECT * FROM `"$ProjectName-catalog-$Environment`".`"silver_car_telemetry`" LIMIT 10;`n" -ForegroundColor $Cyan
}

Write-Host " Upload concluído!`n" -ForegroundColor $Green
