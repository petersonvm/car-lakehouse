# Build Script for Lambda Ingestion Function and Layer
# This script creates the deployment packages for the ingestion Lambda and its dependencies

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Lambda Ingestion - Build Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Set paths
$ROOT_DIR = $PSScriptRoot
$LAMBDA_DIR = Join-Path $ROOT_DIR "lambdas\ingestion"
$BUILD_DIR = Join-Path $ROOT_DIR "build"
$LAYER_BUILD_DIR = Join-Path $BUILD_DIR "layer\python"
$ASSETS_DIR = Join-Path $ROOT_DIR "assets"

# Create necessary directories
Write-Host "Creating build directories..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $BUILD_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $LAYER_BUILD_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $ASSETS_DIR | Out-Null

Write-Host "Directories created" -ForegroundColor Green
Write-Host ""

# Step 1: Create Lambda Function Package
Write-Host "Step 1: Creating Lambda function package..." -ForegroundColor Yellow
Write-Host "Source: $LAMBDA_DIR" -ForegroundColor Gray

$LAMBDA_PACKAGE = Join-Path $ASSETS_DIR "ingestion_package.zip"

# Remove old package if exists
if (Test-Path $LAMBDA_PACKAGE) {
    Remove-Item $LAMBDA_PACKAGE -Force
    Write-Host "  - Removed old package" -ForegroundColor Gray
}

# Create zip file with lambda function
Compress-Archive -Path (Join-Path $LAMBDA_DIR "lambda_function.py") -DestinationPath $LAMBDA_PACKAGE -Force

Write-Host "Lambda package created: ingestion_package.zip" -ForegroundColor Green
Write-Host ""

# Step 2: Install dependencies for Lambda Layer
Write-Host "Step 2: Installing dependencies for Lambda Layer..." -ForegroundColor Yellow
Write-Host "Installing pandas and pyarrow..." -ForegroundColor Gray
Write-Host "This may take a few minutes..." -ForegroundColor Gray

# Install packages
$installCommand = "pip install pandas pyarrow -t `"$LAYER_BUILD_DIR`" --upgrade --no-user"
Write-Host "  Running: $installCommand" -ForegroundColor Gray

try {
    Invoke-Expression $installCommand
    Write-Host "Dependencies installed" -ForegroundColor Green
} catch {
    Write-Host "Error installing dependencies: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Step 3: Create Lambda Layer Package
Write-Host "Step 3: Creating Lambda Layer package..." -ForegroundColor Yellow

$LAYER_PACKAGE = Join-Path $ASSETS_DIR "pandas_pyarrow_layer.zip"

# Remove old layer if exists
if (Test-Path $LAYER_PACKAGE) {
    Remove-Item $LAYER_PACKAGE -Force
    Write-Host "  - Removed old layer package" -ForegroundColor Gray
}

# Create zip file with dependencies (must include 'python' directory)
$layerDir = Join-Path $BUILD_DIR "layer"
Push-Location $layerDir
Compress-Archive -Path "python" -DestinationPath $LAYER_PACKAGE -Force
Pop-Location

if (Test-Path $LAYER_PACKAGE) {
    Write-Host "Layer package created: pandas_pyarrow_layer.zip" -ForegroundColor Green
} else {
    Write-Host "ERROR: Failed to create layer package!" -ForegroundColor Red
    exit 1
}
Write-Host ""

# Display package information
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Build Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$lambdaSize = (Get-Item $LAMBDA_PACKAGE).Length / 1KB

Write-Host "Lambda Package:" -ForegroundColor Yellow
Write-Host "  Location: $LAMBDA_PACKAGE" -ForegroundColor Gray
Write-Host "  Size: $([math]::Round($lambdaSize, 2)) KB" -ForegroundColor Gray
Write-Host ""

if (Test-Path $LAYER_PACKAGE) {
    $layerSize = (Get-Item $LAYER_PACKAGE).Length / 1MB
    Write-Host "Layer Package:" -ForegroundColor Yellow
    Write-Host "  Location: $LAYER_PACKAGE" -ForegroundColor Gray
    Write-Host "  Size: $([math]::Round($layerSize, 2)) MB" -ForegroundColor Gray
} else {
    Write-Host "Layer Package: NOT CREATED" -ForegroundColor Red
}
Write-Host ""

# Cleanup option
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
$cleanup = Read-Host "Do you want to clean up build directory? (y/N)"

if ($cleanup -eq "y" -or $cleanup -eq "Y") {
    Remove-Item $BUILD_DIR -Recurse -Force
    Write-Host "Build directory cleaned" -ForegroundColor Green
} else {
    Write-Host "Build directory preserved at: $BUILD_DIR" -ForegroundColor Gray
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Build completed successfully!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1. cd terraform" -ForegroundColor Gray
Write-Host "2. terraform plan" -ForegroundColor Gray
Write-Host "3. terraform apply" -ForegroundColor Gray
Write-Host ""
