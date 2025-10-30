# Lambda Silver - Documentação Técnica

## 📋 Visão Geral

**Função:** `cleansing_function.py`  
**Objetivo:** Transformar dados brutos JSON da Camada Bronze em arquivos Parquet limpos e particionados na Camada Silver.

---

## 🏗️ Arquitetura

### Trigger
- **Tipo:** S3 ObjectCreated Event
- **Bucket de Origem:** Bronze (`datalake-pipeline-bronze-dev`)
- **Padrão de Arquivos:** `*.json`

### Bibliotecas Utilizadas
- **boto3** (AWS SDK - nativo na Lambda)
- **pandas** (via Lambda Layer)
- **pyarrow** (via Lambda Layer)
- **json**, **uuid**, **datetime**, **logging** (Python stdlib)

---

## 🔄 Fluxo de Processamento

```
┌─────────────────────────────────────────────────────────────┐
│                  SILVER CLEANSING PIPELINE                  │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. Parse S3 Event → Extract bucket & object key           │
│  2. Read JSON from Bronze bucket                           │
│  3. Flatten nested JSON (json_normalize)                   │
│  4. Apply Cleansing (Title case, lowercase)                │
│  5. Convert Data Types (datetime, numeric)                 │
│  6. Enrich Data (calculated columns)                       │
│  7. Create Partition Columns (event_year/month/day)        │
│  8. Write Parquet to Silver (partitioned)                  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 📥 Input - Exemplo de JSON (Bronze)

```json
{
  "carChassis": "5ifRWRvuBaRWyPzdZbXgXTgzAc7KC0dQSkaA8Ak",
  "Model": "HB20 Sedan",
  "year": 2024,
  "ModelYear": 2025,
  "Manufacturer": "hyundai",
  "horsePower": 120,
  "gasType": "Flex",
  "currentMileage": 4321,
  "color": "Blue",
  "fuelCapacityLiters": 50,
  "metrics": {
    "engineTempCelsius": 98,
    "oilTempCelsius": 105,
    "batteryChargePerc": 65,
    "fuelAvailableLiters": 32,
    "coolantCelsius": 90,
    "trip": {
      "tripMileage": 16,
      "tripTimeMinutes": 63,
      "tripFuelLiters": 3,
      "tripMaxSpeedKm": 55,
      "tripAverageSpeedKm": 28,
      "tripStartTimestamp": "Wed, 29 Oct 2025 09:57:35"
    },
    "metricTimestamp": "Wed, 29 Oct 2025 11:00:00"
  },
  "carInsurance": {
    "number": "INS-987654321",
    "provider": "SafeAuto",
    "validUntil": "2026-10-29"
  },
  "market":{
    "currentPrice": 108000,
    "currency": "BRL",
    "location": "Recife, PE",
    "dealer": "Hyndai Pateo",
    "warrantyYears": 5,
    "evaluator": "Tabela Fiepe"
  }
}
```

---

## 🔧 Transformações Aplicadas

### 1. **Flattening (Achatamento)**
Usa `pd.json_normalize()` com separador `_`:

```python
# Antes (nested)
{
  "metrics": {
    "trip": {
      "tripMileage": 16
    }
  }
}

# Depois (flat)
{
  "metrics_trip_tripMileage": 16
}
```

### 2. **Cleansing (Limpeza)**

| Coluna | Transformação | Antes | Depois |
|--------|---------------|-------|--------|
| `Manufacturer` | Title Case | "hyundai" | "Hyundai" |
| `color` | Lowercase | "Blue" | "blue" |
| Todas string | Strip whitespace | " text " | "text" |

### 3. **Conversão de Tipos**

| Coluna | Tipo Original | Tipo Final |
|--------|---------------|------------|
| `metrics_metricTimestamp` | string | datetime64 |
| `metrics_trip_tripStartTimestamp` | string | datetime64 |
| `carInsurance_validUntil` | string | date |
| Colunas numéricas | object/string | float64/int64 |

### 4. **Enriquecimento (Novas Colunas)**

| Nova Coluna | Fórmula | Descrição |
|-------------|---------|-----------|
| `metrics_fuel_level_percentage` | `fuelAvailableLiters / fuelCapacityLiters` | Percentual de combustível |
| `metrics_trip_km_per_liter` | `tripMileage / tripFuelLiters` | Eficiência (km/L) |
| `silver_processing_timestamp` | `datetime.utcnow()` | Timestamp do processamento |
| `silver_processing_date` | `date.today()` | Data do processamento |

### 5. **Particionamento**

Colunas de partição **extraídas de `metrics_metricTimestamp`**:

| Coluna | Extração | Exemplo |
|--------|----------|---------|
| `event_year` | `dt.year` | 2025 |
| `event_month` | `dt.month` (zero-padded) | "10" |
| `event_day` | `dt.day` (zero-padded) | "29" |

---

## 📤 Output - Estrutura no S3 Silver

### Caminho de Partição
```
s3://silver-bucket/
└── car_telemetry/
    └── event_year=2025/
        └── event_month=10/
            └── event_day=29/
                └── car_telemetry_20251029_110523_a1b2c3d4.parquet
```

### Nomenclatura de Arquivo
```
{TABLE_NAME}_{TIMESTAMP}_{UUID}.parquet

Exemplo:
car_telemetry_20251029_110523_a1b2c3d4-e5f6-7890-abcd-ef1234567890.parquet
```

### Formato do Arquivo
- **Formato:** Apache Parquet
- **Compressão:** Snappy
- **Engine:** PyArrow
- **Índice:** Removido (`index=False`)

### Metadados S3
```python
{
  'source': 'silver-cleansing-lambda',
  'record_count': '1',
  'partition_year': '2025',
  'partition_month': '10',
  'partition_day': '29',
  'processing_timestamp': '2025-10-29T11:05:23.456789'
}
```

---

## 🔍 Funções Principais

### 1. `lambda_handler(event, context)`
**Descrição:** Entry point da Lambda. Orquestra todo o pipeline.

**Parâmetros:**
- `event`: Evento S3 com informações do arquivo
- `context`: Contexto da Lambda (não utilizado)

**Retorno:**
```json
{
  "statusCode": 200,
  "body": {
    "message": "Silver cleansing completed successfully",
    "input_file": "s3://bronze-bucket/bronze/file.json",
    "output_path": "s3://silver-bucket/car_telemetry/event_year=2025/...",
    "rows_processed": 1,
    "columns": 45
  }
}
```

### 2. `parse_s3_event(event)`
**Descrição:** Extrai bucket e object key do evento S3.

**Suporta:**
- Evento S3 direto
- Evento S3 wrapped em SQS
- Invocação manual (para testes)

### 3. `read_json_from_s3(bucket, key)`
**Descrição:** Lê arquivo JSON do S3.

**Suporta:**
- JSON único
- JSON Lines (múltiplos JSONs por linha)

### 4. `transform_json_to_dataframe(json_data)`
**Descrição:** Converte JSON em DataFrame achatado.

**Usa:** `pd.json_normalize(json_data, sep='_')`

### 5. `apply_cleansing(df)`
**Descrição:** Aplica limpeza de dados.

**Transformações:**
- Manufacturer → Title Case
- color → lowercase
- Remove espaços em branco

### 6. `convert_data_types(df)`
**Descrição:** Converte tipos de dados.

**Conversões:**
- Timestamps → datetime64
- Datas → date
- Números → float64/int64

### 7. `enrich_data(df)`
**Descrição:** Adiciona colunas calculadas.

**Cria:**
- `metrics_fuel_level_percentage`
- `metrics_trip_km_per_liter` (com tratamento de divisão por zero)
- Metadados de processamento

### 8. `create_partition_columns(df)`
**Descrição:** Cria colunas de partição baseadas em `metrics_metricTimestamp`.

### 9. `write_to_silver(df)`
**Descrição:** Escreve DataFrame como Parquet particionado no S3 Silver.

**Remove:** Colunas de partição do arquivo (ficam no path)

---

## 🧪 Testes

### Teste Local
```python
if __name__ == "__main__":
    test_event = {
        "Records": [{
            "s3": {
                "bucket": {"name": "bronze-bucket"},
                "object": {"key": "bronze/file.json"}
            }
        }]
    }
    
    result = lambda_handler(test_event, None)
    print(json.dumps(result, indent=2))
```

### Teste na AWS
```bash
# Invocação manual
aws lambda invoke \
  --function-name datalake-pipeline-cleansing-silver-dev \
  --payload file://test_event.json \
  output.json

# Ver resultado
cat output.json

# Ver logs
aws logs tail /aws/lambda/datalake-pipeline-cleansing-silver-dev --follow
```

---

## 📊 Métricas e Monitoramento

### CloudWatch Logs
- **Log Group:** `/aws/lambda/datalake-pipeline-cleansing-silver-dev`
- **Retention:** 7 dias

### Logs Estruturados
```
INFO: Starting Silver layer cleansing process
INFO: Processing file: s3://bronze-bucket/bronze/file.json
INFO: Successfully read JSON data from Bronze bucket
INFO: Transformed JSON to DataFrame with 1 rows and 42 columns
INFO: Applied cleansing transformations
INFO: Converted data types
INFO: Enriched data with calculated columns
INFO: Created partition columns
INFO: Successfully wrote data to Silver: s3://silver-bucket/...
```

### Métricas Lambda
- **Invocations:** Contagem total de execuções
- **Duration:** Tempo de execução (target: < 30s)
- **Errors:** Erros durante o processamento
- **Throttles:** Limitações de concorrência

---

## ⚠️ Tratamento de Erros

### Divisão por Zero
```python
# metrics_trip_km_per_liter
df['metrics_trip_km_per_liter'] = df.apply(
    lambda row: round(row['metrics_trip_tripMileage'] / row['metrics_trip_tripFuelLiters'], 2)
    if row['metrics_trip_tripFuelLiters'] > 0 else 0.0,
    axis=1
)
```

### Conversão de Tipos Falha
```python
# Usa errors='coerce' para retornar NaT/NaN em caso de erro
df['metrics_metricTimestamp'] = pd.to_datetime(
    df['metrics_metricTimestamp'],
    format='%a, %d %b %Y %H:%M:%S',
    errors='coerce'
)
```

### Campos Faltando
- Usa `errors='ignore'` ao remover colunas
- Verifica existência de colunas antes de processar

---

## 🚀 Deployment

### Package
```bash
cd lambdas/silver
zip -r ../../assets/silver_etl_package.zip cleansing_function.py
```

### Terraform Apply
```bash
cd terraform
terraform apply -target="aws_lambda_function.cleansing" -auto-approve
```

### Verificação
```bash
aws lambda get-function \
  --function-name datalake-pipeline-cleansing-silver-dev \
  --query 'Configuration.[FunctionName,Runtime,MemorySize,Timeout,State]'
```

---

## 📚 Referências

- [AWS Lambda Python](https://docs.aws.amazon.com/lambda/latest/dg/lambda-python.html)
- [Pandas json_normalize](https://pandas.pydata.org/docs/reference/api/pandas.json_normalize.html)
- [Apache Parquet](https://parquet.apache.org/)
- [PyArrow](https://arrow.apache.org/docs/python/)

---

**Última Atualização:** 2025-10-30  
**Versão:** 1.0.0
