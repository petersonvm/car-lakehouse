# 🧹 Plano de Limpeza de Recursos Legados - Car Lakehouse

**Data**: 06 de Novembro de 2025  
**Versão Pipeline**: v2.1 (100% funcional)  
**Objetivo**: Remover 10+ recursos órfãos para otimização de custos e redução de complexidade

---

## 📋 Inventário de Recursos Legados

### Estado Atual no Terraform State

```bash
# Recursos legados identificados:
aws_lambda_function.cleansing
aws_lambda_function.etl["analysis"]
aws_lambda_function.etl["compliance"]
aws_glue_crawler.gold_alerts_slim_crawler
aws_glue_crawler.gold_fuel_efficiency_crawler
aws_iam_role.gold_alerts_slim_crawler_role (+ 3 policies associadas)
```

### Recursos de Cleanup (null_resource)

```bash
# Recursos de limpeza já existentes (manter):
null_resource.cleanup_car_silver_crawler
null_resource.cleanup_gold_fuel_efficiency_crawler_long
null_resource.cleanup_lambda_analysis
null_resource.cleanup_lambda_cleansing
null_resource.cleanup_lambda_compliance
```

---

## 🎯 Estratégia de Remoção

### Fase 1: Remoção via Terraform Destroy (Recursos Gerenciados)

**Recursos a remover do código Terraform:**

#### 1. Lambdas Legadas (3 recursos)
- ✅ `aws_lambda_function.cleansing` (substituída por Glue Job Silver)
- ✅ `aws_lambda_function.etl["analysis"]` (substituída por Glue Jobs Gold)
- ✅ `aws_lambda_function.etl["compliance"]` (não implementada)

#### 2. Crawlers Duplicados (2 recursos)
- ✅ `aws_glue_crawler.gold_alerts_slim_crawler` (duplicado no crawlers.tf)
- ✅ `aws_glue_crawler.gold_fuel_efficiency_crawler` (duplicado no crawlers.tf)

#### 3. IAM Role Órfã (1 recurso + policies)
- ✅ `aws_iam_role.gold_alerts_slim_crawler_role`
- ✅ `aws_iam_role_policy.gold_alerts_slim_crawler_catalog`
- ✅ `aws_iam_role_policy.gold_alerts_slim_crawler_cloudwatch`
- ✅ `aws_iam_role_policy.gold_alerts_slim_crawler_s3`

### Fase 2: Verificação de Recursos AWS (Fora do Terraform)

Verificar e remover manualmente (se existirem):
- Crawlers órfãos na AWS Console
- Jobs Glue legados
- Tabelas Catalog órfãs

---

## 🚀 Plano de Execução

### Passo 1: Backup do State Atual

```bash
cd terraform

# Backup do state
terraform state pull > terraform.tfstate.backup.$(date +%Y%m%d-%H%M%S)

# Listar recursos legados
terraform state list | grep -E "cleansing|analysis|compliance|gold_alerts_slim_crawler|gold_fuel_efficiency_crawler"
```

### Passo 2: Remover Recursos Específicos do State (Opção Rápida)

```bash
# Remover Lambdas legadas
terraform state rm aws_lambda_function.cleansing
terraform state rm 'aws_lambda_function.etl["analysis"]'
terraform state rm 'aws_lambda_function.etl["compliance"]'

# Remover Crawlers duplicados
terraform state rm aws_glue_crawler.gold_alerts_slim_crawler
terraform state rm aws_glue_crawler.gold_fuel_efficiency_crawler

# Remover IAM Role órfã + policies
terraform state rm aws_iam_role.gold_alerts_slim_crawler_role
terraform state rm aws_iam_role_policy.gold_alerts_slim_crawler_catalog
terraform state rm aws_iam_role_policy.gold_alerts_slim_crawler_cloudwatch
terraform state rm aws_iam_role_policy.gold_alerts_slim_crawler_s3
```

**⚠️ IMPORTANTE**: Após remover do state, os recursos continuam existindo na AWS. Execute o Passo 3 para destruí-los.

### Passo 3: Destruir Recursos na AWS (Após Remover do State)

```bash
# Destruir Lambdas legadas
aws lambda delete-function --function-name datalake-pipeline-cleansing-dev
aws lambda delete-function --function-name datalake-pipeline-analysis-dev
aws lambda delete-function --function-name datalake-pipeline-compliance-dev

# Destruir Crawlers duplicados
aws glue delete-crawler --name gold_alerts_slim_crawler
aws glue delete-crawler --name gold_fuel_efficiency_crawler

# Destruir IAM Role órfã (primeiro remover policies)
aws iam delete-role-policy --role-name gold_alerts_slim_crawler_role --policy-name catalog_access
aws iam delete-role-policy --role-name gold_alerts_slim_crawler_role --policy-name cloudwatch_access
aws iam delete-role-policy --role-name gold_alerts_slim_crawler_role --policy-name s3_access
aws iam delete-role --role-name gold_alerts_slim_crawler_role
```

### Passo 4: Limpar Código Terraform (Remover Definições)

#### 4.1. Editar `terraform/lambda.tf`

**Remover o bloco completo da função cleansing (linhas ~167-211):**

```tf
# REMOVER ESTE BLOCO:
resource "aws_lambda_function" "cleansing" {
  function_name = "${var.project_name}-${var.cleansing_lambda_config.function_name}-${var.environment}"
  # ... (todo o bloco)
}
```

#### 4.2. Editar `terraform/variables.tf`

**Remover as entradas legadas do map `lambda_functions` (linhas ~91-111):**

```tf
# REMOVER:
    analysis = {
      name_suffix = "analysis"
      description = "Lambda function for data analysis (Silver to Gold)"
      handler     = "main.handler"
      runtime     = "python3.9"
      timeout     = 600
      memory_size = 1024
      environment_vars = {
        STAGE = "analysis"
      }
    }
    compliance = {
      name_suffix = "compliance"
      description = "Lambda function for compliance validation (Gold layer)"
      handler     = "main.handler"
      runtime     = "python3.9"
      timeout     = 300
      memory_size = 512
      environment_vars = {
        STAGE = "compliance"
      }
    }
```

**Remover variável cleansing_lambda_config (linhas ~153-174):**

```tf
# REMOVER:
variable "cleansing_lambda_config" {
  description = "Configuration for the dedicated cleansing Lambda function (Silver Layer)"
  # ... (todo o bloco)
}
```

**Remover variável cleansing_package_path (linhas ~177-181):**

```tf
# REMOVER:
variable "cleansing_package_path" {
  description = "Path to the cleansing Lambda deployment package"
  type        = string
  default     = "../assets/cleansing_package.zip"
}
```

#### 4.3. Editar `terraform/crawlers.tf`

**Remover crawlers duplicados (linhas ~46-76):**

```tf
# REMOVER:
resource "aws_glue_crawler" "gold_fuel_efficiency_crawler" {
  # ... (todo o bloco)
}

resource "aws_glue_crawler" "gold_alerts_slim_crawler" {
  # ... (todo o bloco)
}
```

**MANTER apenas os crawlers corretos:**
- ✅ `aws_glue_crawler.silver_car_telemetry_crawler`
- ✅ `aws_glue_crawler.gold_car_current_state_crawler`
- Os crawlers gold corretos estão definidos em outros arquivos (glue_gold_*.tf)

### Passo 5: Validar Terraform após Limpeza

```bash
# Formatar código
terraform fmt

# Validar configuração
terraform validate

# Ver plano (não deve mostrar mudanças significativas)
terraform plan
```

### Passo 6: Aplicar Mudanças (Se Necessário)

```bash
# Se o terraform plan mostrou mudanças esperadas
terraform apply
```

---

## 🔍 Validação Pós-Limpeza

### 1. Verificar Lambdas Ativas (Deve mostrar apenas 1)

```bash
aws lambda list-functions \
  --query "Functions[?starts_with(FunctionName, 'datalake-pipeline')].FunctionName" \
  --output table

# Resultado esperado:
# +-------------------------------------+
# |          ListFunctions              |
# +-------------------------------------+
# |  datalake-pipeline-ingestion-dev    |
# +-------------------------------------+
```

### 2. Verificar Crawlers Ativos (Deve mostrar 6 crawlers corretos)

```bash
aws glue get-crawlers \
  --query "Crawlers[?starts_with(Name, 'datalake-pipeline') || starts_with(Name, 'gold') || starts_with(Name, 'silver')].Name" \
  --output table

# Resultado esperado:
# +-------------------------------------------------------+
# |                    GetCrawlers                         |
# +-------------------------------------------------------+
# |  datalake-pipeline-bronze-car-data-crawler-dev        |
# |  datalake-pipeline-silver-crawler-dev                 |
# |  gold_car_current_state_crawler                       |
# |  datalake-pipeline-gold-fuel-efficiency-crawler-dev   |
# |  datalake-pipeline-gold-performance-alerts-slim-crawler-dev |
# |  silver_car_telemetry_crawler                         |
# +-------------------------------------------------------+
```

### 3. Verificar Jobs Glue Ativos (Deve mostrar 4 jobs)

```bash
aws glue get-jobs \
  --query "Jobs[?starts_with(Name, 'datalake-pipeline')].Name" \
  --output table

# Resultado esperado:
# +----------------------------------------------------------+
# |                        GetJobs                           |
# +----------------------------------------------------------+
# |  datalake-pipeline-silver-consolidation-dev              |
# |  datalake-pipeline-gold-car-current-state-dev            |
# |  datalake-pipeline-gold-fuel-efficiency-dev              |
# |  datalake-pipeline-gold-performance-alerts-slim-dev      |
# +----------------------------------------------------------+
```

### 4. Verificar IAM Roles (Deve mostrar 4 roles)

```bash
aws iam list-roles \
  --query "Roles[?starts_with(RoleName, 'datalake-pipeline')].RoleName" \
  --output table

# Resultado esperado:
# +--------------------------------------------------+
# |                   ListRoles                      |
# +--------------------------------------------------+
# |  datalake-pipeline-lambda-execution-role-dev     |
# |  datalake-pipeline-glue-job-role-dev             |
# |  datalake-pipeline-gold-job-role-dev             |
# |  datalake-pipeline-glue-crawler-role-dev         |
# +--------------------------------------------------+
```

### 5. Verificar Terraform State

```bash
terraform state list | wc -l

# Antes: ~150+ recursos
# Depois: ~140 recursos (10 removidos)
```

---

## 📊 Impacto Esperado

### Recursos Removidos
- ✅ 3 Lambdas legadas (cleansing, analysis, compliance)
- ✅ 2 Crawlers duplicados (gold_alerts_slim, gold_fuel_efficiency)
- ✅ 1 IAM Role órfã + 3 policies
- ✅ ~10 recursos no Terraform state

### Economia de Custos Estimada
- **Lambdas não utilizadas**: $0/mês (não eram invocadas)
- **Crawlers duplicados**: ~$0.50/mês (DPUs desperdiçadas)
- **IAM Role órfã**: $0/mês (sem custo direto)
- **Simplificação**: Redução de 7% na complexidade do Terraform

### Pipeline Após Limpeza
- ✅ 1 Lambda ativa (Ingestion)
- ✅ 4 Jobs Glue (1 Silver + 3 Gold)
- ✅ 6 Crawlers (1 Bronze + 1 Silver + 4 Gold)
- ✅ 1 Workflow (8 actions)
- ✅ 4 IAM Roles
- ✅ 5 Tabelas Glue Catalog

---

## ⚠️ Checklist de Segurança

Antes de executar a limpeza:

- [ ] ✅ Backup do Terraform state criado
- [ ] ✅ Pipeline em produção 100% funcional
- [ ] ✅ Últimas execuções do Workflow bem-sucedidas
- [ ] ✅ Nenhum job legado está sendo usado
- [ ] ✅ Verificado que Lambdas legadas não têm triggers ativos
- [ ] ✅ Crawlers duplicados confirmados como não utilizados
- [ ] ✅ Comunicado ao time sobre a limpeza

Durante a execução:

- [ ] Remover recursos do state antes de destruir
- [ ] Verificar AWS Console entre cada etapa
- [ ] Documentar qualquer erro encontrado

Após a limpeza:

- [ ] Executar workflow completo para validação
- [ ] Verificar logs do CloudWatch
- [ ] Atualizar documentação do projeto
- [ ] Commit das mudanças no Git

---

## 🛟 Rollback (Se Necessário)

Se algo der errado, você pode restaurar o state:

```bash
# Restaurar state do backup
cp terraform.tfstate.backup.<timestamp> terraform.tfstate

# Recriar recursos (se necessário)
terraform apply
```

---

## 📝 Commit das Mudanças

Após validar a limpeza:

```bash
git add terraform/
git commit -m "chore: Remover recursos legados do Terraform

- Remover Lambdas não utilizadas (cleansing, analysis, compliance)
- Remover Crawlers duplicados (gold_alerts_slim, gold_fuel_efficiency)
- Remover IAM Role órfã (gold_alerts_slim_crawler_role)
- Limpar variáveis não utilizadas
- Reduzir complexidade do Terraform

Recursos mantidos:
- 1 Lambda (Ingestion)
- 4 Jobs Glue (1 Silver + 3 Gold)
- 6 Crawlers (1 Bronze + 1 Silver + 4 Gold)
- 4 IAM Roles

Impacto: Pipeline 100% funcional, ~10 recursos removidos"

git push origin gold
```

---

## 📚 Referências

- **[INVENTARIO_COMPONENTES_ATUALIZADO.md](../docs/reports/INVENTARIO_COMPONENTES_ATUALIZADO.md)**: Inventário completo pré-limpeza
- **[README.md](../README.md)**: Documentação principal do projeto
- **Terraform State**: Backup em `terraform.tfstate.backup.<timestamp>`

---

**Autor**: Engenheiro DevOps Sênior  
**Data de Criação**: 06 de Novembro de 2025  
**Status**: ✅ Pronto para Execução
