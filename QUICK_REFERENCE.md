# ⚡ Quick Reference - Recuperação do Workflow

> **Referência rápida** para recuperação após atualizações Terraform

---

## 🚀 Recuperação Rápida (1 Comando)

```powershell
cd C:\dev\HP\wsas\Poc
.\scripts\Recover-Workflow.ps1
```

**Tempo estimado**: 4-5 minutos  
**Ações automáticas**: Bronze Crawler → Reset Bookmarks → Workflow → Validação

---

## 📋 Comandos Essenciais

### Verificar Status do Workflow
```powershell
aws glue get-workflow-runs `
  --name datalake-pipeline-silver-etl-workflow-dev `
  --max-results 1 `
  --query 'Runs[0].{Status:Status,Succeeded:Statistics.SucceededActions,Failed:Statistics.FailedActions}'
```

### Executar Bronze Crawler
```powershell
aws glue start-crawler --name datalake-pipeline-bronze-car-data-crawler-dev
Start-Sleep -Seconds 90
```

### Resetar Job Bookmarks
```powershell
aws glue reset-job-bookmark --job-name datalake-pipeline-silver-consolidation-dev
aws glue reset-job-bookmark --job-name datalake-pipeline-gold-car-current-state-dev
aws glue reset-job-bookmark --job-name datalake-pipeline-gold-performance-alerts-dev
```

### Iniciar Workflow
```powershell
aws glue start-workflow-run --name datalake-pipeline-silver-etl-workflow-dev
```

### Listar Tabelas
```powershell
aws glue get-tables --database-name datalake-pipeline-catalog-dev
```

---

## 🔧 Parâmetros do Script

| Comando | Descrição |
|---------|-----------|
| `.\scripts\Recover-Workflow.ps1` | Recuperação completa |
| `-SkipBronzeCrawler` | Pula Bronze Crawler |
| `-SkipBookmarkReset` | Não reseta bookmarks |
| `-AutoApprove` | Sem confirmação |
| `-WaitSeconds 60` | Reduz espera do Crawler |

---

## 🎯 Troubleshooting Rápido

### Erro: "Column does not exist"
```powershell
# Solução
aws glue start-crawler --name datalake-pipeline-bronze-car-data-crawler-dev
Start-Sleep -Seconds 90
aws glue reset-job-bookmark --job-name datalake-pipeline-silver-consolidation-dev
aws glue start-workflow-run --name datalake-pipeline-silver-etl-workflow-dev
```

### Erro: "AccessDeniedException: glue:BatchGetPartition"
```powershell
# Solução
cd terraform
terraform apply -auto-approve
Start-Sleep -Seconds 60
aws glue start-crawler --name datalake-pipeline-gold-performance-alerts-crawler-dev
```

### Job não processa dados novos
```powershell
# Solução
aws glue reset-job-bookmark --job-name <JOB_NAME>
aws glue start-job-run --job-name <JOB_NAME>
```

---

## ✅ Validação Rápida

```powershell
# 1. Verificar tabelas (esperado: 4 tabelas)
aws glue get-tables --database-name datalake-pipeline-catalog-dev --query 'TableList[*].Name'

# 2. Query Athena - Gold Current State
aws athena start-query-execution `
  --query-string "SELECT COUNT(*) FROM gold_car_current_state" `
  --query-execution-context Database=datalake-pipeline-catalog-dev `
  --result-configuration OutputLocation=s3://datalake-pipeline-athena-results-dev/

# 3. Query Athena - Performance Alerts
aws athena start-query-execution `
  --query-string "SELECT alert_type, COUNT(*) FROM performance_alerts_log GROUP BY alert_type" `
  --query-execution-context Database=datalake-pipeline-catalog-dev `
  --result-configuration OutputLocation=s3://datalake-pipeline-athena-results-dev/
```

---

## 📊 Status Esperado

**Workflow Saudável:**
```
Status: COMPLETED
✅ Succeeded: 6/6
❌ Failed: 0
📊 Total: 6
```

**Tabelas Esperadas:**
- `bronze_ingest_year_2025`
- `silver_car_telemetry`
- `gold_car_current_state`
- `performance_alerts_log`

---

## 📞 Documentação Completa

- 📖 **Guia Detalhado**: `WORKFLOW_RECOVERY_GUIDE.md`
- 📚 **Como Usar**: `RECOVERY_README.md`
- 🚀 **Script**: `scripts/Recover-Workflow.ps1`

---

**Última atualização**: 31/10/2025
