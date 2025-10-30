# S3 Event Triggers Configuration

Este documento explica como o S3 Event Trigger está configurado para a função Lambda de ingestão.

## 🎯 Configuração Atual

### Ingestion Lambda Trigger

A função `ingestion-function` é **automaticamente invocada** quando arquivos são enviados ao bucket `landing`.

**Configuração:**
- **Bucket**: `{project_name}-landing-{environment}`
- **Evento**: `s3:ObjectCreated:*`
- **Filtro de Prefixo**: Nenhum (todos os objetos)
- **Filtro de Sufixo**: Nenhum (todos os tipos de arquivo)

## 📋 Eventos S3 Disponíveis

Você pode modificar o evento no arquivo `lambda.tf`. Opções:

### Eventos de Criação
- `s3:ObjectCreated:*` - Qualquer método de criação
- `s3:ObjectCreated:Put` - Upload via PUT
- `s3:ObjectCreated:Post` - Upload via POST
- `s3:ObjectCreated:Copy` - Cópia de objeto
- `s3:ObjectCreated:CompleteMultipartUpload` - Upload multipart

### Eventos de Remoção
- `s3:ObjectRemoved:*` - Qualquer remoção
- `s3:ObjectRemoved:Delete` - Exclusão de objeto
- `s3:ObjectRemoved:DeleteMarkerCreated` - Marcador de exclusão

## 🔧 Customizações Comuns

### 1. Filtrar por Tipo de Arquivo

Para processar apenas arquivos JSON:

```hcl
resource "aws_s3_bucket_notification" "landing_bucket_notification" {
  bucket = aws_s3_bucket.data_lake["landing"].id

  lambda_function {
    lambda_function_arn = aws_lambda_function.etl["ingestion"].arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = ""
    filter_suffix       = ".json"  # Apenas arquivos .json
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke_ingestion]
}
```

### 2. Filtrar por Pasta/Prefixo

Para processar apenas arquivos em uma pasta específica:

```hcl
resource "aws_s3_bucket_notification" "landing_bucket_notification" {
  bucket = aws_s3_bucket.data_lake["landing"].id

  lambda_function {
    lambda_function_arn = aws_lambda_function.etl["ingestion"].arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "raw-data/"  # Apenas arquivos na pasta raw-data/
    filter_suffix       = ""
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke_ingestion]
}
```

### 3. Múltiplos Triggers

Para processar diferentes tipos de arquivo com diferentes padrões:

```hcl
resource "aws_s3_bucket_notification" "landing_bucket_notification" {
  bucket = aws_s3_bucket.data_lake["landing"].id

  # Trigger para arquivos CSV
  lambda_function {
    id                  = "csv-trigger"
    lambda_function_arn = aws_lambda_function.etl["ingestion"].arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "csv/"
    filter_suffix       = ".csv"
  }

  # Trigger para arquivos JSON
  lambda_function {
    id                  = "json-trigger"
    lambda_function_arn = aws_lambda_function.etl["ingestion"].arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "json/"
    filter_suffix       = ".json"
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke_ingestion]
}
```

## 📦 Estrutura do Evento S3

Quando a Lambda é invocada, ela recebe um evento com a seguinte estrutura:

```json
{
  "Records": [
    {
      "eventVersion": "2.1",
      "eventSource": "aws:s3",
      "awsRegion": "us-east-1",
      "eventTime": "2025-10-29T12:34:56.789Z",
      "eventName": "ObjectCreated:Put",
      "s3": {
        "bucket": {
          "name": "datalake-pipeline-landing-dev",
          "arn": "arn:aws:s3:::datalake-pipeline-landing-dev"
        },
        "object": {
          "key": "my-file.json",
          "size": 1024,
          "eTag": "d41d8cd98f00b204e9800998ecf8427e"
        }
      }
    }
  ]
}
```

## 🐍 Exemplo de Código Python para Processar o Evento

```python
import json
import boto3

s3_client = boto3.client('s3')

def handler(event, context):
    """
    Processa arquivos enviados ao bucket landing
    """
    for record in event['Records']:
        # Extrair informações do evento
        bucket_name = record['s3']['bucket']['name']
        object_key = record['s3']['object']['key']
        file_size = record['s3']['object']['size']
        
        print(f"Processando arquivo: {object_key}")
        print(f"Bucket: {bucket_name}")
        print(f"Tamanho: {file_size} bytes")
        
        # Baixar o arquivo
        response = s3_client.get_object(Bucket=bucket_name, Key=object_key)
        file_content = response['Body'].read()
        
        # Processar o conteúdo
        # ... sua lógica aqui ...
        
        # Exemplo: Copiar para o bucket bronze
        bronze_bucket = os.environ['BRONZE_BUCKET']
        s3_client.put_object(
            Bucket=bronze_bucket,
            Key=f"processed/{object_key}",
            Body=file_content
        )
        
    return {
        'statusCode': 200,
        'body': json.dumps('Processamento concluído!')
    }
```

## 🧪 Testando o Trigger

### Via AWS CLI

```bash
# Upload de arquivo (irá disparar a Lambda)
aws s3 cp test.txt s3://datalake-pipeline-landing-dev/

# Verificar logs
aws logs tail /aws/lambda/datalake-pipeline-ingestion-dev --follow
```

### Via Console AWS

1. Acesse o S3 Console
2. Abra o bucket `landing`
3. Faça upload de um arquivo
4. Acesse CloudWatch Logs para ver a execução da Lambda

## 🔍 Troubleshooting

### Lambda não está sendo invocada

1. Verifique se a permissão Lambda está configurada:
   ```bash
   aws lambda get-policy --function-name datalake-pipeline-ingestion-dev
   ```

2. Verifique a configuração de notificação do bucket:
   ```bash
   aws s3api get-bucket-notification-configuration --bucket datalake-pipeline-landing-dev
   ```

3. Verifique os logs do CloudWatch:
   ```bash
   aws logs tail /aws/lambda/datalake-pipeline-ingestion-dev --since 1h
   ```

### Erro de permissão

Certifique-se de que a IAM Role da Lambda tem permissões para:
- Ler do bucket `landing` (`s3:GetObject`)
- Escrever nos outros buckets (`s3:PutObject`)
- Criar logs no CloudWatch (`logs:CreateLogStream`, `logs:PutLogEvents`)

## 📚 Referências

- [AWS S3 Event Notifications](https://docs.aws.amazon.com/AmazonS3/latest/userguide/NotificationHowTo.html)
- [AWS Lambda with S3](https://docs.aws.amazon.com/lambda/latest/dg/with-s3.html)
- [S3 Event Structure](https://docs.aws.amazon.com/AmazonS3/latest/userguide/notification-content-structure.html)
