#!/bin/bash
# Build Script for Lambda Ingestion Function and Layer (Linux/Mac)
# This script creates the deployment packages for the ingestion Lambda and its dependencies

echo "========================================"
echo "Lambda Ingestion - Build Script"
echo "========================================"
echo ""

# Set paths
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAMBDA_DIR="${ROOT_DIR}/lambdas/ingestion"
BUILD_DIR="${ROOT_DIR}/build"
LAYER_BUILD_DIR="${BUILD_DIR}/layer/python"
ASSETS_DIR="${ROOT_DIR}/assets"

# Create necessary directories
echo "Creating build directories..."
mkdir -p "${BUILD_DIR}"
mkdir -p "${LAYER_BUILD_DIR}"
mkdir -p "${ASSETS_DIR}"

echo " Directories created"
echo ""

# Step 1: Create Lambda Function Package
echo "Step 1: Creating Lambda function package..."
echo "Source: ${LAMBDA_DIR}"

LAMBDA_PACKAGE="${ASSETS_DIR}/ingestion_package.zip"

# Remove old package if exists
if [ -f "${LAMBDA_PACKAGE}" ]; then
    rm -f "${LAMBDA_PACKAGE}"
    echo "  - Removed old package"
fi

# Create zip file with lambda function
cd "${LAMBDA_DIR}"
zip -q "${LAMBDA_PACKAGE}" lambda_function.py
cd "${ROOT_DIR}"

echo " Lambda package created: ingestion_package.zip"
echo ""

# Step 2: Install dependencies for Lambda Layer
echo "Step 2: Installing dependencies for Lambda Layer..."
echo "Installing pandas and pyarrow..."
echo "This may take a few minutes..."

# Install packages
pip install pandas pyarrow -t "${LAYER_BUILD_DIR}" --upgrade --quiet

if [ $? -eq 0 ]; then
    echo " Dependencies installed"
else
    echo " Error installing dependencies"
    exit 1
fi

echo ""

# Step 3: Create Lambda Layer Package
echo "Step 3: Creating Lambda Layer package..."

LAYER_PACKAGE="${ASSETS_DIR}/pandas_pyarrow_layer.zip"

# Remove old layer if exists
if [ -f "${LAYER_PACKAGE}" ]; then
    rm -f "${LAYER_PACKAGE}"
    echo "  - Removed old layer package"
fi

# Create zip file with dependencies
cd "${BUILD_DIR}/layer"
zip -r -q "${LAYER_PACKAGE}" python/
cd "${ROOT_DIR}"

echo " Layer package created: pandas_pyarrow_layer.zip"
echo ""

# Display package information
echo "========================================"
echo "Build Summary"
echo "========================================"

LAMBDA_SIZE=$(du -k "${LAMBDA_PACKAGE}" | cut -f1)
LAYER_SIZE=$(du -m "${LAYER_PACKAGE}" | cut -f1)

echo "Lambda Package:"
echo "  Location: ${LAMBDA_PACKAGE}"
echo "  Size: ${LAMBDA_SIZE} KB"
echo ""

echo "Layer Package:"
echo "  Location: ${LAYER_PACKAGE}"
echo "  Size: ${LAYER_SIZE} MB"
echo ""

# Cleanup option
echo "========================================"
echo ""
read -p "Do you want to clean up build directory? (y/N) " cleanup

if [ "$cleanup" = "y" ] || [ "$cleanup" = "Y" ]; then
    rm -rf "${BUILD_DIR}"
    echo " Build directory cleaned"
else
    echo "Build directory preserved at: ${BUILD_DIR}"
fi

echo ""
echo "========================================"
echo "Build completed successfully!"
echo "========================================"
echo ""
echo "Next steps:"
echo "1. cd terraform"
echo "2. terraform plan"
echo "3. terraform apply"
echo ""
