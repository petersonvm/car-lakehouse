#!/bin/bash
# Script para upload de dados de teste para o Car Lakehouse Pipeline
# Autor: Peterson VM
# Data: 06 de Novembro de 2025

# Configuração padrão
ENVIRONMENT="${1:-dev}"
PROJECT_NAME="${2:-datalake-pipeline}"
SAMPLE_FILE="${3:-all}"

# Cores para output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

# Configuração
LANDING_BUCKET="${PROJECT_NAME}-landing-${ENVIRONMENT}"
TEST_DATA_DIR="test_data"

echo -e "\n${GREEN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          🚀 UPLOAD DE DADOS DE TESTE - CAR LAKEHOUSE                ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════════╝${NC}\n"

echo -e "${CYAN}📋 CONFIGURAÇÃO:${NC}"
echo -e "${GRAY}   Landing Bucket: ${LANDING_BUCKET}${NC}"
echo -e "${GRAY}   Diretório: ${TEST_DATA_DIR}${NC}"
echo -e "${GRAY}   Arquivo(s): ${SAMPLE_FILE}${NC}\n"

# Verificar se diretório existe
if [ ! -d "$TEST_DATA_DIR" ]; then
    echo -e "${RED}❌ ERRO: Diretório '${TEST_DATA_DIR}' não encontrado!${NC}"
    echo -e "${RED}   Execute este script da raiz do projeto.${NC}\n"
    exit 1
fi

# Definir arquivos para upload
SUCCESS_COUNT=0
FAIL_COUNT=0

if [ "$SAMPLE_FILE" == "all" ]; then
    FILES=$(ls ${TEST_DATA_DIR}/sample_car_telemetry_*.json 2>/dev/null)
    FILE_COUNT=$(echo "$FILES" | wc -l)
else
    FILE_NAME="sample_car_telemetry_${SAMPLE_FILE}.json"
    FILE_PATH="${TEST_DATA_DIR}/${FILE_NAME}"
    
    if [ ! -f "$FILE_PATH" ]; then
        echo -e "${RED}❌ ERRO: Arquivo '${FILE_NAME}' não encontrado!${NC}"
        exit 1
    fi
    
    FILES="$FILE_PATH"
    FILE_COUNT=1
fi

echo -e "${YELLOW}📤 FAZENDO UPLOAD DE ${FILE_COUNT} ARQUIVO(S)...${NC}\n"

# Upload dos arquivos
for FILE in $FILES; do
    FILE_NAME=$(basename "$FILE")
    echo -ne "${GRAY}   Uploading: ${FILE_NAME}...${NC}"
    
    if aws s3 cp "$FILE" "s3://${LANDING_BUCKET}/" --only-show-errors; then
        echo -e " ${GREEN}✅${NC}"
        ((SUCCESS_COUNT++))
    else
        echo -e " ${RED}❌${NC}"
        ((FAIL_COUNT++))
    fi
done

echo -e "\n${CYAN}📊 RESULTADO:${NC}"
echo -e "${GREEN}   Sucesso: ${SUCCESS_COUNT} arquivo(s)${NC}"

if [ $FAIL_COUNT -gt 0 ]; then
    echo -e "${RED}   Falha: ${FAIL_COUNT} arquivo(s)${NC}"
else
    echo -e "${GRAY}   Falha: ${FAIL_COUNT} arquivo(s)${NC}"
fi

if [ $SUCCESS_COUNT -gt 0 ]; then
    echo -e "\n${YELLOW}✅ PRÓXIMOS PASSOS:${NC}"
    echo -e "${GRAY}   1. Verificar logs da Lambda Ingestion:${NC}"
    echo -e "${CYAN}      aws logs tail /aws/lambda/${PROJECT_NAME}-ingestion-${ENVIRONMENT} --follow${NC}\n"
    
    echo -e "${GRAY}   2. Verificar arquivos no Bronze:${NC}"
    echo -e "${CYAN}      aws s3 ls s3://${PROJECT_NAME}-bronze-${ENVIRONMENT}/bronze/car_data/ --recursive${NC}\n"
    
    echo -e "${GRAY}   3. Executar Workflow completo:${NC}"
    echo -e "${CYAN}      aws glue start-workflow-run --name ${PROJECT_NAME}-silver-gold-workflow-${ENVIRONMENT}${NC}\n"
    
    echo -e "${GRAY}   4. Consultar dados no Athena:${NC}"
    echo -e "${CYAN}      SELECT * FROM \\\"${PROJECT_NAME}-catalog-${ENVIRONMENT}\\\".\\\"silver_car_telemetry\\\" LIMIT 10;${NC}\n"
fi

echo -e "${GREEN}🎯 Upload concluído!${NC}\n"
