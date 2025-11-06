# 🔍 Análise de Causa Raiz - Falha dos Jobs Gold

**Data:** 2025-11-05  
**Investigação:** Teste E2E - Fase 4  
**Status:** ✅ CAUSA RAIZ IDENTIFICADA

---

## 📊 Resumo Executivo

### Sintoma
Jobs da camada Gold **não geraram dados** durante execução do workflow `datalake-pipeline-silver-gold-workflow-dev`.

### Causa Raiz
❌ **Inconsistência de Nomes de Tabelas**: Os 3 jobs Gold estão configurados para ler a tabela **`car_silver`**, mas o crawler Silver criou a tabela com o nome **`silver_car_telemetry`**.

### Impacto
🔴 **CRÍTICO** - Pipeline interrompido na camada Silver, nenhum KPI de negócio gerado.

---

## 🔬 Análise Detalhada

### 1. Estatísticas do Workflow

**Workflow:** `datalake-pipeline-silver-gold-workflow-dev`  
**Run ID:** `wr_2192529795d3eba09fa8eb49bae951782e06dcd670e134eac065bbcfc2899831`

```json
{
    "TotalActions": 15,
    "TimeoutActions": 0,
    "FailedActions": 6,      // ❌ 6 ações falharam!
    "StoppedActions": 0,
    "SucceededActions": 3,
    "RunningActions": 0,
    "ErroredActions": 0,
    "WaitingActions": 0
}
```

**Interpretação:**
- ✅ 3 ações bem-sucedidas: Job Silver + Crawler Silver + Trigger
- ❌ 6 ações falhadas: 3 Jobs Gold (primeira tentativa) + 3 Jobs Gold (retry com "Max concurrent runs exceeded")

---

### 2. Histórico de Execução dos Jobs Gold

#### Job 1: `datalake-pipeline-gold-car-current-state-dev`

```json
[
    {
        "JobRunId": "jr_e36ecbb258d478eb83653fc15a05829b197141d2f6ea0b2c54bda492043efd39",
        "JobRunState": "FAILED",
        "StartedOn": "2025-11-05T16:35:09",
        "ErrorMessage": "Max concurrent runs exceeded"
    },
    {
        "JobRunId": "jr_eecf8d46c4e15fa30f90225ffc3d1dfd0fb5825131ca5887999c8436f43fb4d0",
        "JobRunState": "FAILED",
        "StartedOn": "2025-11-05T16:34:39",
        "ErrorMessage": "EntityNotFoundException: Entity Not Found"
    }
]
```

**Cronologia:**
1. **16:34:39** - Primeira tentativa → ❌ `EntityNotFoundException` (tabela `car_silver` não existe)
2. **16:35:09** - Segunda tentativa → ❌ `Max concurrent runs exceeded` (retry automático falhou)

---

#### Job 2: `datalake-pipeline-gold-fuel-efficiency-dev`

```json
[
    {
        "JobRunId": "jr_6a24dc865e12d4bf121876180b146cf48769a4b8c9eee7c4823ff7964dbe42a7",
        "JobRunState": "FAILED",
        "StartedOn": "2025-11-05T16:35:09",
        "ErrorMessage": "Max concurrent runs exceeded"
    },
    {
        "JobRunId": "jr_12650c9da03a4732d01dab8ff183390c04c25b4ae51177bfa84564baf365c404",
        "JobRunState": "FAILED",
        "StartedOn": "2025-11-05T16:34:39",
        "ErrorMessage": "EntityNotFoundException: Entity Not Found"
    }
]
```

**Mesmo padrão:** `EntityNotFoundException` seguido de retry com "Max concurrent runs exceeded".

---

#### Job 3: `datalake-pipeline-gold-performance-alerts-slim-dev`

```json
[
    {
        "JobRunId": "jr_777d8d453a48c9947472c0a8069519b58de41bbcdb12898b146a608ada3f6e5c",
        "JobRunState": "FAILED",
        "StartedOn": "2025-11-05T16:35:09",
        "ErrorMessage": "Max concurrent runs exceeded"
    },
    {
        "JobRunId": "jr_9282a8404f6a56af835328039fabedfb3978d6f159f9f1e75665be6c3a2b47a8",
        "JobRunState": "FAILED",
        "StartedOn": "2025-11-05T16:34:39",
        "ErrorMessage": "EntityNotFoundException: Entity Not Found"
    }
]
```

**Conclusão:** ✅ **Todos os 3 jobs Gold falharam com o mesmo erro raiz: `EntityNotFoundException`**

---

### 3. Configuração dos Jobs Gold

#### Parâmetros do Job `gold-car-current-state-dev`:

```json
{
    "--silver_database": "datalake-pipeline-catalog-dev",
    "--silver_table": "car_silver",          // ❌ TABELA NÃO EXISTE!
    "--silver_table_name": "car_silver",     // ❌ TABELA NÃO EXISTE!
    "--gold_bucket": "datalake-pipeline-gold-dev",
    "--gold_path": "car_current_state",
    "--gold_database": "datalake-pipeline-catalog-dev"
}
```

**Problema:** Jobs tentam ler `car_silver`, mas a tabela real é `silver_car_telemetry`.

---

### 4. Comparação: Esperado vs Real

| Componente | Configuração Esperada | Realidade AWS | Status |
|------------|----------------------|----------------|--------|
| **Tabela Silver (Docs)** | `car_silver` | `silver_car_telemetry` | ❌ INCONSISTENTE |
| **Tabela Silver (Glue Catalog)** | `car_silver` | `silver_car_telemetry` | ❌ INCONSISTENTE |
| **Parâmetros Jobs Gold** | `--silver_table=car_silver` | `car_silver` (não existe) | ❌ INCONSISTENTE |
| **Crawler Silver** | `car_silver_crawler` | `car_silver_crawler` | ✅ CONSISTENTE |
| **Output Crawler** | Deveria criar `car_silver` | Criou `silver_car_telemetry` | ❌ INCONSISTENTE |

---

### 5. Linha do Tempo do Teste E2E

```
16:27:07 - Lambda converte JSON → Parquet (Bronze) ✅
16:28:51 - Workflow iniciado ✅
16:30:44 - Job Silver escreve dados Silver ✅
16:31:57 - Crawler Silver descobre partições ✅ (cria tabela "silver_car_telemetry")
16:34:39 - Jobs Gold executam em paralelo ❌ (EntityNotFoundException × 3)
16:35:09 - Jobs Gold tentam retry ❌ (Max concurrent runs × 3)
16:35:45 - Workflow completa com status "COMPLETED" ⚠️ (mas 6 ações falharam!)
```

**Observação Crítica:** O workflow reportou `COMPLETED` apesar de 40% das ações (6/15) terem falhado!

---

## 🎯 Causa Raiz Confirmada

### Problema Principal
❌ **Nome da Tabela Silver Inconsistente**

**Explicação:**
1. O **Crawler Silver** (`car_silver_crawler`) criou a tabela com nome **`silver_car_telemetry`** (provavelmente inferido do path S3 ou configuração do crawler)
2. Os **Jobs Gold** estão parametrizados para ler **`car_silver`** (via Terraform)
3. Quando os Jobs Gold tentaram executar `glueContext.create_dynamic_frame.from_catalog(database="datalake-pipeline-catalog-dev", table_name="car_silver")`, receberam **`EntityNotFoundException`**

### Problemas Secundários
1. **Falta de Validação:** Workflow reporta `COMPLETED` mesmo com 40% de falhas
2. **Retry Ineficaz:** Jobs Gold tentaram retry automático mas falharam com "Max concurrent runs exceeded"
3. **Documentação Desatualizada:** Docs usam `car_silver`, mas tabela real é `silver_car_telemetry`

---

## ✅ Soluções Propostas

### Solução 1: Renomear Tabela via AWS Glue (RECOMENDADO)

**Ação:** Renomear `silver_car_telemetry` → `car_silver` no Glue Catalog

**Vantagens:**
- ✅ Não requer mudança de código ou Terraform
- ✅ Mantém consistência com documentação
- ✅ Jobs Gold funcionarão imediatamente

**Comando:**
```bash
# Opção A: Usar AWS CLI para atualizar tabela
aws glue update-table \
  --database-name datalake-pipeline-catalog-dev \
  --table-input '{
    "Name": "car_silver",
    "StorageDescriptor": {...},
    ...
  }' \
  --region us-east-1

# Opção B: Deletar tabela incorreta e recriar manualmente
aws glue delete-table \
  --database-name datalake-pipeline-catalog-dev \
  --name silver_car_telemetry \
  --region us-east-1

# Depois criar tabela com nome correto (manualmente via Console ou Terraform)
```

**Desvantagem:**
- ⚠️ Tabela será recriada pelo crawler na próxima execução (necessário ajustar crawler)

---

### Solução 2: Atualizar Parâmetros dos Jobs Gold

**Ação:** Alterar `--silver_table` de `car_silver` → `silver_car_telemetry` em todos os 3 jobs Gold

**Terraform:**
```hcl
# terraform/glue_jobs.tf

resource "aws_glue_job" "gold_car_current_state" {
  default_arguments = {
    "--silver_table" = "silver_car_telemetry"  # Era: car_silver
    "--silver_database" = "datalake-pipeline-catalog-dev"
    # ... outros parâmetros
  }
}

# Repetir para:
# - gold_fuel_efficiency
# - gold_performance_alerts_slim
```

**Vantagens:**
- ✅ Usa nome real da tabela
- ✅ Não requer mudanças manuais no Glue Catalog
- ✅ Terraform gerencia configuração

**Desvantagens:**
- ⚠️ Requer aplicar Terraform (`terraform apply`)
- ⚠️ Requer update dos jobs na AWS
- ⚠️ Documentação ainda ficará inconsistente

---

### Solução 3: Configurar Crawler Silver para Criar Tabela com Nome Específico

**Ação:** Configurar `car_silver_crawler` para criar tabela com nome `car_silver`

**Terraform:**
```hcl
# terraform/crawlers.tf

resource "aws_glue_crawler" "car_silver_crawler" {
  name = "car_silver_crawler"
  
  catalog_target {
    database_name = "datalake-pipeline-catalog-dev"
    tables = ["car_silver"]  # Forçar nome da tabela
  }
  
  # OU usar TablePrefix
  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Tables = { AddOrUpdateBehavior = "MergeNewColumns" }
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
  })
}
```

**Vantagens:**
- ✅ Crawler sempre criará tabela com nome correto
- ✅ Consistência entre Terraform e AWS

**Desvantagens:**
- ⚠️ Crawler infere nome do path S3, pode não funcionar
- ⚠️ Requer testar se configuração é respeitada

---

### Solução 4: Criar Tabela Manualmente (Como `car_bronze`)

**Ação:** Criar tabela `car_silver` manualmente via script SQL ou Terraform, configurar crawler para apenas atualizar partições.

**Vantagens:**
- ✅ Controle total do schema e nome
- ✅ Mesmo padrão usado em `car_bronze` (que funcionou perfeitamente)

**Desvantagens:**
- ⚠️ Requer manutenção manual do schema se mudar
- ⚠️ Crawler deve ser configurado para não recriar tabela

---

## 🏆 Recomendação Final

### Estratégia Recomendada: **Solução 2 + Solução 4**

1. **Curto Prazo (Hoje):**
   - ✅ Atualizar parâmetros dos 3 Jobs Gold via AWS CLI para usar `silver_car_telemetry`
   - ✅ Executar Jobs Gold manualmente para validar funcionamento
   - ✅ Executar Crawlers Gold
   - ✅ Completar validação E2E

2. **Médio Prazo (Esta Semana):**
   - ✅ Criar tabela `car_silver` manualmente via Terraform (mesmo padrão de `car_bronze`)
   - ✅ Deletar tabela `silver_car_telemetry`
   - ✅ Configurar crawler para apenas atualizar partições da tabela existente
   - ✅ Atualizar Jobs Gold de volta para `--silver_table=car_silver`
   - ✅ Aplicar Terraform
   - ✅ Reiniciar teste E2E completo

3. **Longo Prazo (Próximas 2 Semanas):**
   - ✅ Padronizar nomenclatura: `car_bronze`, `car_silver`, `car_gold_*`
   - ✅ Atualizar toda documentação
   - ✅ Adicionar validações no workflow (fail se tabelas Gold não forem criadas)
   - ✅ Implementar alarmes CloudWatch para `EntityNotFoundException`

---

## 📝 Próximos Passos Imediatos

### 1. Update Rápido (Sem Terraform)
```bash
# Atualizar Job 1
aws glue update-job \
  --job-name datalake-pipeline-gold-car-current-state-dev \
  --job-update '{
    "DefaultArguments": {
      "--silver_table": "silver_car_telemetry",
      "--silver_database": "datalake-pipeline-catalog-dev",
      "--gold_bucket": "datalake-pipeline-gold-dev",
      "--gold_path": "car_current_state",
      "--gold_database": "datalake-pipeline-catalog-dev"
    }
  }' \
  --region us-east-1

# Repetir para outros 2 jobs Gold
```

### 2. Executar Jobs Manualmente
```bash
# Job 1
aws glue start-job-run \
  --job-name datalake-pipeline-gold-car-current-state-dev \
  --region us-east-1

# Job 2
aws glue start-job-run \
  --job-name datalake-pipeline-gold-fuel-efficiency-dev \
  --region us-east-1

# Job 3
aws glue start-job-run \
  --job-name datalake-pipeline-gold-performance-alerts-slim-dev \
  --region us-east-1
```

### 3. Validar Dados Gold
```sql
-- Athena Query 1
SELECT COUNT(*) FROM car_current_state;

-- Athena Query 2
SELECT COUNT(*) FROM fuel_efficiency_metrics;

-- Athena Query 3
SELECT COUNT(*) FROM performance_alerts;
```

---

## 📊 Métricas de Impacto

| Métrica | Valor |
|---------|-------|
| **Jobs Afetados** | 3 (100% dos Jobs Gold) |
| **Falhas no Workflow** | 6 (40% das ações) |
| **Tempo de Downtime** | ~6.5 minutos (workflow completo sem dados Gold) |
| **Tabelas Não Criadas** | 3 (car_current_state, fuel_efficiency_metrics, performance_alerts) |
| **KPIs de Negócio Perdidos** | 100% (nenhum dado Gold gerado) |
| **Severidade** | 🔴 CRÍTICA |

---

## 🔗 Referências

- **Workflow Terraform:** `terraform/workflow.tf`
- **Jobs Gold Terraform:** `terraform/glue_jobs.tf`
- **Relatório E2E Completo:** `docs/TESTE_E2E_COMPLETO_RELATORIO.md`
- **Documentação Infraestrutura:** `docs/INFRAESTRUTURA_COMPONENTES.md`
- **AWS Console - Workflow:** https://console.aws.amazon.com/glue/home?region=us-east-1#workflow:name=datalake-pipeline-silver-gold-workflow-dev
- **AWS Console - Jobs Gold:** https://console.aws.amazon.com/glue/home?region=us-east-1#/v2/data-catalog/jobs

---

**Análise realizada por:** QA Engineer / SRE  
**Data:** 2025-11-05 20:15:00 UTC-3  
**Status:** ✅ CAUSA RAIZ IDENTIFICADA - AGUARDANDO CORREÇÃO
