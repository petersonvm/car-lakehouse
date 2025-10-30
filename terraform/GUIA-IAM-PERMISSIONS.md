# Guia: Anexar Política IAM ao Usuário wsas-terraform

## 📋 Arquivo de Política Criado
- **Localização:** `terraform/iam-policy-glue-athena.json`
- **Tipo:** Política IAM Customizada (Least Privilege)
- **Permissões:** AWS Glue + Amazon Athena

---

## 🔧 Opção 1: Usar AWS Console (Recomendado)

### Passo 1: Acessar IAM Console
1. Acesse: https://console.aws.amazon.com/iam/
2. No menu lateral, clique em **"Users"**
3. Localize e clique no usuário: **`wsas-terraform`**

### Passo 2: Criar Política Customizada
1. Abra uma nova aba e acesse: https://console.aws.amazon.com/iam/home#/policies
2. Clique em **"Create policy"**
3. Clique na aba **"JSON"**
4. Cole o conteúdo do arquivo: `terraform/iam-policy-glue-athena.json`
5. Clique em **"Next: Tags"** (pule as tags)
6. Clique em **"Next: Review"**
7. Defina o nome: **`DataLake-Glue-Athena-TerraformAccess`**
8. Descrição: `Permite Terraform gerenciar AWS Glue e Athena para Data Lake`
9. Clique em **"Create policy"**

### Passo 3: Anexar Política ao Usuário
1. Volte para a página do usuário **`wsas-terraform`**
2. Clique na aba **"Permissions"**
3. Clique em **"Add permissions"** → **"Attach policies directly"**
4. Na busca, digite: `DataLake-Glue-Athena-TerraformAccess`
5. Marque o checkbox da política
6. Clique em **"Next"** e depois **"Add permissions"**

---

## 🚀 Opção 2: Usar AWS CLI (Mais Rápido)

### Passo 1: Criar a Política
```powershell
aws iam create-policy `
  --policy-name DataLake-Glue-Athena-TerraformAccess `
  --policy-document file://terraform/iam-policy-glue-athena.json `
  --description "Permite Terraform gerenciar AWS Glue e Athena para Data Lake"
```

### Passo 2: Anexar ao Usuário
```powershell
aws iam attach-user-policy `
  --user-name wsas-terraform `
  --policy-arn arn:aws:iam::901207488135:policy/DataLake-Glue-Athena-TerraformAccess
```

---

## ✅ Verificar Permissões

Após anexar a política, verifique:

```powershell
aws iam list-attached-user-policies --user-name wsas-terraform
```

Você deve ver a nova política listada.

---

## 🔄 Reexecutar Terraform Apply

Depois de anexar as permissões:

```powershell
cd C:\dev\HP\wsas\Poc\terraform
terraform apply "tfplan"
```

**IMPORTANTE:** Se o plano expirou (passou muito tempo), gere um novo:

```powershell
terraform plan -out=tfplan
terraform apply "tfplan"
```

---

## 📊 Permissões Concedidas

A política criada permite:

### AWS Glue:
- ✅ Criar/Ler/Atualizar/Deletar Databases
- ✅ Criar/Ler/Atualizar/Deletar Tables
- ✅ Gerenciar Partitions
- ✅ Criar/Ler/Atualizar/Deletar Crawlers
- ✅ Iniciar/Parar Crawlers

### Amazon Athena:
- ✅ Criar/Ler/Atualizar/Deletar Workgroups
- ✅ Executar Queries
- ✅ Obter Resultados de Queries
- ✅ Acessar Data Catalog

### IAM:
- ✅ PassRole (apenas para Glue e Athena roles específicos)

---

## 🛡️ Segurança

Esta política segue o princípio de **Least Privilege**:
- ✅ Escopada apenas aos recursos necessários
- ✅ Restrita à região us-east-1
- ✅ Restrita à conta AWS 901207488135
- ✅ PassRole limitado aos serviços glue.amazonaws.com e athena.amazonaws.com

---

## ❓ Troubleshooting

Se ainda encontrar erros após anexar a política:

1. **Aguarde 10-30 segundos** (propagação IAM)
2. **Limpe credenciais em cache:**
   ```powershell
   Remove-Item Env:\AWS_*
   aws configure list
   ```
3. **Verifique se está usando o perfil correto:**
   ```powershell
   aws sts get-caller-identity
   ```
   Deve retornar: `"UserId": "...", "Account": "901207488135", "Arn": "...wsas-terraform"`

---

## 📞 Próximos Passos

Após anexar a política e reexecutar o Terraform:

1. ✅ Terraform apply completará com sucesso
2. ✅ Glue Database e Crawlers serão criados
3. ✅ Athena Workgroup será criado
4. 🎯 **Executar os Crawlers manualmente no AWS Console**
5. 🎯 **Testar queries no Athena Query Editor**
