-- ============================================================================
-- WORKAROUND: Criar tabelas Gold Iceberg via Athena DDL
-- ============================================================================
-- Razão: Jobs Glue PySpark falham com "Writing job aborted" ao usar
--        writeTo().createOrReplace() para criar tabelas Iceberg
-- Solução: Criar tabelas manualmente via Athena, depois jobs usam INSERT/MERGE
-- Referência: ICEBERG_MIGRATION_ISSUES.txt - Recomendação 2
-- ============================================================================

-- Pré-requisito: Criar diretórios warehouse manualmente (se não existirem)
-- aws s3 mb s3://datalake-pipeline-gold-dev/iceberg-warehouse/datalake_pipeline_catalog_dev.db/gold_car_current_state_new/
-- aws s3 mb s3://datalake-pipeline-gold-dev/iceberg-warehouse/datalake_pipeline_catalog_dev.db/fuel_efficiency_monthly/
-- aws s3 mb s3://datalake-pipeline-gold-dev/iceberg-warehouse/datalake_pipeline_catalog_dev.db/performance_alerts_log_slim/

-- ============================================================================
-- TABELA 1: Gold Car Current State
-- ============================================================================

CREATE TABLE IF NOT EXISTS glue_catalog.datalake_pipeline_catalog_dev.gold_car_current_state_new (
    car_chassis STRING COMMENT 'Vehicle chassis number (business key)',
    manufacturer STRING COMMENT 'Vehicle manufacturer',
    model STRING COMMENT 'Vehicle model',
    year INT COMMENT 'Manufacturing year',
    gas_type STRING COMMENT 'Fuel type (gasoline, diesel, electric, hybrid)',
    insurance_provider STRING COMMENT 'Insurance company name',
    insurance_valid_until DATE COMMENT 'Insurance expiration date',
    current_mileage_km DOUBLE COMMENT 'Latest odometer reading in kilometers',
    fuel_available_liters DOUBLE COMMENT 'Current fuel level in liters',
    last_telemetry_timestamp TIMESTAMP COMMENT 'Timestamp of the most recent telemetry event',
    avg_fuel_efficiency_kmpl DOUBLE COMMENT 'Average fuel efficiency (km/L) calculated from recent trips',
    total_trips_count BIGINT COMMENT 'Total number of trips recorded for this vehicle',
    processing_timestamp TIMESTAMP COMMENT 'Timestamp when this state snapshot was generated'
)
USING iceberg
LOCATION 's3://datalake-pipeline-gold-dev/iceberg-warehouse/datalake_pipeline_catalog_dev.db/gold_car_current_state_new/'
TBLPROPERTIES (
    'table_type' = 'ICEBERG',
    'format' = 'parquet',
    'write.format.default' = 'parquet',
    'write.parquet.compression-codec' = 'snappy',
    'write.merge.mode' = 'merge-on-read',
    'write.delete.mode' = 'merge-on-read',
    'write.update.mode' = 'merge-on-read',
    'comment' = 'Gold layer - Latest state per vehicle with KPIs (Iceberg MERGE INTO pattern)'
);

-- ============================================================================
-- TABELA 2: Fuel Efficiency Monthly
-- ============================================================================

CREATE TABLE IF NOT EXISTS glue_catalog.datalake_pipeline_catalog_dev.fuel_efficiency_monthly (
    car_chassis STRING COMMENT 'Vehicle chassis number',
    manufacturer STRING COMMENT 'Vehicle manufacturer',
    model STRING COMMENT 'Vehicle model',
    year_month STRING COMMENT 'Month in YYYY-MM format',
    total_km_driven DOUBLE COMMENT 'Total kilometers driven in month',
    total_fuel_liters DOUBLE COMMENT 'Total fuel consumed in liters',
    avg_fuel_efficiency_kmpl DOUBLE COMMENT 'Average fuel efficiency (km/L)',
    trip_count BIGINT COMMENT 'Number of trips in month',
    processing_timestamp TIMESTAMP COMMENT 'Timestamp when aggregation was calculated'
)
USING iceberg
LOCATION 's3://datalake-pipeline-gold-dev/iceberg-warehouse/datalake_pipeline_catalog_dev.db/fuel_efficiency_monthly/'
TBLPROPERTIES (
    'table_type' = 'ICEBERG',
    'format' = 'parquet',
    'write.format.default' = 'parquet',
    'write.parquet.compression-codec' = 'snappy',
    'write.merge.mode' = 'merge-on-read',
    'comment' = 'Gold layer - Monthly fuel efficiency metrics by vehicle (Iceberg format)'
);

-- ============================================================================
-- TABELA 3: Performance Alerts Log (Slim)
-- ============================================================================

CREATE TABLE IF NOT EXISTS glue_catalog.datalake_pipeline_catalog_dev.performance_alerts_log_slim (
    alert_id STRING COMMENT 'Unique alert identifier (UUID)',
    car_chassis STRING COMMENT 'Vehicle chassis number',
    alert_type STRING COMMENT 'Alert type: LOW_FUEL, HIGH_MILEAGE, ANOMALY',
    alert_severity STRING COMMENT 'Severity: WARNING, CRITICAL',
    alert_message STRING COMMENT 'Human-readable alert description',
    current_mileage_km DOUBLE COMMENT 'Mileage at time of alert',
    fuel_available_liters DOUBLE COMMENT 'Fuel level at time of alert',
    telemetry_timestamp TIMESTAMP COMMENT 'Telemetry timestamp when alert triggered',
    alert_generated_timestamp TIMESTAMP COMMENT 'Timestamp when alert was generated',
    alert_date DATE COMMENT 'Alert generation date for efficient querying'
)
USING iceberg
PARTITIONED BY (alert_date)
LOCATION 's3://datalake-pipeline-gold-dev/iceberg-warehouse/datalake_pipeline_catalog_dev.db/performance_alerts_log_slim/'
TBLPROPERTIES (
    'table_type' = 'ICEBERG',
    'format' = 'parquet',
    'write.format.default' = 'parquet',
    'write.parquet.compression-codec' = 'snappy',
    'comment' = 'Gold layer - Performance alerts and anomaly detection log (Iceberg format, append-only)'
);

-- ============================================================================
-- VERIFICAÇÃO
-- ============================================================================

-- Listar tabelas no catálogo
SHOW TABLES IN glue_catalog.datalake_pipeline_catalog_dev;

-- Descrever estrutura das tabelas
DESCRIBE EXTENDED glue_catalog.datalake_pipeline_catalog_dev.gold_car_current_state_new;
DESCRIBE EXTENDED glue_catalog.datalake_pipeline_catalog_dev.fuel_efficiency_monthly;
DESCRIBE EXTENDED glue_catalog.datalake_pipeline_catalog_dev.performance_alerts_log_slim;

-- Verificar que são tabelas Iceberg
SELECT 
    table_name,
    table_type
FROM information_schema.tables
WHERE table_schema = 'datalake_pipeline_catalog_dev'
    AND table_name IN (
        'gold_car_current_state_new',
        'fuel_efficiency_monthly',
        'performance_alerts_log_slim'
    );

-- ============================================================================
-- PRÓXIMO PASSO: Modificar jobs Glue PySpark
-- ============================================================================
-- Alterar de:
--   df.writeTo(iceberg_table).using("iceberg").createOrReplace()
--
-- Para:
--   df.createOrReplaceTempView("temp_view")
--   spark.sql(f"INSERT OVERWRITE glue_catalog.database.table SELECT * FROM temp_view")
--
-- Ou para MERGE INTO (Car Current State e Fuel Efficiency):
--   df.createOrReplaceTempView("source_data")
--   spark.sql("""
--       MERGE INTO glue_catalog.database.table AS target
--       USING source_data AS source
--       ON target.car_chassis = source.car_chassis
--       WHEN MATCHED THEN UPDATE SET *
--       WHEN NOT MATCHED THEN INSERT *
--   """)
-- ============================================================================
