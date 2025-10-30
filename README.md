# Data Lake Pipeline - Terraform Infrastructure

Este projeto contém a infraestrutura como código (IaC) para provisionar um Data Lake na AWS com arquitetura Medallion e funções Lambda para processamento de dados (ETL).

## 📋 Arquitetura

### Data Lake (Arquitetura Medallion)
- **Landing Zone**: Dados brutos conforme recebidos da fonte
- **Bronze Layer**: Dados brutos com metadados e validação inicial
- **Silver Layer**: Dados limpos, transformados e enriquecidos
- **Gold Layer**: Dados agregados e prontos para consumo analítico

### Funções Lambda
- **ingestion-function**: Ingestão e conversão CSV→Parquet (Landing → Bronze) - **✨ Implementação Real** - **Gatilho automático via S3**
- **cleansing-function**: Limpeza de dados (Bronze → Silver) - *Dummy*
- **analysis-function**: Análise e transformação (Silver → Gold) - *Dummy*
- **compliance-function**: Validação de compliance (Gold layer) - *Dummy*

### Event-Driven Architecture
- **S3 Event Trigger**: O bucket `landing` está configurado para invocar automaticamente a função `ingestion-function` sempre que um arquivo CSV é carregado (evento `s3:ObjectCreated:*.csv`)
- **Processamento Automático**: CSV → Pandas → Parquet com compressão Snappy

## 📁 Estrutura do Projeto

```
.
├── terraform/
│   ├── provider.tf                  # Configuração do provider AWS
│   ├── variables.tf                 # Definição de variáveis
│   ├── s3.tf                        # Recursos dos buckets S3
│   ├── lambda.tf                    # Recursos das funções Lambda + Layer
│   ├── iam.tf                       # Roles e policies IAM
│   ├── outputs.tf                   # Outputs do Terraform
│   ├── terraform.tfvars.example     # Exemplo de valores de variáveis
│   └── TRIGGERS.md                  # Documentação sobre S3 triggers
├── lambdas/
│   └── ingestion/
│       ├── lambda_function.py       # Código real da função ingestion
│       └── README.md                # Documentação técnica detalhada
├── assets/
│   ├── main.py                      # Código dummy das Lambdas genéricas
│   ├── dummy_package.zip            # Package das Lambdas genéricas
│   ├── ingestion_package.zip        # Package da Lambda ingestion (gerado)
│   └── pandas_pyarrow_layer.zip     # Lambda Layer (gerado)
├── build_lambda.ps1                 # Script de build (Windows)
├── build_lambda.sh                  # Script de build (Linux/Mac)
└── README.md                        # Este arquivo
```

## 🚀 Pré-requisitos

1. **Terraform** >= 1.0
   ```bash
   terraform version
   ```

2. **AWS CLI** configurado
   ```bash
   aws configure
   ```

3. **Credenciais AWS** com permissões para criar:
   - S3 Buckets
   - Lambda Functions
   - IAM Roles e Policies
   - CloudWatch Log Groups

## 📝 Como Usar

### 1. Build da Lambda Ingestion

**IMPORTANTE**: Execute este passo ANTES do Terraform!

**Windows (PowerShell):**
```powershell
.\build_lambda.ps1
```

**Linux/Mac:**
```bash
chmod +x build_lambda.sh
./build_lambda.sh
```

Este script irá:
- ✅ Criar `ingestion_package.zip` (código da Lambda)
- ✅ Instalar pandas e pyarrow
- ✅ Criar `pandas_pyarrow_layer.zip` (Lambda Layer)
- ✅ Colocar ambos em `assets/`

### 2. Navegar até o diretório do Terraform

```bash
cd terraform
```

### 3. Configurar variáveis

Copie o arquivo de exemplo e edite com seus valores:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edite o arquivo `terraform.tfvars`:

```hcl
aws_region   = "us-east-1"
project_name = "meu-datalake"
environment  = "dev"

common_tags = {
  Project     = "DataLake-Pipeline"
  ManagedBy   = "Terraform"
  Environment = "dev"
  Owner       = "Seu-Nome"
  CostCenter  = "Engineering"
}
```

### 4. Inicializar o Terraform

```bash
terraform init
```

### 5. Validar a configuração

```bash
terraform validate
```

### 6. Visualizar o plano de execução

```bash
terraform plan
```

### 7. Aplicar as mudanças

```bash
terraform apply
```

Digite `yes` quando solicitado para confirmar a criação dos recursos.

### 8. Visualizar os outputs

```bash
terraform output
terraform output pipeline_summary  # Ver resumo completo
```

### 9. Testar a Lambda Ingestion

Para testar se a função `ingestion` é invocada automaticamente:

**Criar arquivo CSV de teste:**
```bash
# test.csv
cat > test.csv << EOF
id,name,age,city,country
1,John Doe,30,New York,USA
2,Jane Smith,25,London,UK
3,Bob Johnson,35,Toronto,Canada
EOF
```

**Upload para bucket landing:**
```bash
aws s3 cp test.csv s3://meu-datalake-landing-dev/test.csv
```

**Verificar logs em tempo real:**
```bash
aws logs tail /aws/lambda/meu-datalake-ingestion-dev --follow
```

**Verificar arquivo Parquet no bronze:**
```bash
aws s3 ls s3://meu-datalake-bronze-dev/bronze/ --recursive
```
# Fazer upload para o bucket landing (substitua o nome do bucket)
aws s3 cp test.txt s3://meu-projeto-datalake-landing-dev/

# Verificar os logs da Lambda no CloudWatch
aws logs tail /aws/lambda/meu-projeto-datalake-ingestion-dev --follow
```

## 🔧 Customização

### Modificar buckets S3

Edite a variável `s3_buckets` no arquivo `terraform.tfvars`:

```hcl
s3_buckets = {
  landing = {
    name_suffix = "landing"
    versioning  = true
    lifecycle_rules = {
      enabled                       = true
      transition_to_glacier_days    = 90
      transition_to_deep_archive_days = 180
      expiration_days               = 365
    }
  }
  # ... outros buckets
}
```

### Modificar funções Lambda

Edite a variável `lambda_functions` no arquivo `terraform.tfvars`:

```hcl
lambda_functions = {
  ingestion = {
    name_suffix  = "ingestion"
    description  = "Lambda function for data ingestion"
    handler      = "main.handler"
    runtime      = "python3.9"
    timeout      = 900
    memory_size  = 1024
    environment_vars = {
      STAGE = "ingestion"
    }
  }
  # ... outras funções
}
```

## 🗑️ Destruir recursos

Para remover todos os recursos criados:

```bash
terraform destroy
```

⚠️ **ATENÇÃO**: Certifique-se de fazer backup dos dados antes de destruir os recursos!

## 📊 Recursos Criados

Após a execução do `terraform apply`, os seguintes recursos serão criados:

### S3 Buckets (5)
- `{project_name}-landing-{environment}` - Dados brutos
- `{project_name}-bronze-{environment}` - Dados em Parquet
- `{project_name}-silver-{environment}` - Dados transformados
- `{project_name}-gold-{environment}` - Dados agregados
- `{project_name}-lambda-layers-{environment}` - Storage para Lambda Layers (>50MB)
- `{project_name}-gold-{environment}`

### Lambda Functions (4)
- `{project_name}-ingestion-{environment}`
- `{project_name}-cleansing-{environment}`
- `{project_name}-analysis-{environment}`
- `{project_name}-compliance-{environment}`

### IAM Resources
- 1 IAM Role (compartilhada por todas as Lambdas)
- 1 IAM Policy (com permissões mínimas necessárias)
- 1 Lambda Permission (para S3 invocar a função ingestion)

### Event Triggers
- 1 S3 Bucket Notification (landing bucket → ingestion Lambda)
  - Evento: `s3:ObjectCreated:*`
  - Trigger automático quando arquivos são enviados ao bucket landing

### CloudWatch
- 4 Log Groups (criados automaticamente pela AWS quando as Lambdas são invocadas)

## 🔐 Segurança

- **Criptografia**: Todos os buckets S3 usam criptografia AES256
- **Acesso Público**: Bloqueado por padrão em todos os buckets
- **Versionamento**: Habilitado em todos os buckets
- **IAM**: Princípio do menor privilégio aplicado
- **Logs**: CloudWatch Logs habilitado para todas as Lambdas

## 📈 Políticas de Lifecycle

Os buckets têm políticas de lifecycle configuradas:

| Bucket  | Glacier (dias) | Deep Archive (dias) | Expiração (dias) |
|---------|----------------|---------------------|------------------|
| Landing | 90             | 180                 | 365              |
| Bronze  | 180            | 365                 | 730              |
| Silver  | 365            | 730                 | 1095             |
| Gold    | Desabilitado   | Desabilitado        | Desabilitado     |

## 🛠️ Desenvolvimento

### Adicionar código real às Lambdas

1. Substitua o arquivo `assets/main.py` pelo seu código
2. Instale dependências (se necessário):
   ```bash
   pip install -r requirements.txt -t ./assets/
   ```
3. Recrie o pacote:
   ```bash
   cd assets
   zip -r dummy_package.zip .
   ```
4. Execute `terraform apply` novamente

## 📚 Referências

- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [AWS Lambda](https://docs.aws.amazon.com/lambda/)
- [AWS S3](https://docs.aws.amazon.com/s3/)
- [Medallion Architecture](https://www.databricks.com/glossary/medallion-architecture)

## 📄 Licença

Este projeto é fornecido como exemplo educacional.

## 👥 Contribuição

Sinta-se à vontade para contribuir com melhorias!

---

**Desenvolvido com ❤️ usando Terraform e AWS**
# car-lakehouse
