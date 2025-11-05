#!/usr/bin/env python3
"""
Script de Migração: silver_car_telemetry_new → car_silver
========================================================

Este script executa a migração completa da refatoração de nomenclatura
da tabela Silver, incluindo:

1. Backup da tabela antiga
2. Criação da nova tabela car_silver
3. Atualização dos jobs Glue
4. Testes de validação
5. Limpeza (opcional)

Autor: Sistema de Data Lakehouse - Refatoração
Data: 2025-11-05
"""

import boto3
import json
import time
from datetime import datetime

# Configurações
AWS_REGION = "us-east-1"
DATABASE_NAME = "datalake-pipeline-catalog-dev"
OLD_TABLE_NAME = "silver_car_telemetry_new"
NEW_TABLE_NAME = "car_silver"
SILVER_BUCKET = "datalake-pipeline-silver-dev"
OLD_S3_PATH = "car_telemetry_new"
NEW_S3_PATH = "car_silver"

# Clientes AWS
glue_client = boto3.client('glue', region_name=AWS_REGION)
s3_client = boto3.client('s3', region_name=AWS_REGION)
athena_client = boto3.client('athena', region_name=AWS_REGION)

def log_message(message, level="INFO"):
    """Log com timestamp"""
    timestamp = datetime.now().isoformat()
    print(f"[{timestamp}] {level}: {message}")

def backup_table_metadata():
    """Backup dos metadados da tabela antiga"""
    log_message("🔄 Fazendo backup dos metadados da tabela antiga...")
    
    try:
        response = glue_client.get_table(
            DatabaseName=DATABASE_NAME,
            Name=OLD_TABLE_NAME
        )
        
        # Salvar metadados em arquivo
        backup_file = f"backup_table_{OLD_TABLE_NAME}_{int(time.time())}.json"
        with open(backup_file, 'w') as f:
            json.dump(response['Table'], f, indent=2, default=str)
        
        log_message(f"✅ Backup salvo em: {backup_file}")
        return response['Table']
        
    except Exception as e:
        log_message(f"❌ Erro no backup: {str(e)}", "ERROR")
        return None

def copy_s3_data():
    """Copiar dados S3 para novo caminho"""
    log_message("🔄 Copiando dados S3 para novo caminho...")
    
    try:
        # Listar objetos no caminho antigo
        paginator = s3_client.get_paginator('list_objects_v2')
        pages = paginator.paginate(
            Bucket=SILVER_BUCKET,
            Prefix=OLD_S3_PATH
        )
        
        copied_files = 0
        for page in pages:
            if 'Contents' in page:
                for obj in page['Contents']:
                    old_key = obj['Key']
                    new_key = old_key.replace(OLD_S3_PATH, NEW_S3_PATH, 1)
                    
                    # Copiar arquivo
                    copy_source = {'Bucket': SILVER_BUCKET, 'Key': old_key}
                    s3_client.copy_object(
                        CopySource=copy_source,
                        Bucket=SILVER_BUCKET,
                        Key=new_key
                    )
                    copied_files += 1
        
        log_message(f"✅ {copied_files} arquivos copiados para s3://{SILVER_BUCKET}/{NEW_S3_PATH}/")
        return True
        
    except Exception as e:
        log_message(f"❌ Erro na cópia S3: {str(e)}", "ERROR")
        return False

def create_new_table():
    """Criar nova tabela car_silver"""
    log_message("🔄 Criando nova tabela car_silver...")
    
    table_input = {
        'Name': NEW_TABLE_NAME,
        'Description': 'Tabela Silver principal - Dados processados e flattened dos veículos (Refatorada)',
        'TableType': 'EXTERNAL_TABLE',
        'Parameters': {
            'classification': 'parquet',
            'compressionType': 'snappy',
            'typeOfData': 'file',
            'has_encrypted_data': 'false'
        },
        'StorageDescriptor': {
            'Columns': [
                {'Name': 'event_id', 'Type': 'string'},
                {'Name': 'event_timestamp', 'Type': 'timestamp'},
                {'Name': 'car_chassis', 'Type': 'string'},
                {'Name': 'manufacturer', 'Type': 'string'},
                {'Name': 'model', 'Type': 'string'},
                {'Name': 'year', 'Type': 'int'},
                {'Name': 'model_year', 'Type': 'int'},
                {'Name': 'gas_type', 'Type': 'string'},
                {'Name': 'fuel_capacity_liters', 'Type': 'int'},
                {'Name': 'color', 'Type': 'string'},
                {'Name': 'insurance_provider', 'Type': 'string'},
                {'Name': 'insurance_policy_number', 'Type': 'string'},
                {'Name': 'insurance_valid_until', 'Type': 'string'},
                {'Name': 'last_service_date', 'Type': 'string'},
                {'Name': 'last_service_mileage_km', 'Type': 'int'},
                {'Name': 'oil_life_percentage', 'Type': 'double'},
                {'Name': 'rental_agreement_id', 'Type': 'string'},
                {'Name': 'rental_customer_id', 'Type': 'string'},
                {'Name': 'rental_start_date', 'Type': 'string'},
                {'Name': 'trip_start_timestamp', 'Type': 'string'},
                {'Name': 'trip_end_timestamp', 'Type': 'string'},
                {'Name': 'trip_mileage_km', 'Type': 'double'},
                {'Name': 'trip_time_minutes', 'Type': 'int'},
                {'Name': 'trip_fuel_liters', 'Type': 'double'},
                {'Name': 'trip_max_speed_kmh', 'Type': 'int'},
                {'Name': 'current_mileage_km', 'Type': 'int'},
                {'Name': 'fuel_available_liters', 'Type': 'double'},
                {'Name': 'engine_temp_celsius', 'Type': 'int'},
                {'Name': 'oil_temp_celsius', 'Type': 'int'},
                {'Name': 'battery_charge_percentage', 'Type': 'int'},
                {'Name': 'tire_pressure_front_left_psi', 'Type': 'double'},
                {'Name': 'tire_pressure_front_right_psi', 'Type': 'double'},
                {'Name': 'tire_pressure_rear_left_psi', 'Type': 'double'},
                {'Name': 'tire_pressure_rear_right_psi', 'Type': 'double'}
            ],
            'Location': f's3://{SILVER_BUCKET}/{NEW_S3_PATH}/',
            'InputFormat': 'org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat',
            'OutputFormat': 'org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat',
            'SerdeInfo': {
                'Name': 'ParquetHiveSerDe',
                'SerializationLibrary': 'org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe'
            }
        },
        'PartitionKeys': [
            {'Name': 'event_year', 'Type': 'string'},
            {'Name': 'event_month', 'Type': 'string'},
            {'Name': 'event_day', 'Type': 'string'}
        ]
    }
    
    try:
        glue_client.create_table(
            DatabaseName=DATABASE_NAME,
            TableInput=table_input
        )
        log_message(f"✅ Tabela {NEW_TABLE_NAME} criada com sucesso!")
        return True
        
    except Exception as e:
        log_message(f"❌ Erro na criação da tabela: {str(e)}", "ERROR")
        return False

def update_glue_jobs():
    """Atualizar parâmetros dos jobs Glue"""
    log_message("🔄 Atualizando jobs Glue...")
    
    jobs_to_update = [
        {
            'name': 'datalake-pipeline-silver-consolidation-dev',
            'script': 'silver_consolidation_job_refactored.py',
            'params': {
                '--silver_path': NEW_S3_PATH
            }
        },
        {
            'name': 'datalake-pipeline-gold-car-current-state-dev', 
            'script': 'gold_car_current_state_job_refactored.py',
            'params': {
                '--database_name': DATABASE_NAME,
                '--silver_table_name': NEW_TABLE_NAME
            }
        },
        {
            'name': 'datalake-pipeline-gold-fuel-efficiency-dev',
            'script': 'gold_fuel_efficiency_job_refactored.py', 
            'params': {
                '--database_name': DATABASE_NAME,
                '--silver_table_name': NEW_TABLE_NAME
            }
        },
        {
            'name': 'datalake-pipeline-gold-performance-alerts-slim-dev',
            'script': 'gold_performance_alerts_slim_job_refactored.py',
            'params': {
                '--database_name': DATABASE_NAME,
                '--silver_table_name': NEW_TABLE_NAME
            }
        }
    ]
    
    updated_jobs = 0
    for job_config in jobs_to_update:
        try:
            # Buscar configuração atual
            response = glue_client.get_job(JobName=job_config['name'])
            current_job = response['Job']
            
            # Atualizar parâmetros
            new_default_args = current_job.get('DefaultArguments', {})
            new_default_args.update(job_config['params'])
            
            # Atualizar script se necessário
            new_command = current_job['Command'].copy()
            if 'script' in job_config:
                script_bucket = new_command['ScriptLocation'].split('/')[2]
                new_command['ScriptLocation'] = f"s3://{script_bucket}/glue_jobs/{job_config['script']}"
            
            # Aplicar atualização
            job_update = {
                'Role': current_job['Role'],
                'Command': new_command,
                'DefaultArguments': new_default_args,
                'Description': current_job.get('Description', '') + ' (Refatorado para car_silver)',
                'MaxRetries': current_job.get('MaxRetries', 1),
                'Timeout': current_job.get('Timeout', 10),
                'GlueVersion': current_job.get('GlueVersion', '4.0'),
                'NumberOfWorkers': current_job.get('NumberOfWorkers', 2),
                'WorkerType': current_job.get('WorkerType', 'G.1X')
            }
            
            glue_client.update_job(
                JobName=job_config['name'],
                JobUpdate=job_update
            )
            
            log_message(f"✅ Job {job_config['name']} atualizado!")
            updated_jobs += 1
            
        except Exception as e:
            log_message(f"❌ Erro atualizando job {job_config['name']}: {str(e)}", "ERROR")
    
    log_message(f"✅ {updated_jobs}/{len(jobs_to_update)} jobs atualizados!")
    return updated_jobs == len(jobs_to_update)

def test_new_table():
    """Testar nova tabela via Athena"""
    log_message("🔄 Testando nova tabela via Athena...")
    
    test_query = f"""
    SELECT 
        COUNT(*) as total_records,
        COUNT(DISTINCT car_chassis) as unique_vehicles,
        MIN(event_timestamp) as earliest_event,
        MAX(event_timestamp) as latest_event
    FROM {NEW_TABLE_NAME}
    LIMIT 1;
    """
    
    try:
        response = athena_client.start_query_execution(
            QueryString=test_query,
            QueryExecutionContext={
                'Database': DATABASE_NAME
            },
            ResultConfiguration={
                'OutputLocation': f's3://{SILVER_BUCKET}/athena-test-results/'
            }
        )
        
        query_id = response['QueryExecutionId']
        log_message(f"Query iniciada: {query_id}")
        
        # Aguardar execução
        max_attempts = 30
        for attempt in range(max_attempts):
            result = athena_client.get_query_execution(QueryExecutionId=query_id)
            status = result['QueryExecution']['Status']['State']
            
            if status == 'SUCCEEDED':
                log_message("✅ Teste da nova tabela executado com sucesso!")
                return True
            elif status == 'FAILED':
                error = result['QueryExecution']['Status'].get('StateChangeReason', 'Unknown error')
                log_message(f"❌ Teste falhou: {error}", "ERROR")
                return False
            
            time.sleep(2)
        
        log_message("❌ Timeout no teste da tabela", "ERROR")
        return False
        
    except Exception as e:
        log_message(f"❌ Erro no teste: {str(e)}", "ERROR")
        return False

def cleanup_old_resources():
    """Limpeza da tabela e dados antigos (CUIDADO!)"""
    log_message("🔄 Iniciando limpeza dos recursos antigos...")
    
    confirmation = input("⚠️  ATENÇÃO: Deseja realmente remover a tabela e dados antigos? (digite 'CONFIRMO' para prosseguir): ")
    
    if confirmation != "CONFIRMO":
        log_message("🔄 Limpeza cancelada pelo usuário.")
        return False
    
    try:
        # Remover tabela antiga
        glue_client.delete_table(
            DatabaseName=DATABASE_NAME,
            Name=OLD_TABLE_NAME
        )
        log_message(f"✅ Tabela {OLD_TABLE_NAME} removida!")
        
        # Opcional: Remover dados S3 antigos
        # (Comentado por segurança - descomente se necessário)
        """
        paginator = s3_client.get_paginator('list_objects_v2')
        pages = paginator.paginate(Bucket=SILVER_BUCKET, Prefix=OLD_S3_PATH)
        
        for page in pages:
            if 'Contents' in page:
                objects_to_delete = [{'Key': obj['Key']} for obj in page['Contents']]
                if objects_to_delete:
                    s3_client.delete_objects(
                        Bucket=SILVER_BUCKET,
                        Delete={'Objects': objects_to_delete}
                    )
        
        log_message(f"✅ Dados S3 antigos removidos de s3://{SILVER_BUCKET}/{OLD_S3_PATH}/")
        """
        
        return True
        
    except Exception as e:
        log_message(f"❌ Erro na limpeza: {str(e)}", "ERROR")
        return False

def main():
    """Função principal de migração"""
    log_message("🚀 INICIANDO MIGRAÇÃO: silver_car_telemetry_new → car_silver")
    log_message("=" * 80)
    
    steps_completed = 0
    total_steps = 6
    
    # Step 1: Backup
    log_message(f"📋 ETAPA 1/{total_steps}: Backup dos metadados")
    if backup_table_metadata():
        steps_completed += 1
    
    # Step 2: Copiar dados S3
    log_message(f"📋 ETAPA 2/{total_steps}: Cópia dos dados S3")
    if copy_s3_data():
        steps_completed += 1
    
    # Step 3: Criar nova tabela
    log_message(f"📋 ETAPA 3/{total_steps}: Criação da nova tabela")
    if create_new_table():
        steps_completed += 1
    
    # Step 4: Atualizar jobs
    log_message(f"📋 ETAPA 4/{total_steps}: Atualização dos jobs Glue")
    if update_glue_jobs():
        steps_completed += 1
    
    # Step 5: Testar nova tabela
    log_message(f"📋 ETAPA 5/{total_steps}: Teste da nova tabela")
    if test_new_table():
        steps_completed += 1
    
    # Step 6: Limpeza (opcional)
    log_message(f"📋 ETAPA 6/{total_steps}: Limpeza (opcional)")
    cleanup_result = cleanup_old_resources()
    if cleanup_result:
        steps_completed += 1
    
    # Resultado final
    log_message("=" * 80)
    log_message(f"🎉 MIGRAÇÃO CONCLUÍDA: {steps_completed}/{total_steps} etapas executadas com sucesso!")
    
    if steps_completed == total_steps:
        log_message("✅ Refatoração completamente bem-sucedida!")
        log_message(f"📝 Nova tabela Silver: {DATABASE_NAME}.{NEW_TABLE_NAME}")
        log_message(f"📁 Nova localização S3: s3://{SILVER_BUCKET}/{NEW_S3_PATH}/")
    else:
        log_message("⚠️  Refatoração parcialmente concluída. Verifique os logs.")
    
    log_message("=" * 80)

if __name__ == "__main__":
    main()