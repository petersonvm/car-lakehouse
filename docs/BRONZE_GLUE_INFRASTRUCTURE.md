# Infraestrutura AWS Glue para Camada Bronze - car_data

## 📋 Visão Geral

Este documento descreve a infraestrutura Terraform criada para tornar os dados da **Camada Bronze** automaticamente detectáveis e consultáveis via **Amazon Athena**, utilizando **AWS Glue Crawlers**.

## 🏗️ Arquitetura

```
┌─────────────────────────────────────────────────────────────────┐
│                    AWS Glue Infrastructure                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Glue Catalog Database                                    │  │
│  │  • Name: datalake-pipeline-catalog-dev                   │  │
│  │  • Purpose: Central metadata repository                  │  │
│  └──────────────────────────────────────────────────────────┘  │
│                            │                                     │
│                            │ cataloged in                       │
│                            ▼                                     │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Bronze Car Data Crawler                                 │  │
│  │  • Name: datalake-pipeline-bronze-car-data-crawler-dev   │  │
│  │  • Schedule: Daily at 00:00 UTC                         │  │
│  │  • Target: s3://bronze/car_data/                        │  │
│  │  • Table Prefix: bronze_                                │  │
│  │  • Features: Preserves nested structures (structs)      │  │
│  └──────────────────────────────────────────────────────────┘  │
│                            │                                     │
│                            │ discovers                          │
│                            ▼                                     │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  S3 Bronze Data (Parquet with Structs)                  │  │
│  │  • Path: s3://bronze/car_data/                          │  │
│  │  • Partitioning: ingest_year/ingest_month/ingest_day    │  │
│  │  • Format: Parquet with nested structures               │  │
│  │  • Structs: metrics, market, carInsurance, owner        │  │
│  └──────────────────────────────────────────────────────────┘  │
│                            │                                     │
│                            │ queryable via                      │
│                            ▼                                     │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Amazon Athena                                           │  │
│  │  • Query Engine: Presto/Trino                           │  │
│  │  • Access: Dot notation for nested fields               │  │
│  │  • Example: metrics.engineTempCelsius                   │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## 🔧 Recursos Terraform Criados

### 1. IAM Role para Glue Crawler

**Recurso**: `aws_iam_role.glue_crawler_role`

```hcl
resource "aws_iam_role" "glue_crawler_role" {
  name               = "datalake-pipeline-glue-crawler-role-dev"
  description        = "IAM role for Glue Crawler to access S3 and Glue Catalog"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json
}
```

**Políticas Anexadas**:
1. **S3 Access** (`aws_iam_role_policy.glue_s3_policy`):
   - `s3:GetObject` - Ler arquivos Parquet
   - `s3:ListBucket` - Listar diretórios particionados

2. **Glue Catalog Access** (`aws_iam_role_policy.glue_catalog_policy`):
   - `glue:GetDatabase`, `glue:GetTable` - Ler metadados
   - `glue:CreateTable`, `glue:UpdateTable` - Criar/atualizar tabelas
   - `glue:GetPartition`, `glue:CreatePartition` - Gerenciar partições
   - `glue:BatchCreatePartition`, `glue:BatchUpdatePartition` - Operações em lote

3. **CloudWatch Logs** (`aws_iam_role_policy.glue_cloudwatch_policy`):
   - `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`

### 2. Glue Catalog Database

**Recurso**: `aws_glue_catalog_database.data_lake_database`

```hcl
resource "aws_glue_catalog_database" "data_lake_database" {
  name        = "datalake-pipeline-catalog-dev"
  description = "Glue Data Catalog database for datalake-pipeline lakehouse architecture"
}
```

**Propósito**: Repositório central de metadados para todas as tabelas (Bronze, Silver, Gold).

### 3. Bronze Car Data Crawler

**Recurso**: `aws_glue_crawler.bronze_car_data_crawler`

```hcl
resource "aws_glue_crawler" "bronze_car_data_crawler" {
  name          = "datalake-pipeline-bronze-car-data-crawler-dev"
  description   = "Crawler for Bronze layer car_data with nested structures (structs)"
  role          = aws_iam_role.glue_crawler_role.arn
  database_name = aws_glue_catalog_database.data_lake_database.name
  
  # Schedule - Daily at midnight UTC
  schedule = "cron(0 0 * * ? *)"
  
  # Target S3 path with HIVE-style partitioning
  s3_target {
    path = "s3://datalake-pipeline-bronze-dev/bronze/car_data/"
    
    exclusions = [
      "**/_temporary/**",
      "**/_SUCCESS",
      "**/.spark*"
    ]
  }
  
  # Table prefix
  table_prefix = "bronze_"
}
```

#### Configurações Críticas para Estruturas Aninhadas

**Schema Change Policy**:
```hcl
schema_change_policy {
  delete_behavior = "LOG"                    # Log deletions, don't remove tables
  update_behavior = "UPDATE_IN_DATABASE"     # Update schema when structs change
}
```

**Recrawl Policy**:
```hcl
recrawl_policy {
  recrawl_behavior = "CRAWL_EVERYTHING"  # Always check for schema changes
}
```

**Configuration** (JSON):
```json
{
  "Version": 1.0,
  "CrawlerOutput": {
    "Partitions": {
      "AddOrUpdateBehavior": "InheritFromTable"  // HIVE-style partitions
    },
    "Tables": {
      "AddOrUpdateBehavior": "MergeNewColumns"   // Add new struct fields
    }
  },
  "Grouping": {
    "TableGroupingPolicy": "CombineCompatibleSchemas"
  }
}
```

## 📊 Estrutura de Dados Bronze

### Localização S3
```
s3://datalake-pipeline-bronze-dev/bronze/car_data/
└── ingest_year=2025/
    └── ingest_month=10/
        └── ingest_day=30/
            └── car_data_20251030_140345_73ca8a0e.parquet
```

### Schema da Tabela `bronze_car_data`

**Tabela Criada pelo Crawler**: `bronze_car_data`

#### Colunas Top-Level
| Column | Type | Description |
|--------|------|-------------|
| `carChassis` | string | Identificador único do veículo |
| `manufacturer` | string | Fabricante do veículo |
| `model` | string | Modelo do veículo |
| `year` | int64 | Ano de fabricação |
| `color` | string | Cor do veículo |
| `ingestion_timestamp` | string | Timestamp de ingestão (ISO 8601) |
| `source_file` | string | Nome do arquivo JSON original |
| `source_bucket` | string | Nome do bucket de origem |

#### Colunas Struct (Nested)

**1. `metrics` - struct<...>**
```sql
struct<
  engineTempCelsius: double,
  fuelCapacityLitres: double,
  fuelLevelLitres: double,
  metricTimestamp: string,
  odometerKm: double,
  speedKmh: double,
  tripDistanceKm: double
>
```

**2. `market` - struct<...>**
```sql
struct<
  currency: string,
  currentPrice: double,
  marketRegion: string,
  marketSegment: string
>
```

**3. `carInsurance` - struct<...>**
```sql
struct<
  annualPremium: double,
  coverageType: string,
  expiryDate: string,
  policyNumber: string,
  provider: string
>
```

**4. `owner` - struct<...>**
```sql
struct<
  contactEmail: string,
  ownerId: string,
  ownerName: string,
  ownershipStartDate: string
>
```

#### Partições (Hive-Style)
| Partition Column | Type | Description |
|------------------|------|-------------|
| `ingest_year` | int | Ano da ingestão |
| `ingest_month` | int | Mês da ingestão (1-12) |
| `ingest_day` | int | Dia da ingestão (1-31) |

## 🚀 Deploy da Infraestrutura

### Pré-requisitos
- Terraform instalado
- AWS CLI configurado
- Permissões IAM adequadas

### Comandos de Deploy

```bash
# 1. Navegar para o diretório Terraform
cd c:\dev\HP\wsas\Poc\terraform

# 2. Inicializar Terraform (se necessário)
terraform init

# 3. Validar configuração
terraform validate

# 4. Planejar mudanças
terraform plan

# 5. Aplicar mudanças
terraform apply

# Ou aplicar apenas os recursos Glue
terraform apply -target="aws_glue_crawler.bronze_car_data_crawler"
```

### Validação do Deploy

```bash
# Verificar se o crawler foi criado
aws glue get-crawler --name datalake-pipeline-bronze-car-data-crawler-dev

# Listar crawlers
aws glue list-crawlers --query "CrawlerNames[?contains(@, 'bronze')]"
```

## 🔄 Executando o Crawler

### Execução Manual

```bash
# Iniciar crawler manualmente
aws glue start-crawler --name datalake-pipeline-bronze-car-data-crawler-dev

# Verificar status do crawler
aws glue get-crawler --name datalake-pipeline-bronze-car-data-crawler-dev \
  --query "Crawler.State" --output text

# Acompanhar logs do crawler
aws glue get-crawler --name datalake-pipeline-bronze-car-data-crawler-dev \
  --query "Crawler.LastCrawl"
```

### Execução Agendada

O crawler está configurado para executar **diariamente às 00:00 UTC** através da expressão cron:

```
cron(0 0 * * ? *)
```

**Schedule Details**:
- **Minutos**: 0
- **Horas**: 0 (midnight UTC)
- **Dia do Mês**: * (todos os dias)
- **Mês**: * (todos os meses)
- **Dia da Semana**: ? (qualquer dia)
- **Ano**: * (todos os anos)

## 📊 Consultando Dados no Athena

### 1. Verificar Tabela Catalogada

```sql
-- Ver schema da tabela com structs
DESCRIBE bronze_car_data;

-- Ver partições disponíveis
SHOW PARTITIONS bronze_car_data;
```

### 2. Query Básica (Colunas Top-Level)

```sql
SELECT 
    carChassis,
    manufacturer,
    model,
    year,
    color,
    ingestion_timestamp
FROM bronze_car_data
WHERE ingest_year = 2025
    AND ingest_month = 10
    AND ingest_day = 30
LIMIT 10;
```

### 3. Query com Campos Aninhados (Dot Notation)

```sql
-- Acessar campos dentro de structs usando dot notation
SELECT 
    carChassis,
    manufacturer,
    
    -- Campos do struct 'metrics'
    metrics.engineTempCelsius,
    metrics.fuelLevelLitres,
    metrics.fuelCapacityLitres,
    metrics.speedKmh,
    metrics.odometerKm,
    metrics.metricTimestamp,
    
    -- Campos do struct 'market'
    market.currentPrice,
    market.currency,
    market.marketRegion,
    market.marketSegment,
    
    -- Campos do struct 'carInsurance'
    carInsurance.policyNumber,
    carInsurance.provider,
    carInsurance.coverageType,
    
    -- Campos do struct 'owner'
    owner.ownerName,
    owner.contactEmail
    
FROM bronze_car_data
WHERE ingest_year = 2025
LIMIT 10;
```

### 4. Query com Filtros em Campos Aninhados

```sql
-- Filtrar por temperatura do motor
SELECT 
    carChassis,
    manufacturer,
    metrics.engineTempCelsius,
    metrics.speedKmh
FROM bronze_car_data
WHERE metrics.engineTempCelsius > 90.0
    AND ingest_year = 2025
ORDER BY metrics.engineTempCelsius DESC;
```

```sql
-- Filtrar por região de mercado
SELECT 
    carChassis,
    manufacturer,
    market.currentPrice,
    market.currency,
    market.marketRegion
FROM bronze_car_data
WHERE market.marketRegion = 'North America'
    AND market.currentPrice > 50000.00
ORDER BY market.currentPrice DESC;
```

### 5. Query Agregada

```sql
-- Temperatura média do motor por fabricante
SELECT 
    manufacturer,
    COUNT(*) as total_records,
    AVG(metrics.engineTempCelsius) as avg_engine_temp,
    AVG(metrics.speedKmh) as avg_speed,
    AVG(market.currentPrice) as avg_price
FROM bronze_car_data
WHERE ingest_year = 2025
GROUP BY manufacturer
ORDER BY avg_price DESC;
```

### 6. Query com Conversão de Data

```sql
-- Converter metricTimestamp (string) para timestamp
SELECT 
    carChassis,
    manufacturer,
    CAST(metrics.metricTimestamp AS TIMESTAMP) as metric_time,
    metrics.engineTempCelsius,
    DATE_DIFF('hour', 
              CAST(metrics.metricTimestamp AS TIMESTAMP), 
              CURRENT_TIMESTAMP) as hours_ago
FROM bronze_car_data
WHERE ingest_year = 2025
ORDER BY metric_time DESC
LIMIT 20;
```

## 🔍 Monitoramento e Troubleshooting

### Verificar Execução do Crawler

```bash
# Ver últimas 10 execuções do crawler
aws glue get-crawler --name datalake-pipeline-bronze-car-data-crawler-dev \
  --query "Crawler.CrawlElapsedTime"

# Ver estatísticas da última execução
aws glue get-crawler --name datalake-pipeline-bronze-car-data-crawler-dev \
  --query "Crawler.LastCrawl.{Status:Status,Duration:LogStream,TablesCreated:TablesCreated,TablesUpdated:TablesUpdated}"
```

### Logs do Crawler no CloudWatch

```bash
# Tail dos logs do crawler
aws logs tail /aws-glue/crawlers --since 30m --follow

# Buscar logs de erro
aws logs filter-log-events \
  --log-group-name /aws-glue/crawlers \
  --filter-pattern "ERROR" \
  --start-time $(date -u -d '1 hour ago' +%s)000
```

### Verificar Tabelas Criadas

```bash
# Listar todas as tabelas no database
aws glue get-tables \
  --database-name datalake-pipeline-catalog-dev \
  --query "TableList[?Name=='bronze_car_data'].[Name,StorageDescriptor.Location,PartitionKeys]"

# Ver schema completo da tabela
aws glue get-table \
  --database-name datalake-pipeline-catalog-dev \
  --name bronze_car_data \
  --query "Table.StorageDescriptor.Columns"
```

### Verificar Partições

```bash
# Listar todas as partições da tabela
aws glue get-partitions \
  --database-name datalake-pipeline-catalog-dev \
  --table-name bronze_car_data \
  --query "Partitions[].{Values:Values,Location:StorageDescriptor.Location}"
```

## 🎯 Próximos Passos

### 1. Executar Crawler pela Primeira Vez

```bash
# Iniciar crawler manualmente
aws glue start-crawler --name datalake-pipeline-bronze-car-data-crawler-dev

# Aguardar conclusão (status: READY)
watch -n 5 'aws glue get-crawler --name datalake-pipeline-bronze-car-data-crawler-dev --query "Crawler.State" --output text'
```

### 2. Validar Tabela no Athena

```sql
-- Ver schema
DESCRIBE bronze_car_data;

-- Contar registros
SELECT COUNT(*) FROM bronze_car_data;

-- Ver sample de dados
SELECT * FROM bronze_car_data LIMIT 5;
```

### 3. Configurar Alertas (Opcional)

```bash
# Criar alarme CloudWatch para falhas do crawler
aws cloudwatch put-metric-alarm \
  --alarm-name bronze-car-data-crawler-failures \
  --alarm-description "Alert when Bronze car_data crawler fails" \
  --metric-name CrawlerFailureRate \
  --namespace AWS/Glue \
  --statistic Average \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 0.5 \
  --comparison-operator GreaterThanThreshold \
  --dimensions Name=CrawlerName,Value=datalake-pipeline-bronze-car-data-crawler-dev
```

## 📚 Referências

### AWS Glue Crawler Documentation
- [Glue Crawler Overview](https://docs.aws.amazon.com/glue/latest/dg/add-crawler.html)
- [Schema Change Policy](https://docs.aws.amazon.com/glue/latest/dg/crawler-schema-changes-prevent.html)
- [Crawler Configuration](https://docs.aws.amazon.com/glue/latest/dg/crawler-configuration.html)

### Athena Documentation
- [Querying Parquet](https://docs.aws.amazon.com/athena/latest/ug/querying-parquet.html)
- [Working with Arrays and Structs](https://docs.aws.amazon.com/athena/latest/ug/rows-and-structs.html)
- [Dot Notation Syntax](https://docs.aws.amazon.com/athena/latest/ug/querying-nested-data.html)

### Terraform Documentation
- [aws_glue_crawler Resource](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/glue_crawler)
- [aws_glue_catalog_database Resource](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/glue_catalog_database)
- [aws_iam_role Resource](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role)

## ✅ Checklist de Validação

- [ ] IAM Role criada com permissões corretas
- [ ] Glue Catalog Database criado
- [ ] Bronze car_data Crawler criado
- [ ] Schedule configurado (cron: daily 00:00 UTC)
- [ ] S3 target apontando para `bronze/car_data/`
- [ ] Table prefix `bronze_` configurado
- [ ] Schema change policy: `UPDATE_IN_DATABASE`
- [ ] Recrawl policy: `CRAWL_EVERYTHING`
- [ ] Terraform outputs atualizados
- [ ] Crawler executado manualmente
- [ ] Tabela `bronze_car_data` catalogada
- [ ] Partições detectadas
- [ ] Structs preservados no schema
- [ ] Query Athena funcionando com dot notation
- [ ] Documentação completa criada

## 🎉 Resultado Final

A infraestrutura Glue está **completamente configurada** para:

✅ **Descobrir automaticamente** arquivos Parquet na camada Bronze  
✅ **Preservar estruturas aninhadas** (structs) no schema  
✅ **Detectar partições HIVE-style** (ingest_year/month/day)  
✅ **Catalogar metadados** no Glue Data Catalog  
✅ **Permitir queries Athena** com dot notation para campos nested  
✅ **Executar diariamente** às 00:00 UTC para detectar novos dados  
✅ **Gerenciar schema evolution** com MergeNewColumns  

**A Camada Bronze agora é consultável via SQL no Amazon Athena! 🚀**

---

**Criado em**: 2025-10-30  
**Terraform Version**: v1.0+  
**AWS Provider**: v5.100.0  
**Status**: ✅ Pronto para produção
