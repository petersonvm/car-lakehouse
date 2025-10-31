# 📚 Documentação de Recuperação do Workflow

Este diretório contém recursos para recuperação e troubleshooting do workflow AWS Glue após atualizações Terraform.

---

## 📄 Arquivos Disponíveis

### 1. **WORKFLOW_RECOVERY_GUIDE.md** 
📖 **Guia Completo de Recuperação**

Documentação detalhada com:
- ✅ Procedimento passo a passo de recuperação
- 🔍 Diagnóstico de problemas comuns
- 💡 Soluções para cada tipo de erro
- 📊 Comandos de validação e monitoramento
- 🛡️ Checklist de prevenção

**Quando usar:**
- Primeira vez configurando recuperação
- Troubleshooting de problemas específicos
- Referência para entender cada etapa
- Documentação de procedimentos

---

### 2. **Recover-Workflow.ps1**
🚀 **Script PowerShell Automatizado**

Script completo que executa TODO o procedimento de recuperação automaticamente.

**Recursos:**
- ✅ Execução automática dos 5 passos principais
- 📊 Monitoramento em tempo real com barra de progresso
- 🎨 Interface colorida e informativa
- ⚙️ Parâmetros configuráveis
- 🔍 Validação completa ao final

---

## 🚀 Como Usar

### Opção 1: Recuperação Automática Completa (RECOMENDADO)

```powershell
# Navegar para a pasta do projeto
cd C:\dev\HP\wsas\Poc

# Executar script de recuperação
.\scripts\Recover-Workflow.ps1
```

O script irá:
1. ✅ Verificar status atual
2. 🔄 Executar Bronze Crawler
3. 🔖 Resetar Job Bookmarks
4. 🚀 Executar workflow completo
5. 👀 Monitorar execução em tempo real
6. ✅ Validar tabelas catalogadas
7. 📊 Exibir resumo final

---

### Opção 2: Recuperação com Parâmetros Personalizados

```powershell
# Pular Bronze Crawler (se já foi executado recentemente)
.\scripts\Recover-Workflow.ps1 -SkipBronzeCrawler

# Pular reset de bookmarks (manter histórico)
.\scripts\Recover-Workflow.ps1 -SkipBookmarkReset

# Execução rápida sem confirmações
.\scripts\Recover-Workflow.ps1 -AutoApprove

# Reduzir tempo de espera do Crawler
.\scripts\Recover-Workflow.ps1 -WaitSeconds 60

# Combinação de parâmetros
.\scripts\Recover-Workflow.ps1 -SkipBronzeCrawler -AutoApprove
```

#### Parâmetros Disponíveis:

| Parâmetro | Tipo | Descrição | Padrão |
|-----------|------|-----------|--------|
| `-SkipBronzeCrawler` | Switch | Pula execução do Bronze Crawler | `$false` |
| `-SkipBookmarkReset` | Switch | Pula reset dos Job Bookmarks | `$false` |
| `-AutoApprove` | Switch | Não pede confirmação antes de executar | `$false` |
| `-WaitSeconds` | Int | Tempo de espera após Bronze Crawler (segundos) | `90` |

---

### Opção 3: Recuperação Manual (Passo a Passo)

Se preferir controle total, consulte o **WORKFLOW_RECOVERY_GUIDE.md** e execute cada comando manualmente.

```powershell
# 1. Executar Bronze Crawler
aws glue start-crawler --name datalake-pipeline-bronze-car-data-crawler-dev

# 2. Aguardar 90 segundos
Start-Sleep -Seconds 90

# 3. Resetar Bookmarks
aws glue reset-job-bookmark --job-name datalake-pipeline-silver-consolidation-dev
aws glue reset-job-bookmark --job-name datalake-pipeline-gold-car-current-state-dev
aws glue reset-job-bookmark --job-name datalake-pipeline-gold-performance-alerts-dev

# 4. Executar Workflow
aws glue start-workflow-run --name datalake-pipeline-silver-etl-workflow-dev
```

---

## 📊 Exemplos de Uso

### Cenário 1: Após Atualização Terraform Normal

```powershell
# Recuperação completa padrão
.\scripts\Recover-Workflow.ps1
```

**Output esperado:**
```
═══════════════════════════════════════════════════════════════
  🔧 RECUPERAÇÃO AUTOMÁTICA DO WORKFLOW GLUE
═══════════════════════════════════════════════════════════════

Workflow: datalake-pipeline-silver-etl-workflow-dev
Data/Hora: 31/10/2025 14:30:00

⚠️ Este script irá executar os seguintes passos:
  1. Verificar status atual do workflow
  2. Executar Bronze Crawler (aguardar 90 segundos)
  3. Resetar Job Bookmarks (3 jobs)
  4. Executar workflow completo
  5. Monitorar execução
  6. Validar resultados

Deseja continuar? (S/N): S

═══════════════════════════════════════════════════════════════
  PASSO 0: VERIFICANDO STATUS ATUAL
═══════════════════════════════════════════════════════════════
...
```

---

### Cenário 2: Workflow já está OK (apenas testar)

```powershell
# Verificar status sem executar nada
aws glue get-workflow-runs --name datalake-pipeline-silver-etl-workflow-dev --max-results 1
```

---

### Cenário 3: Apenas Bronze Crawler + Workflow (sem reset)

```powershell
# Útil quando schema mudou mas não quer reprocessar tudo
.\scripts\Recover-Workflow.ps1 -SkipBookmarkReset
```

---

### Cenário 4: Recuperação Express (CI/CD)

```powershell
# Para pipelines automatizados
.\scripts\Recover-Workflow.ps1 -AutoApprove -WaitSeconds 60
```

---

## 🔍 Troubleshooting

### Problema: "Script não encontrado"

**Erro:**
```
.\scripts\Recover-Workflow.ps1 : O termo '.\scripts\Recover-Workflow.ps1' não é 
reconhecido como nome de cmdlet...
```

**Solução:**
```powershell
# Verificar diretório atual
Get-Location

# Navegar para pasta correta
cd C:\dev\HP\wsas\Poc

# Verificar se arquivo existe
Test-Path .\scripts\Recover-Workflow.ps1

# Executar com caminho completo
C:\dev\HP\wsas\Poc\scripts\Recover-Workflow.ps1
```

---

### Problema: "Execução de scripts desabilitada"

**Erro:**
```
Recover-Workflow.ps1 cannot be loaded because running scripts is disabled on this system.
```

**Solução:**
```powershell
# Verificar política de execução
Get-ExecutionPolicy

# Permitir execução (temporário - sessão atual)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# OU permitir execução (permanente - requer admin)
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

# Executar script novamente
.\scripts\Recover-Workflow.ps1
```

---

### Problema: Script trava no Bronze Crawler

**Sintoma:** Script fica parado em "Aguardando conclusão do crawler..."

**Diagnóstico:**
```powershell
# Em outro terminal, verificar status do Crawler
aws glue get-crawler --name datalake-pipeline-bronze-car-data-crawler-dev

# Verificar se há execução travada
aws glue get-crawler-metrics --crawler-name-list datalake-pipeline-bronze-car-data-crawler-dev
```

**Solução:**
- Aguardar mais tempo (Crawler pode estar processando muitos arquivos)
- OU cancelar script (Ctrl+C) e executar com `-WaitSeconds 120`
- OU pular Bronze Crawler: `-SkipBronzeCrawler`

---

### Problema: Workflow continua falhando após recuperação

**Consulte:** `WORKFLOW_RECOVERY_GUIDE.md` → Seção "Diagnóstico de Problemas"

**Comandos úteis:**
```powershell
# Ver detalhes completos da última execução
aws glue get-workflow-run --name datalake-pipeline-silver-etl-workflow-dev --run-id <RUN_ID> --include-graph

# Ver logs de um Job específico
aws logs tail /aws-glue/jobs/datalake-pipeline-silver-consolidation-dev --follow

# Listar tabelas catalogadas
aws glue get-tables --database-name datalake-pipeline-catalog-dev
```

---

## 📝 Logs e Diagnóstico

### Verificar Logs CloudWatch

```powershell
# Silver Job
aws logs tail /aws-glue/jobs/datalake-pipeline-silver-consolidation-dev --since 30m

# Gold Current State Job
aws logs tail /aws-glue/jobs/datalake-pipeline-gold-car-current-state-dev --since 30m

# Gold Alerts Job
aws logs tail /aws-glue/jobs/datalake-pipeline-gold-performance-alerts-dev --since 30m

# Crawlers
aws logs tail /aws-glue/crawlers --since 30m
```

### Verificar Dados no S3

```powershell
# Bronze
aws s3 ls s3://datalake-pipeline-bronze-dev/bronze/car_data/ --recursive

# Silver
aws s3 ls s3://datalake-pipeline-silver-dev/car_telemetry/ --recursive

# Gold Current State
aws s3 ls s3://datalake-pipeline-gold-dev/gold/ --recursive

# Gold Alerts
aws s3 ls s3://datalake-pipeline-gold-dev/performance_alerts_log/ --recursive
```

---

## ✅ Checklist de Validação

Após executar o script de recuperação, verifique:

- [ ] **Script terminou sem erros**
- [ ] **Workflow Status**: `COMPLETED`
- [ ] **Ações Sucesso**: `6/6`
- [ ] **Falhas**: `0`
- [ ] **4 Tabelas catalogadas**: 
  - [ ] `bronze_ingest_year_2025`
  - [ ] `silver_car_telemetry`
  - [ ] `gold_car_current_state`
  - [ ] `performance_alerts_log`
- [ ] **Queries Athena funcionando**
- [ ] **Dados atualizados nas tabelas Gold**

---

## 🎯 Casos de Uso Comuns

### Após adicionar novo Gold Job/Crawler
```powershell
# Reset completo + execução
.\scripts\Recover-Workflow.ps1
```

### Após mudança no schema Bronze
```powershell
# Bronze Crawler + Reset + Execução
.\scripts\Recover-Workflow.ps1
```

### Após mudança em políticas IAM
```powershell
# Aplicar Terraform + Aguardar propagação + Executar
cd terraform
terraform apply
Start-Sleep -Seconds 60
cd ..
.\scripts\Recover-Workflow.ps1 -SkipBookmarkReset
```

### Dados duplicados ou incorretos
```powershell
# Reset completo para reprocessar tudo
.\scripts\Recover-Workflow.ps1
```

---

## 📞 Suporte e Recursos

- 📖 **Guia Completo**: `WORKFLOW_RECOVERY_GUIDE.md`
- 🤖 **Script Automatizado**: `scripts/Recover-Workflow.ps1`
- 📚 **AWS Glue Docs**: https://docs.aws.amazon.com/glue/
- 🔧 **Terraform AWS**: https://registry.terraform.io/providers/hashicorp/aws/

---

## 📅 Histórico de Versões

| Data | Versão | Descrição |
|------|--------|-----------|
| 2025-10-31 | 1.0 | Versão inicial - Guia + Script de recuperação |

---

**💡 Dica:** Mantenha este README e o script sempre atualizados quando houver mudanças na arquitetura do workflow!
