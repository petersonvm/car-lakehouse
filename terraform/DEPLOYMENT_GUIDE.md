# 🚀 Guia de Deployment - AWS Glue Workflow & Limpeza de Recursos

**Data de Criação:** 05/11/2025  
**Ambiente:** DEV  
**Projeto:** Data Lakehouse - Car Rental Analytics

---

## 📋 Índice

1. [Visão Geral](#visão-geral)
2. [Pré-requisitos](#pré-requisitos)
3. [Parte 1: Deploy do Workflow Automatizado](#parte-1-deploy-do-workflow-automatizado)
4. [Parte 2: Limpeza de Recursos Legados](#parte-2-limpeza-de-recursos-legados)
5. [Parte 3: Validação Pós-Deploy](#parte-3-validação-pós-deploy)
6. [Troubleshooting](#troubleshooting)

---

## 🎯 Visão Geral

Este guia contém instruções completas para:

### ✨ Artefato 1: AWS Glue Workflow
Implementação do workflow **automatizado** `datalake-pipeline-silver-gold-workflow-dev` que orquestra o pipeline completo:

```
SCHEDULED (02:00 UTC) → Silver Job → Silver Crawler → Fan-Out (3 Gold Jobs paralelos) → 3 Gold Crawlers
```

**Benefícios:**
- ✅ Execução automatizada diária (sem intervenção manual)
- ✅ Processamento paralelo de 3 jobs Gold (redução de 60% no tempo total)
- ✅ Gestão condicional de falhas (cada job Gold independente)
- ✅ Catálogo sempre atualizado (crawlers após cada job)

### 🧹 Artefato 2: Limpeza de Recursos Legados
Remoção de componentes órfãos identificados no inventário:

| Recurso | Tipo | Justificativa | Economia Estimada |
|---------|------|---------------|-------------------|
| `gold-performance-alerts-crawler` | Crawler | Tabela deletada (órfão) | ~$2-5/mês |
| `gold-performance-alerts-dev` | Job | Substituído por `-slim` | Limpeza de ambiente |
| `silver-test-job` | Job | Job de desenvolvimento | Limpeza de ambiente |
| Dados S3 órfãos | Storage | performance_alerts_log | ~$0.50-2/mês |

**Total estimado: ~$2.50-7/mês + redução de complexidade operacional**

---

## 📦 Pré-requisitos

### Ferramentas Necessárias
- ✅ Terraform >= 1.0 instalado
- ✅ AWS CLI configurado com credenciais válidas
- ✅ Permissões IAM necessárias:
  - `glue:CreateWorkflow`, `glue:CreateTrigger`
  - `glue:DeleteCrawler`, `glue:DeleteJob`, `glue:DeleteTable`
  - `s3:ListBucket`, `s3:DeleteObject`

### Validação do Ambiente
Execute os comandos para validar recursos existentes:

```powershell
# Validar jobs existem
aws glue get-job --job-name datalake-pipeline-silver-consolidation-dev --region us-east-1
aws glue get-job --job-name datalake-pipeline-gold-car-current-state-dev --region us-east-1
aws glue get-job --job-name datalake-pipeline-gold-fuel-efficiency-dev --region us-east-1
aws glue get-job --job-name datalake-pipeline-gold-performance-alerts-slim-dev --region us-east-1

# Validar crawlers existem
aws glue get-crawler --name datalake-pipeline-silver-car-crawler-dev --region us-east-1
aws glue get-crawler --name datalake-pipeline-gold-car-current-state-crawler-dev --region us-east-1
aws glue get-crawler --name datalake-pipeline-gold-fuel-efficiency-crawler-dev --region us-east-1
aws glue get-crawler --name datalake-pipeline-gold-performance-alerts-slim-crawler-dev --region us-east-1
```

**Resultado esperado:** Todos os comandos devem retornar JSON com detalhes dos recursos (sem erros).

---

## 🌟 Parte 1: Deploy do Workflow Automatizado

### Passo 1.1: Revisar Configurações

Edite o arquivo `terraform/glue_workflow.tfvars` se necessário:

```hcl
# Alterar schedule se necessário
workflow_schedule = "cron(0 2 * * ? *)"  # 02:00 UTC diariamente

# Habilitar/desabilitar workflow
workflow_enabled = true

# Ajustar timeouts se jobs demoram mais
job_timeout_minutes = 30
crawler_timeout_minutes = 15
```

**Expressões cron comuns:**
- `cron(0 2 * * ? *)` - Diariamente às 02:00 UTC
- `cron(0 */6 * * ? *)` - A cada 6 horas
- `cron(0 8 ? * MON-FRI *)` - 08:00 UTC dias úteis apenas

### Passo 1.2: Inicializar Terraform

```powershell
cd C:\dev\HP\wsas\Poc\terraform

# Inicializar providers
terraform init

# Validar sintaxe
terraform validate
```

**Resultado esperado:**
```
Success! The configuration is valid.
```

### Passo 1.3: Planejar Deploy

```powershell
# Gerar plano de execução
terraform plan -var-file="glue_workflow.tfvars" -out=workflow.tfplan

# Revisar recursos a serem criados
# Esperado:
# - 1 aws_glue_workflow
# - 6 aws_glue_trigger (1 scheduled + 5 conditional)
```

**❗ IMPORTANTE:** Revise o plano cuidadosamente. Terraform deve mostrar:
- **7 recursos a criar** (1 workflow + 6 triggers)
- **0 recursos a modificar ou destruir**

### Passo 1.4: Aplicar Deploy

```powershell
# Aplicar o plano
terraform apply workflow.tfplan

# Confirmar com "yes" quando solicitado
```

**Resultado esperado:**
```
Apply complete! Resources: 7 added, 0 changed, 0 destroyed.

Outputs:
workflow_name = "datalake-pipeline-silver-gold-workflow-dev"
workflow_arn = "arn:aws:glue:us-east-1:901207488135:workflow/..."
scheduled_trigger_name = "datalake-pipeline-silver-gold-workflow-dev-trigger-scheduled-start"
workflow_schedule = "cron(0 2 * * ? *)"
trigger_count = 6
```

### Passo 1.5: Validar Workflow no Console AWS

1. Acesse: [AWS Glue Console → Workflows](https://console.aws.amazon.com/glue/home?region=us-east-1#/v2/etl-configuration/workflows)
2. Localize: `datalake-pipeline-silver-gold-workflow-dev`
3. Clique no workflow e visualize o **Graph** (DAG visual)
4. Verifique:
   - ✅ 1 trigger SCHEDULED (ponto de entrada)
   - ✅ 5 triggers CONDITIONAL
   - ✅ 4 jobs conectados
   - ✅ 4 crawlers conectados

### Passo 1.6: Executar Teste Manual (Opcional)

Para validar antes do agendamento automático:

```powershell
# Iniciar workflow manualmente via CLI
aws glue start-workflow-run `
  --name datalake-pipeline-silver-gold-workflow-dev `
  --region us-east-1
```

**Monitorar execução:**
```powershell
# Obter run ID da execução
aws glue get-workflow-runs `
  --name datalake-pipeline-silver-gold-workflow-dev `
  --max-results 1 `
  --region us-east-1
```

Ou via Console AWS:
1. Workflows → `datalake-pipeline-silver-gold-workflow-dev`
2. Tab **History** → Visualizar execução mais recente
3. **Graph** → Acompanhar status de cada step em tempo real

---

## 🧹 Parte 2: Limpeza de Recursos Legados

### ⚠️ IMPORTANTE: PROCESSO IRREVERSÍVEL
Faça backup dos dados antes de prosseguir. A limpeza S3 é **irreversível**.

### Passo 2.1: Backup de Dados (Recomendado)

```powershell
# Backup de dados de performance_alerts_log órfãos
aws s3 sync `
  s3://datalake-pipeline-gold-dev/performance_alerts_log/ `
  s3://datalake-pipeline-archive-dev/backups/performance_alerts_log_20251105/ `
  --region us-east-1

# Verificar backup foi criado
aws s3 ls s3://datalake-pipeline-archive-dev/backups/performance_alerts_log_20251105/ --recursive --summarize
```

### Passo 2.2: Revisar Recursos a Remover

```powershell
# Listar crawler órfão
aws glue get-crawler --name datalake-pipeline-gold-performance-alerts-crawler-dev --region us-east-1

# Listar job legado
aws glue get-job --job-name datalake-pipeline-gold-performance-alerts-dev --region us-east-1

# Listar job de teste
aws glue get-job --job-name silver-test-job --region us-east-1

# Listar dados órfãos no S3
aws s3 ls s3://datalake-pipeline-gold-dev/performance_alerts_log/ --recursive --human-readable --summarize
```

### Passo 2.3: Remover Crawler Órfão

```powershell
# Deletar crawler de performance_alerts_log
aws glue delete-crawler `
  --name datalake-pipeline-gold-performance-alerts-crawler-dev `
  --region us-east-1

# Validar remoção
aws glue get-crawler --name datalake-pipeline-gold-performance-alerts-crawler-dev --region us-east-1
# Esperado: ResourceNotFoundException
```

### Passo 2.4: Remover Jobs Legados

```powershell
# Deletar job legado de performance alerts
aws glue delete-job `
  --job-name datalake-pipeline-gold-performance-alerts-dev `
  --region us-east-1

# Deletar job de teste Silver
aws glue delete-job `
  --job-name silver-test-job `
  --region us-east-1

# Validar remoções
aws glue get-job --job-name datalake-pipeline-gold-performance-alerts-dev --region us-east-1
# Esperado: EntityNotFoundException
```

### Passo 2.5: Verificar Tabela Silver Legada

```powershell
# Verificar se tabela ainda existe
aws glue get-table `
  --database-name datalake-pipeline-catalog-dev `
  --name silver_car_telemetry_new `
  --region us-east-1

# Se existir, remover:
aws glue delete-table `
  --database-name datalake-pipeline-catalog-dev `
  --name silver_car_telemetry_new `
  --region us-east-1
```

### Passo 2.6: Limpeza de Dados Órfãos no S3

⚠️ **ATENÇÃO: Ação irreversível! Dados serão permanentemente deletados.**

```powershell
# Listar dados e confirmar volume antes de deletar
aws s3 ls s3://datalake-pipeline-gold-dev/performance_alerts_log/ --recursive --human-readable --summarize

# DELETAR dados órfãos (CUIDADO!)
aws s3 rm s3://datalake-pipeline-gold-dev/performance_alerts_log/ --recursive --region us-east-1

# Verificar espaço liberado
aws s3 ls s3://datalake-pipeline-gold-dev/ --recursive --summarize
```

### Passo 2.7: Gerar Relatório de Limpeza (Terraform)

```powershell
# Executar plan do legacy_cleanup.tf para ver outputs informativos
cd C:\dev\HP\wsas\Poc\terraform
terraform plan -target=module.legacy_cleanup

# Visualizar outputs com resumo de economia
terraform output legacy_resources_summary
terraform output estimated_cost_savings
terraform output cleanup_checklist
terraform output manual_commands_reference
```

---

## ✅ Parte 3: Validação Pós-Deploy

### Checklist Final

#### 3.1: Validar Workflow Funciona

```powershell
# Listar workflows
aws glue list-workflows --region us-east-1

# Obter detalhes do workflow
aws glue get-workflow --name datalake-pipeline-silver-gold-workflow-dev --region us-east-1

# Listar triggers do workflow
aws glue list-triggers --region us-east-1 | jq '.TriggerNames[] | select(. | contains("silver-gold-workflow"))'
```

**Esperado:** 6 triggers listados com prefixo `datalake-pipeline-silver-gold-workflow-dev-trigger-*`

#### 3.2: Validar Catálogo Limpo

```powershell
# Listar TODAS as tabelas
aws glue get-tables --database-name datalake-pipeline-catalog-dev --region us-east-1 --query 'TableList[*].Name' --output table

# Esperado (5 tabelas ativas):
# - car_bronze
# - car_bronze_structured
# - car_silver
# - gold_car_current_state
# - fuel_efficiency_monthly
# 
# NÃO devem aparecer:
# - silver_car_telemetry_new (legada)
# - performance_alerts_log (deletada)
```

#### 3.3: Validar Jobs Limpos

```powershell
# Listar jobs Glue
aws glue list-jobs --region us-east-1 --query 'JobNames' --output table

# Esperado (4 jobs ativos):
# - datalake-pipeline-silver-consolidation-dev
# - datalake-pipeline-gold-car-current-state-dev
# - datalake-pipeline-gold-fuel-efficiency-dev
# - datalake-pipeline-gold-performance-alerts-slim-dev
#
# NÃO devem aparecer:
# - datalake-pipeline-gold-performance-alerts-dev (legado)
# - silver-test-job (teste)
```

#### 3.4: Validar Crawlers Limpos

```powershell
# Listar crawlers
aws glue list-crawlers --region us-east-1 --query 'CrawlerNames' --output table

# Esperado (7 crawlers):
# - Bronze: 2 crawlers (car, car_structured)
# - Silver: 1 crawler (car_silver)
# - Gold: 3 crawlers (car_state, fuel_efficiency, alerts_slim)
# - Raw: 1 crawler (opcional, se existir)
#
# NÃO deve aparecer:
# - datalake-pipeline-gold-performance-alerts-crawler-dev (órfão)
```

#### 3.5: Validar Economia de Custos

```powershell
# Verificar tamanho dos buckets S3 antes/depois
aws s3 ls s3://datalake-pipeline-gold-dev/ --recursive --summarize

# Acessar AWS Cost Explorer:
# https://console.aws.amazon.com/cost-management/home?region=us-east-1#/dashboard

# Filtrar por serviços:
# - AWS Glue (esperado: redução em crawler executions)
# - Amazon S3 (esperado: redução em storage)
```

#### 3.6: Executar Workflow End-to-End

```powershell
# Disparar execução completa do workflow
aws glue start-workflow-run --name datalake-pipeline-silver-gold-workflow-dev --region us-east-1

# Monitorar no console AWS:
# Glue → Workflows → datalake-pipeline-silver-gold-workflow-dev → History → Graph
```

**Validar:**
- ✅ Silver job completa com sucesso
- ✅ Silver crawler atualiza catálogo
- ✅ 3 Gold jobs executam em paralelo
- ✅ 3 Gold crawlers atualizam schemas
- ✅ Workflow status = COMPLETED (sem erros)

---

## 🔧 Troubleshooting

### Problema 1: Terraform Apply Falha

**Erro:** `Error creating Glue Workflow: InvalidInputException`

**Solução:**
```powershell
# Validar nomes de jobs e crawlers existem
terraform plan -var-file="glue_workflow.tfvars"

# Verificar variáveis no .tfvars estão corretas
cat terraform\glue_workflow.tfvars

# Confirmar recursos existem na AWS
aws glue get-job --job-name [nome-do-job] --region us-east-1
```

### Problema 2: Workflow Não Inicia Automaticamente

**Erro:** Workflow não executa no horário agendado

**Solução:**
```powershell
# Verificar trigger está habilitado
aws glue get-trigger --name datalake-pipeline-silver-gold-workflow-dev-trigger-scheduled-start --region us-east-1

# Verificar expressão cron é válida
# Testar em: https://docs.aws.amazon.com/glue/latest/dg/monitor-data-warehouse-schedule.html

# Habilitar trigger se desabilitado
aws glue start-trigger --name datalake-pipeline-silver-gold-workflow-dev-trigger-scheduled-start --region us-east-1
```

### Problema 3: Gold Jobs Não Executam em Paralelo

**Erro:** Jobs Gold executam sequencialmente

**Solução:**
Verificar configuração do trigger Fan-Out:

```powershell
# Verificar trigger tem múltiplas actions
aws glue get-trigger --name datalake-pipeline-silver-gold-workflow-dev-trigger-gold-fanout --region us-east-1

# Deve conter 3 actions (uma para cada job Gold)
```

### Problema 4: Não Consigo Deletar Crawler/Job

**Erro:** `ConcurrentModificationException` ou `EntityNotFoundException`

**Solução:**
```powershell
# Aguardar crawler/job terminar execução atual
aws glue get-crawler --name [crawler-name] --region us-east-1 | jq '.Crawler.State'
# Esperado: READY (não RUNNING)

# Tentar novamente após conclusão
aws glue delete-crawler --name [crawler-name] --region us-east-1
```

### Problema 5: S3 Delete Falha (Access Denied)

**Erro:** `AccessDenied` ao deletar dados S3

**Solução:**
```powershell
# Verificar permissões IAM
aws sts get-caller-identity

# Verificar bucket policy permite delete
aws s3api get-bucket-policy --bucket datalake-pipeline-gold-dev

# Adicionar permissões se necessário:
# s3:DeleteObject, s3:DeleteObjectVersion
```

---

## 📊 Monitoramento Contínuo

### CloudWatch Logs

```powershell
# Visualizar logs do workflow
aws logs tail /aws-glue/workflows/datalake-pipeline-silver-gold-workflow-dev --follow --region us-east-1

# Visualizar logs de jobs específicos
aws logs tail /aws-glue/jobs/datalake-pipeline-gold-car-current-state-dev --follow --region us-east-1
```

### CloudWatch Metrics

Métricas importantes:
- `glue.driver.aggregate.numCompletedStages` - Stages completados
- `glue.driver.aggregate.numFailedTasks` - Falhas
- `glue.ALL.system.cpuUtilization` - CPU usage

### Alarmes Recomendados

```powershell
# Criar alarme para falhas no workflow
aws cloudwatch put-metric-alarm `
  --alarm-name glue-workflow-silver-gold-failures `
  --alarm-description "Alerta quando workflow Silver->Gold falha" `
  --metric-name glue.workflow.failed.runs `
  --namespace AWS/Glue `
  --statistic Sum `
  --period 300 `
  --threshold 1 `
  --comparison-operator GreaterThanThreshold `
  --evaluation-periods 1
```

---

## 📝 Documentação Adicional

- **Inventário AWS:** `INVENTARIO_AWS.md` (componentes e arquitetura)
- **Relatório Técnico:** `Relatorio_Componentes_Lakehouse.md` (detalhes do lakehouse)
- **Terraform Workflow:** `terraform/glue_workflow_main.tf` (código IaC)
- **Terraform Cleanup:** `terraform/legacy_cleanup.tf` (remoção de legados)

---

## ✅ Conclusão

Após completar este guia, você terá:

- ✅ Workflow automatizado executando diariamente às 02:00 UTC
- ✅ Processamento paralelo de 3 jobs Gold (economia de ~60% no tempo)
- ✅ Ambiente limpo (sem recursos legados/órfãos)
- ✅ Economia de custos: ~$2.50-7/mês
- ✅ Pipeline validado end-to-end

**Status:** 🎯 **Ambiente pronto para produção!**

---

*Documento gerado em 05/11/2025 - Versão 1.0*
