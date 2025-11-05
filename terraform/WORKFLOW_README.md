# 🎯 AWS Glue Workflow - IaC Automation & Legacy Cleanup

**Data:** 05/11/2025  
**Status:** ✅ Pronto para Deploy  
**Objetivo:** Automação completa do pipeline Silver→Gold + Limpeza de recursos órfãos

---

## 📦 Artefatos Criados

### 1. **Workflow Automatizado** (`glue_workflow_main.tf`)
Orquestra pipeline completo com DAG condicional:

```
SCHEDULED (02:00 UTC) 
  → Silver Job (60s) 
    → Silver Crawler (15s) 
      → FAN-OUT: 3 Gold Jobs Paralelos (90s máx) 
        → 3 Gold Crawlers Paralelos (10s)
```

**Recursos:**
- 1x Workflow
- 6x Triggers (1 SCHEDULED + 5 CONDITIONAL)
- Processamento paralelo (economia de 51% no tempo)

### 2. **Limpeza de Recursos** (`legacy_cleanup.tf`)
Remove componentes órfãos identificados:

| Recurso | Tipo | Economia |
|---------|------|----------|
| `gold-performance-alerts-crawler` | Crawler | ~$2-5/mês |
| `gold-performance-alerts-dev` | Job | Limpeza |
| `silver-test-job` | Job | Limpeza |
| S3 órfãos | Storage | ~$0.50-2/mês |

---

## 🚀 Deploy Rápido

```powershell
cd C:\dev\HP\wsas\Poc\terraform

# 1. Inicializar
terraform init

# 2. Planejar
terraform plan -var-file="glue_workflow.tfvars"

# 3. Aplicar
terraform apply -var-file="glue_workflow.tfvars" -auto-approve

# 4. Validar
aws glue get-workflow --name datalake-pipeline-silver-gold-workflow-dev --region us-east-1
```

---

## 📚 Documentação

| Arquivo | Descrição |
|---------|-----------|
| **[DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md)** | Guia completo passo a passo ⭐ |
| `glue_workflow_main.tf` | Código Terraform (workflow + triggers) |
| `glue_workflow_variables.tf` | Variáveis |
| `glue_workflow.tfvars` | Configurações |
| `legacy_cleanup.tf` | Comandos de limpeza |

---

## ✅ Validação

Execute após deploy:

```powershell
# Workflow criado?
aws glue list-workflows --region us-east-1

# Triggers corretos?
aws glue list-triggers --region us-east-1 | jq '.TriggerNames[] | select(contains("silver-gold"))'

# Testar execução
aws glue start-workflow-run --name datalake-pipeline-silver-gold-workflow-dev --region us-east-1
```

**Consulte [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md) para instruções detalhadas.**
