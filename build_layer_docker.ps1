# Lambda Layer Build Script - Docker Version
# Uses AWS Lambda Python base image for Linux compatibility

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Lambda Layer Builder (Docker)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check if Docker is available
try {
    docker --version | Out-Null
    Write-Host "Check Docker is available" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Docker is not installed or not in PATH" -ForegroundColor Red
    Write-Host "Please install Docker Desktop from docker.com" -ForegroundColor Yellow
    exit 1
}

Write-Host ""

# Paths
$PROJECT_ROOT = $PSScriptRoot
$ASSETS_DIR = Join-Path $PROJECT_ROOT "assets"
$LAYER_PACKAGE = Join-Path $ASSETS_DIR "pandas_pyarrow_layer.zip"

# Ensure assets directory exists
if (-not (Test-Path $ASSETS_DIR)) {
    New-Item -ItemType Directory -Path $ASSETS_DIR -Force | Out-Null
}

Write-Host "Building Lambda Layer using Docker..." -ForegroundColor Cyan
Write-Host "This uses AWS Lambda Python 3.9 base image for Linux compatibility" -ForegroundColor Gray
Write-Host ""

# Remove old layer package
if (Test-Path $LAYER_PACKAGE) {
    Remove-Item $LAYER_PACKAGE -Force
}

# Build layer using Docker
Write-Host "Running Docker build..." -ForegroundColor Gray

# Using only minimal dependencies for Lambda Layer
# pyarrow < 10 is smaller and sufficient for Parquet operations
$dockerCmd = "docker run --rm -v `"${PROJECT_ROOT}:/workspace`" python:3.9-slim bash -c `"pip install 'pandas==1.5.3' 'pyarrow==9.0.0' 'numpy==1.23.5' -t /tmp/layer/python --no-cache-dir && cd /tmp/layer && apt-get update && apt-get install -y zip && zip -r9 /workspace/assets/pandas_pyarrow_layer.zip python`""

try {
    Invoke-Expression $dockerCmd
    if ($LASTEXITCODE -ne 0) {
        throw "Docker build failed with exit code $LASTEXITCODE"
    }
    Write-Host "Docker build completed" -ForegroundColor Green
} catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Verify layer package
if (Test-Path $LAYER_PACKAGE) {
    $layerSize = (Get-Item $LAYER_PACKAGE).Length / 1MB
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Build Summary" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Layer Package:" -ForegroundColor White
    Write-Host "  Location: $LAYER_PACKAGE" -ForegroundColor Gray
    Write-Host "  Size: $([math]::Round($layerSize, 2)) MB" -ForegroundColor Gray
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Build completed successfully!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "1. cd terraform" -ForegroundColor White
    Write-Host "2. terraform apply" -ForegroundColor White
} else {
    Write-Host "ERROR: Layer package was not created!" -ForegroundColor Red
    exit 1
}
