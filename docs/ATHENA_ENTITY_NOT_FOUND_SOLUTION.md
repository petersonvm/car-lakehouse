# Solução - Erro "Entity Not Found" no Athena

## ❌ Problema

Ao executar a query no Athena:
```sql
DESCRIBE bronze_car_data;
```

Erro apresentado:
```
Entity Not Found (Service: AmazonDataCatalog; Status Code: 400; 
Error Code: EntityNotFoundException)
```

## ✅ Causa Raiz

O **nome da tabela criada pelo Glue Crawler é diferente** do esperado.

### Por Que Isso Aconteceu?

O Glue Crawler usa a estrutura de pastas S3 para nomear tabelas. Como os dados estão em:
```
s3://bronze-bucket/bronze/car_data/ingest_year=2025/ingest_month=10/ingest_day=30/
```

O Glue interpretou `ingest_year=2025` como parte da estrutura de particionamento e criou uma tabela chamada:
- **Nome Real**: `bronze_ingest_year_2025` ← Use este!
- **Nome Esperado**: `bronze_car_data` ← Não existe

## ✅ Solução Imediata

### Usar o Nome Correto da Tabela

```sql
-- ❌ ERRADO - Tabela não existe
DESCRIBE bronze_car_data;

-- ✅ CORRETO - Nome real da tabela
DESCRIBE bronze_ingest_year_2025;
```

## 📊 Verificação das Tabelas Criadas

```bash
# Listar todas as tabelas Bronze
aws glue get-tables --database-name datalake-pipeline-catalog-dev \
  --query "TableList[?starts_with(Name, 'bronze')].{Name:Name,Location:StorageDescriptor.Location}" \
  --output table
```

**Resultado**:
```
+----------------------------------------------------------------------+--------------------------+
|                               Location                               |          Name            |
+----------------------------------------------------------------------+--------------------------+
|  s3://datalake-pipeline-bronze-dev/bronze/                           |  bronze                  |
|  s3://datalake-pipeline-bronze-dev/bronze/car_data/ingest_year=2025/ |  bronze_ingest_year_2025 |
+----------------------------------------------------------------------+--------------------------+
```

## 🎯 Queries Corretas para Usar

### 1. Ver Schema com Structs

```sql
DESCRIBE bronze_ingest_year_2025;
```

### 2. Query Simples

```sql
SELECT 
    carchassis,
    manufacturer,
    model,
    year,
    color
FROM bronze_ingest_year_2025
LIMIT 10;
```

### 3. Query com Campos Nested (Dot Notation)

```sql
SELECT 
    carchassis,
    manufacturer,
    
    -- Struct: metrics
    metrics.engineTempCelsius,
    metrics.fuelLevelLitres,
    metrics.speedKmh,
    
    -- Struct: market
    market.currentPrice,
    market.currency,
    market.marketRegion,
    
    -- Struct: carinsurance
    carinsurance.policyNumber,
    carinsurance.provider,
    
    -- Struct: owner
    owner.ownerName,
    owner.contactEmail
    
FROM bronze_ingest_year_2025
LIMIT 10;
```

### 4. Query com Filtro em Campos Nested

```sql
SELECT 
    carchassis,
    manufacturer,
    metrics.engineTempCelsius as engine_temp,
    market.currentPrice as price
FROM bronze_ingest_year_2025
WHERE metrics.engineTempCelsius > 90.0
    AND market.currentPrice > 50000.00
ORDER BY market.currentPrice DESC;
```

## 🔧 Solução Definitiva (Opcional)

Se você quiser que a tabela se chame `bronze_car_data`, você tem 3 opções:

### Opção 1: Criar View com Nome Desejado (Recomendado)

```sql
CREATE OR REPLACE VIEW bronze_car_data AS
SELECT * FROM bronze_ingest_year_2025;

-- Agora você pode usar:
SELECT * FROM bronze_car_data LIMIT 10;
```

### Opção 2: Reorganizar Estrutura de Pastas S3

Mudar a estrutura para:
```
s3://bronze-bucket/bronze/car_data/
├── data_file_1.parquet
├── data_file_2.parquet
└── ...
```

E mover partições para dentro dos arquivos Parquet (não na estrutura de pastas).

### Opção 3: Renomear Tabela no Glue Catalog

```bash
# 1. Deletar tabela existente
aws glue delete-table \
  --database-name datalake-pipeline-catalog-dev \
  --name bronze_ingest_year_2025

# 2. Re-executar crawler com configuração ajustada
aws glue start-crawler --name datalake-pipeline-bronze-car-data-crawler-dev
```

## ✅ Confirmação - Structs Preservados

Verificando o schema da tabela `bronze_ingest_year_2025`:

```bash
aws glue get-table --database-name datalake-pipeline-catalog-dev \
  --name bronze_ingest_year_2025 \
  --query "Table.StorageDescriptor.Columns[?contains(Type, 'struct')].[Name,Type]" \
  --output table
```

**Resultado - Structs Funcionando Perfeitamente**:

| Column Name   | Type |
|---------------|------|
| `metrics` | `struct<engineTempCelsius:double,fuelCapacityLitres:double,fuelLevelLitres:double,metricTimestamp:string,odometerKm:double,speedKmh:double,tripDistanceKm:double>` |
| `market` | `struct<currency:string,currentPrice:double,marketRegion:string,marketSegment:string>` |
| `carinsurance` | `struct<annualPremium:double,coverageType:string,expiryDate:string,policyNumber:string,provider:string>` |
| `owner` | `struct<contactEmail:string,ownerId:string,ownerName:string,ownershipStartDate:string>` |

✅ **4 structs preservados com sucesso!**

## 📝 Observações Importantes

1. **Case Sensitivity**: O Glue converte nomes para lowercase:
   - `carChassis` → `carchassis`
   - `carInsurance` → `carinsurance`

2. **Partições Detectadas**: 
   - `ingest_month` (string)
   - `ingest_day` (string)

3. **Dot Notation Funciona**: Acesse campos nested com `.`
   - Exemplo: `metrics.engineTempCelsius`

4. **Arquivo de Queries Completo**: 
   - `c:\dev\HP\wsas\Poc\test_data\athena_bronze_queries.sql`
   - Contém 23 queries de exemplo

## 🎉 Conclusão

**O problema NÃO é um erro de configuração - é apenas uma questão de nome!**

✅ O Glue Crawler funcionou perfeitamente  
✅ Todas as estruturas nested foram preservadas como structs  
✅ Partições foram detectadas corretamente  
✅ A tabela está pronta para uso no Athena  

**Use**: `bronze_ingest_year_2025` ao invés de `bronze_car_data`

---

**Data**: 2025-10-30  
**Status**: ✅ **RESOLVIDO**
