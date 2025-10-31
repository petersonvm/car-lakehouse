# 🔧 Guia de Recuperação do Workflow após Atualizações Terraform

> **Data de criação**: 31/10/2025  
> **Versão**: 1.0  
> **Aplicável a**: Workflow `datalake-pipeline-silver-etl-workflow-dev`

---

## 📋 Índice

1. [Visão Geral](#visão-geral)
2. [Sintomas Comuns](#sintomas-comuns)
3. [Procedimento de Recuperação](#procedimento-de-recuperação)
4. [Diagnóstico de Problemas](#diagnóstico-de-problemas)
5. [Prevenção de Problemas](#prevenção-de-problemas)
6. [Referência Rápida](#referência-rápida)

---

## 🎯 Visão Geral

Após aplicar atualizações no Terraform que afetam Jobs ou Crawlers do AWS Glue, é necessário executar um procedimento de recuperação para garantir que:

- **Schemas do catálogo estejam atualizados**
- **Job Bookmarks não causem conflitos**
- **Permissões IAM estejam propagadas**
- **Workflow execute end-to-end sem falhas**

---

## ⚠️ Sintomas Comuns

### Sintoma 1: Workflow com Falhas (FailedActions > 0)
```powershell
Status: COMPLETED
SucceededActions: 5
FailedActions: 1
```

### Sintoma 2: Erro "Column does not exist"
```
AnalysisException: Column 'metrics.engineTempCelsius' does not exist
```

### Sintoma 3: AccessDeniedException no Crawler
```
Service Principal: glue.amazonaws.com is not authorized to perform: 
glue:BatchGetPartition on resource
```

### Sintoma 4: Jobs não processam novos dados
- Job executa mas não gera saídas
- Tabelas Gold não atualizam
- Job Bookmarks desatualizados

---

## 🔄 Procedimento de Recuperação

### **PASSO 1: Verificar Status do Workflow**

```powershell
# Obter última execução do workflow
aws glue get-workflow-runs `
  --name datalake-pipeline-silver-etl-workflow-dev `
  --max-results 1 `
  --query 'Runs[0].{Status:Status,Succeeded:Statistics.SucceededActions,Failed:Statistics.FailedActions,Total:Statistics.TotalActions}' `
  --output table
```

**✅ Esperado**: Status=COMPLETED, Failed=0  
**❌ Problema**: Failed > 0 → Continue para Passo 2

---

### **PASSO 2: Executar Bronze Crawler**

> **⚠️ CRÍTICO**: Este passo é **OBRIGATÓRIO** após qualquer mudança que afete o schema Bronze ou após limpeza de ambiente.

```powershell
# Iniciar Bronze Crawler
Write-Host "`n🔄 PASSO 2: Executando Bronze Crawler..." -ForegroundColor Yellow
aws glue start-crawler --name datalake-pipeline-bronze-car-data-crawler-dev

# Aguardar conclusão (90 segundos é tempo médio)
Start-Sleep -Seconds 90

# Verificar status
aws glue get-crawler `
  --name datalake-pipeline-bronze-car-data-crawler-dev `
  --query 'Crawler.{Estado:State,UltimaExecucao:LastCrawl.Status}' `
  --output table
```

**✅ Esperado**: `Estado=READY`, `UltimaExecucao=SUCCEEDED`  
**❌ Problema**: `FAILED` → Verificar logs CloudWatch

**Por que este passo é necessário?**
- Atualiza schema das tabelas Bronze no Glue Catalog
- Garante que Jobs downstream consigam ler as colunas corretamente
- Resolve erros do tipo "Column does not exist"

---

### **PASSO 3: Resetar Job Bookmarks**

> **⚠️ ATENÇÃO**: Este passo faz com que os Jobs reprocessem **TODOS** os dados existentes. Use com cuidado em produção.

```powershell
Write-Host "`n🔄 PASSO 3: Resetando Job Bookmarks..." -ForegroundColor Yellow

# Resetar Silver Job
Write-Host "  → Silver Consolidation Job..." -ForegroundColor Cyan
aws glue reset-job-bookmark --job-name datalake-pipeline-silver-consolidation-dev

# Resetar Gold Current State Job
Write-Host "  → Gold Current State Job..." -ForegroundColor Cyan
aws glue reset-job-bookmark --job-name datalake-pipeline-gold-car-current-state-dev

# Resetar Gold Performance Alerts Job
Write-Host "  → Gold Performance Alerts Job..." -ForegroundColor Cyan
aws glue reset-job-bookmark --job-name datalake-pipeline-gold-performance-alerts-dev

Write-Host "`n✅ Bookmarks resetados!" -ForegroundColor Green
```

**✅ Esperado**: Mensagem de confirmação para cada job  
**⚠️ Nota**: Se o Job nunca foi executado, receberá erro `EntityNotFoundException` (normal, pode ignorar)

**Quando resetar Bookmarks?**
- ✅ Após mudanças no schema de entrada
- ✅ Após alterações na lógica de transformação do Job
- ✅ Quando Job não processa dados novos
- ❌ **NÃO** resetar em produção sem backup

---

### **PASSO 4: Verificar Permissões IAM (se aplicável)**

> Execute este passo **SOMENTE** se houver erros de `AccessDeniedException`.

```powershell
Write-Host "`n🔄 PASSO 4: Aplicando correções IAM..." -ForegroundColor Yellow

# Navegar para pasta terraform
cd C:\dev\HP\wsas\Poc\terraform

# Aplicar mudanças (se houver correções pendentes)
terraform apply -auto-approve

Write-Host "`n⏳ Aguardando propagação IAM (60 segundos)..." -ForegroundColor Cyan
Start-Sleep -Seconds 60
```

**Permissões comuns que precisam correção:**
- `glue:BatchGetPartition` (Crawlers)
- `glue:GetPartition` (Crawlers)
- `glue:BatchCreatePartition` (Jobs com particionamento)
- `s3:PutObject` (Jobs que escrevem dados)

**✅ Esperado**: `Apply complete! Resources: 0 added, X changed, 0 destroyed`

---

### **PASSO 5: Executar Workflow Completo**

```powershell
Write-Host "`n🚀 PASSO 5: Executando workflow completo..." -ForegroundColor Green

# Iniciar workflow
$runId = (aws glue start-workflow-run `
  --name datalake-pipeline-silver-etl-workflow-dev | ConvertFrom-Json).RunId

Write-Host "✅ Workflow iniciado!" -ForegroundColor Green
Write-Host "   Run ID: $runId" -ForegroundColor Cyan
Write-Host "`n⏳ Monitorando execução (3-4 minutos)..." -ForegroundColor Yellow
```

---

### **PASSO 6: Monitorar Execução**

```powershell
# Script de monitoramento automático
$runId = "SUBSTITUIR_PELO_RUN_ID"

for ($i = 1; $i -le 10; $i++) {
    Start-Sleep -Seconds 30
    
    $status = (aws glue get-workflow-run `
        --name datalake-pipeline-silver-etl-workflow-dev `
        --run-id $runId | ConvertFrom-Json).Run
    
    Write-Host "`n[$i] Status: $($status.Status)" -ForegroundColor Cyan
    Write-Host "    ✅ Sucesso: $($status.Statistics.SucceededActions)/$($status.Statistics.TotalActions)" -ForegroundColor Green
    Write-Host "    ❌ Falhas: $($status.Statistics.FailedActions)" -ForegroundColor $(if($status.Statistics.FailedActions -gt 0){'Red'}else{'Gray'})
    Write-Host "    🔄 Rodando: $($status.Statistics.RunningActions)" -ForegroundColor Yellow
    
    if ($status.Status -ne 'RUNNING') {
        Write-Host "`n🎉 Workflow finalizado!" -ForegroundColor Green
        break
    }
}
```

**✅ Sucesso Completo**: 
```
Status: COMPLETED
✅ Sucesso: 6/6
❌ Falhas: 0
```

**❌ Se houver falhas**: Continue para [Diagnóstico de Problemas](#diagnóstico-de-problemas)

---

### **PASSO 7: Validar Tabelas Catalogadas**

```powershell
Write-Host "`n📊 PASSO 7: Validando tabelas catalogadas..." -ForegroundColor Cyan

aws glue get-tables `
  --database-name datalake-pipeline-catalog-dev `
  --query 'TableList[*].{Tabela:Name,Criada:CreateTime,Atualizada:UpdateTime}' `
  --output table
```

**✅ Esperado - 4 Tabelas**:
```
┌───────────────────────────────┐
│ bronze_ingest_year_2025       │
│ silver_car_telemetry          │
│ gold_car_current_state        │
│ performance_alerts_log        │ ← NOVA!
└───────────────────────────────┘
```

---

### **PASSO 8: Testar Queries no Athena**

```powershell
Write-Host "`n🔍 PASSO 8: Testando queries Athena..." -ForegroundColor Cyan

# Query 1: Verificar Gold Current State
$query1 = "SELECT carChassis, currentMileage FROM gold_car_current_state LIMIT 5"

# Query 2: Verificar Performance Alerts
$query2 = "SELECT alert_type, COUNT(*) as total FROM performance_alerts_log GROUP BY alert_type"

# Executar Query 2 (Alerts)
$queryId = (aws athena start-query-execution `
    --query-string $query2 `
    --query-execution-context Database=datalake-pipeline-catalog-dev `
    --result-configuration OutputLocation=s3://datalake-pipeline-athena-results-dev/query-results/ `
    --work-group datalake-pipeline-workgroup-dev | ConvertFrom-Json).QueryExecutionId

Start-Sleep -Seconds 8

aws athena get-query-results `
    --query-execution-id $queryId `
    --query 'ResultSet.Rows[*].Data[*].VarCharValue' `
    --output table
```

**✅ Esperado**: Resultados com alertas detectados (OVERHEAT_ENGINE, OVERHEAT_OIL, SPEEDING_ALERT)

---

## 🔍 Diagnóstico de Problemas

### Problema 1: "Column does not exist"

**Causa**: Schema do catálogo desatualizado

**Solução**:
```powershell
# 1. Executar Bronze Crawler
aws glue start-crawler --name datalake-pipeline-bronze-car-data-crawler-dev
Start-Sleep -Seconds 90

# 2. Resetar Job Bookmark do Silver
aws glue reset-job-bookmark --job-name datalake-pipeline-silver-consolidation-dev

# 3. Reexecutar workflow
aws glue start-workflow-run --name datalake-pipeline-silver-etl-workflow-dev
```

---

### Problema 2: AccessDeniedException (glue:BatchGetPartition)

**Causa**: Política IAM do Crawler sem permissões necessárias

**Solução**:
```powershell
# 1. Verificar arquivo terraform
# Editar: terraform/glue_gold_alerts.tf (ou arquivo correspondente)
# Adicionar na política do Crawler:
#   - glue:GetPartition
#   - glue:BatchGetPartition

# 2. Aplicar mudança
cd terraform
terraform apply -auto-approve

# 3. Aguardar propagação IAM
Start-Sleep -Seconds 60

# 4. Executar crawler novamente
aws glue start-crawler --name <NOME_DO_CRAWLER>
```

**Permissões necessárias no Crawler**:
```json
{
  "Action": [
    "glue:GetDatabase",
    "glue:CreateTable",
    "glue:UpdateTable",
    "glue:GetTable",
    "glue:GetPartitions",
    "glue:GetPartition",          ← ADICIONAR
    "glue:BatchGetPartition",     ← ADICIONAR
    "glue:CreatePartition",
    "glue:UpdatePartition",
    "glue:BatchCreatePartition"
  ]
}
```

---

### Problema 3: Job não processa dados novos

**Causa**: Job Bookmarks travados em posição antiga

**Solução**:
```powershell
# Resetar bookmark do job específico
aws glue reset-job-bookmark --job-name <NOME_DO_JOB>

# Reexecutar job
aws glue start-job-run --job-name <NOME_DO_JOB>
```

---

### Problema 4: Crawler falha silenciosamente

**Causa**: Dados não existem no S3 ou path incorreto

**Verificação**:
```powershell
# Verificar dados no S3
aws s3 ls s3://datalake-pipeline-bronze-dev/bronze/car_data/ --recursive

# Verificar configuração do Crawler
aws glue get-crawler --name datalake-pipeline-bronze-car-data-crawler-dev `
  --query 'Crawler.Targets.S3Targets[*].Path'
```

**Solução**: Certifique-se de que há arquivos Parquet no path configurado

---

### Problema 5: Workflow trava em "RUNNING"

**Causa**: Job ou Crawler travado

**Diagnóstico**:
```powershell
# Ver detalhes completos do workflow run
aws glue get-workflow-run `
  --name datalake-pipeline-silver-etl-workflow-dev `
  --run-id <RUN_ID> `
  --include-graph
```

**Solução**:
```powershell
# Parar workflow travado
aws glue stop-workflow-run `
  --name datalake-pipeline-silver-etl-workflow-dev `
  --run-id <RUN_ID>

# Reiniciar
aws glue start-workflow-run --name datalake-pipeline-silver-etl-workflow-dev
```

---

## 🛡️ Prevenção de Problemas

### ✅ Checklist Antes de Atualizar Terraform

- [ ] Fazer backup das configurações atuais
- [ ] Executar `terraform plan` e revisar mudanças
- [ ] Verificar se há mudanças em schemas ou políticas IAM
- [ ] Ter dados de teste prontos para validação
- [ ] Documentar Run IDs antes da atualização

### ✅ Checklist Após Aplicar Terraform

- [ ] Executar Bronze Crawler
- [ ] Resetar Job Bookmarks (se necessário)
- [ ] Aguardar propagação IAM (60s)
- [ ] Executar workflow completo
- [ ] Validar todas as tabelas catalogadas
- [ ] Testar queries no Athena
- [ ] Verificar logs CloudWatch

### 📝 Logs CloudWatch

**Locations**:
```
/aws-glue/jobs/datalake-pipeline-silver-consolidation-dev
/aws-glue/jobs/datalake-pipeline-gold-car-current-state-dev
/aws-glue/jobs/datalake-pipeline-gold-performance-alerts-dev
/aws-glue/crawlers
```

**Como acessar**:
```powershell
# Ver últimos logs de um Job
aws logs tail /aws-glue/jobs/datalake-pipeline-silver-consolidation-dev --follow
```

---

## 📚 Referência Rápida

### Comandos Essenciais

```powershell
# 1. STATUS DO WORKFLOW
aws glue get-workflow-runs --name datalake-pipeline-silver-etl-workflow-dev --max-results 1

# 2. EXECUTAR BRONZE CRAWLER
aws glue start-crawler --name datalake-pipeline-bronze-car-data-crawler-dev

# 3. RESETAR JOB BOOKMARK
aws glue reset-job-bookmark --job-name <JOB_NAME>

# 4. INICIAR WORKFLOW
aws glue start-workflow-run --name datalake-pipeline-silver-etl-workflow-dev

# 5. LISTAR TABELAS
aws glue get-tables --database-name datalake-pipeline-catalog-dev

# 6. VERIFICAR DADOS S3
aws s3 ls s3://datalake-pipeline-bronze-dev/ --recursive
```

### Sequência de Recuperação Rápida

```powershell
# MODO EXPRESS (todos os passos em sequência)
Write-Host "🔄 INICIANDO RECUPERAÇÃO AUTOMÁTICA..." -ForegroundColor Yellow

# 1. Bronze Crawler
aws glue start-crawler --name datalake-pipeline-bronze-car-data-crawler-dev
Start-Sleep -Seconds 90

# 2. Reset Bookmarks
aws glue reset-job-bookmark --job-name datalake-pipeline-silver-consolidation-dev
aws glue reset-job-bookmark --job-name datalake-pipeline-gold-car-current-state-dev
aws glue reset-job-bookmark --job-name datalake-pipeline-gold-performance-alerts-dev

# 3. Executar Workflow
$runId = (aws glue start-workflow-run --name datalake-pipeline-silver-etl-workflow-dev | ConvertFrom-Json).RunId

Write-Host "`n✅ Recuperação iniciada!" -ForegroundColor Green
Write-Host "Run ID: $runId" -ForegroundColor Cyan
Write-Host "Aguarde 3-4 minutos para conclusão..." -ForegroundColor Yellow
```

---

## 🎯 Troubleshooting por Componente

### Bronze Layer
| Problema | Comando Diagnóstico | Solução |
|----------|---------------------|---------|
| Dados não aparecem | `aws s3 ls s3://...bronze/` | Executar Lambda ingestion |
| Schema incorreto | `aws glue get-table --name bronze_*` | Executar Bronze Crawler |
| Crawler falha | `aws glue get-crawler --name ...` | Verificar logs CloudWatch |

### Silver Layer
| Problema | Comando Diagnóstico | Solução |
|----------|---------------------|---------|
| Column not found | Ver logs do Silver Job | Executar Bronze Crawler + Reset Bookmark |
| Job não processa | `aws glue get-job-bookmark --job-name ...` | Resetar Job Bookmark |
| Partições vazias | `aws s3 ls s3://...silver/` | Verificar Silver Job logs |

### Gold Layer
| Problema | Comando Diagnóstico | Solução |
|----------|---------------------|---------|
| Dados desatualizados | Verificar última execução | Resetar bookmark + reexecutar |
| Crawler AccessDenied | Ver erro do Crawler | Corrigir política IAM |
| Jobs não executam em paralelo | Ver workflow graph | Verificar trigger configuration |

---

## 📞 Contatos e Recursos

- **AWS Glue Documentation**: https://docs.aws.amazon.com/glue/
- **Terraform AWS Provider**: https://registry.terraform.io/providers/hashicorp/aws/
- **CloudWatch Logs Console**: https://console.aws.amazon.com/cloudwatch/

---

## 📝 Histórico de Atualizações

| Data | Versão | Mudanças |
|------|--------|----------|
| 2025-10-31 | 1.0 | Versão inicial - Procedimento de recuperação após atualização Gold Alerts |

---

## ✅ Checklist de Validação Final

Após completar todos os passos, valide:

- [ ] **Workflow Status**: COMPLETED com 6/6 ações sucesso
- [ ] **Tabelas Bronze**: `bronze_ingest_year_*` atualizada
- [ ] **Tabelas Silver**: `silver_car_telemetry` atualizada
- [ ] **Tabelas Gold**: `gold_car_current_state` atualizada
- [ ] **Tabelas Gold**: `performance_alerts_log` criada
- [ ] **Athena Queries**: Retornam dados corretos
- [ ] **Logs CloudWatch**: Sem erros críticos
- [ ] **Execução Paralela**: Ambos Gold Jobs executaram simultaneamente

---

**🎉 Se todos os itens estiverem ✅, seu ambiente está 100% operacional!**
