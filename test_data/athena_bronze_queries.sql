-- ============================================================================
-- Amazon Athena Queries - Bronze Layer (car_data with nested structures)
-- ============================================================================
-- Table Name: bronze_ingest_year_2025
-- Database: datalake-pipeline-catalog-dev
-- ============================================================================

-- 1. DESCRIBE TABLE - Ver schema completo com structs
DESCRIBE bronze_ingest_year_2025;

-- 2. SHOW PARTITIONS - Ver partições disponíveis
SHOW PARTITIONS bronze_ingest_year_2025;

-- 3. COUNT - Total de registros
SELECT COUNT(*) as total_records 
FROM bronze_ingest_year_2025;

-- ============================================================================
-- QUERIES BÁSICAS (Colunas Top-Level)
-- ============================================================================

-- 4. Select básico - Colunas simples
SELECT 
    carchassis,
    manufacturer,
    model,
    year,
    color,
    ingestion_timestamp
FROM bronze_ingest_year_2025
LIMIT 10;

-- ============================================================================
-- QUERIES COM NESTED FIELDS (Dot Notation)
-- ============================================================================

-- 5. Acessar campos dentro de structs
SELECT 
    carchassis,
    manufacturer,
    model,
    year,
    
    -- Struct: metrics
    metrics.engineTempCelsius,
    metrics.fuelLevelLitres,
    metrics.fuelCapacityLitres,
    metrics.speedKmh,
    metrics.odometerKm,
    metrics.metricTimestamp,
    
    -- Struct: market
    market.currentPrice,
    market.currency,
    market.marketRegion,
    market.marketSegment,
    
    -- Struct: carinsurance
    carinsurance.policyNumber,
    carinsurance.provider,
    carinsurance.coverageType,
    carinsurance.annualPremium,
    
    -- Struct: owner
    owner.ownerName,
    owner.ownerId,
    owner.contactEmail
    
FROM bronze_ingest_year_2025
LIMIT 10;

-- ============================================================================
-- FILTROS EM CAMPOS NESTED
-- ============================================================================

-- 6. Filtrar por temperatura do motor
SELECT 
    carchassis,
    manufacturer,
    metrics.engineTempCelsius as engine_temp,
    metrics.speedKmh as speed
FROM bronze_ingest_year_2025
WHERE metrics.engineTempCelsius > 90.0
ORDER BY metrics.engineTempCelsius DESC;

-- 7. Filtrar por região de mercado
SELECT 
    carchassis,
    manufacturer,
    market.currentPrice as price,
    market.currency,
    market.marketRegion as region
FROM bronze_ingest_year_2025
WHERE market.marketRegion = 'North America'
ORDER BY market.currentPrice DESC;

-- 8. Filtrar por nível de combustível baixo
SELECT 
    carchassis,
    manufacturer,
    metrics.fuelLevelLitres as fuel_level,
    metrics.fuelCapacityLitres as fuel_capacity,
    ROUND((metrics.fuelLevelLitres / metrics.fuelCapacityLitres) * 100, 2) as fuel_percentage
FROM bronze_ingest_year_2025
WHERE (metrics.fuelLevelLitres / metrics.fuelCapacityLitres) < 0.25
ORDER BY fuel_percentage;

-- 9. Filtrar por fabricante e preço
SELECT 
    carchassis,
    manufacturer,
    model,
    market.currentPrice as price,
    market.currency,
    carinsurance.annualPremium as insurance_premium
FROM bronze_ingest_year_2025
WHERE manufacturer = 'BMW'
    AND market.currentPrice > 50000.00
ORDER BY market.currentPrice DESC;

-- ============================================================================
-- QUERIES AGREGADAS
-- ============================================================================

-- 10. Estatísticas por fabricante
SELECT 
    manufacturer,
    COUNT(*) as total_vehicles,
    ROUND(AVG(metrics.engineTempCelsius), 2) as avg_engine_temp,
    ROUND(AVG(metrics.speedKmh), 2) as avg_speed,
    ROUND(AVG(market.currentPrice), 2) as avg_price,
    ROUND(AVG(carinsurance.annualPremium), 2) as avg_insurance
FROM bronze_ingest_year_2025
GROUP BY manufacturer
ORDER BY avg_price DESC;

-- 11. Análise de combustível
SELECT 
    manufacturer,
    COUNT(*) as total_vehicles,
    ROUND(AVG(metrics.fuelLevelLitres), 2) as avg_fuel_level,
    ROUND(AVG(metrics.fuelCapacityLitres), 2) as avg_fuel_capacity,
    ROUND(AVG((metrics.fuelLevelLitres / metrics.fuelCapacityLitres) * 100), 2) as avg_fuel_percentage
FROM bronze_ingest_year_2025
GROUP BY manufacturer
ORDER BY avg_fuel_percentage DESC;

-- 12. Análise por região de mercado
SELECT 
    market.marketRegion as region,
    market.marketSegment as segment,
    COUNT(*) as total_vehicles,
    ROUND(AVG(market.currentPrice), 2) as avg_price,
    MIN(market.currentPrice) as min_price,
    MAX(market.currentPrice) as max_price
FROM bronze_ingest_year_2025
GROUP BY market.marketRegion, market.marketSegment
ORDER BY avg_price DESC;

-- ============================================================================
-- CONVERSÃO DE TIPOS E DATAS
-- ============================================================================

-- 13. Converter metricTimestamp para TIMESTAMP
SELECT 
    carchassis,
    manufacturer,
    metrics.metricTimestamp as metric_time_string,
    CAST(metrics.metricTimestamp AS TIMESTAMP) as metric_timestamp,
    DATE_DIFF('hour', 
              CAST(metrics.metricTimestamp AS TIMESTAMP), 
              CURRENT_TIMESTAMP) as hours_ago,
    DATE_DIFF('day', 
              CAST(metrics.metricTimestamp AS TIMESTAMP), 
              CURRENT_TIMESTAMP) as days_ago
FROM bronze_ingest_year_2025
ORDER BY metric_timestamp DESC
LIMIT 20;

-- 14. Análise temporal - Veículos por dia
SELECT 
    DATE(CAST(metrics.metricTimestamp AS TIMESTAMP)) as metric_date,
    COUNT(*) as total_vehicles,
    ROUND(AVG(metrics.engineTempCelsius), 2) as avg_engine_temp,
    ROUND(AVG(market.currentPrice), 2) as avg_price
FROM bronze_ingest_year_2025
GROUP BY DATE(CAST(metrics.metricTimestamp AS TIMESTAMP))
ORDER BY metric_date DESC;

-- ============================================================================
-- QUERIES COM PARTIÇÕES
-- ============================================================================

-- 15. Filtrar por partição específica
SELECT 
    carchassis,
    manufacturer,
    metrics.engineTempCelsius,
    market.currentPrice,
    ingest_month,
    ingest_day
FROM bronze_ingest_year_2025
WHERE ingest_month = '10'
    AND ingest_day = '30'
LIMIT 10;

-- 16. Contar registros por partição
SELECT 
    ingest_month,
    ingest_day,
    COUNT(*) as total_records,
    ROUND(AVG(market.currentPrice), 2) as avg_price
FROM bronze_ingest_year_2025
GROUP BY ingest_month, ingest_day
ORDER BY ingest_month DESC, ingest_day DESC;

-- ============================================================================
-- QUERIES COMPLEXAS - MULTIPLE JOINS E ANÁLISES
-- ============================================================================

-- 17. Análise de custo total (veículo + seguro)
SELECT 
    carchassis,
    manufacturer,
    model,
    market.currentPrice as vehicle_price,
    carinsurance.annualPremium as annual_insurance,
    market.currentPrice + (carinsurance.annualPremium * 5) as total_5year_cost,
    owner.ownerName,
    owner.contactEmail
FROM bronze_ingest_year_2025
ORDER BY total_5year_cost DESC
LIMIT 20;

-- 18. Veículos com temperatura alta E velocidade alta
SELECT 
    carchassis,
    manufacturer,
    model,
    metrics.engineTempCelsius as engine_temp,
    metrics.speedKmh as speed,
    CASE 
        WHEN metrics.engineTempCelsius > 95 AND metrics.speedKmh > 100 THEN 'CRITICAL'
        WHEN metrics.engineTempCelsius > 90 OR metrics.speedKmh > 120 THEN 'WARNING'
        ELSE 'NORMAL'
    END as status_alert
FROM bronze_ingest_year_2025
WHERE metrics.engineTempCelsius > 85 OR metrics.speedKmh > 80
ORDER BY engine_temp DESC, speed DESC;

-- 19. Ranking de veículos por preço e características
SELECT 
    carchassis,
    manufacturer,
    model,
    year,
    market.currentPrice as price,
    metrics.odometerKm as odometer,
    carinsurance.coverageType as insurance_type,
    ROW_NUMBER() OVER (PARTITION BY manufacturer ORDER BY market.currentPrice DESC) as price_rank_by_manufacturer
FROM bronze_ingest_year_2025
ORDER BY manufacturer, price_rank_by_manufacturer
LIMIT 50;

-- 20. Análise de eficiência (distância por litro)
SELECT 
    carchassis,
    manufacturer,
    model,
    metrics.tripDistanceKm as trip_km,
    metrics.fuelLevelLitres as fuel_used,
    ROUND((metrics.tripDistanceKm / metrics.fuelLevelLitres), 2) as km_per_liter,
    market.currentPrice as price,
    CASE 
        WHEN (metrics.tripDistanceKm / metrics.fuelLevelLitres) > 15 THEN 'Excellent'
        WHEN (metrics.tripDistanceKm / metrics.fuelLevelLitres) > 10 THEN 'Good'
        WHEN (metrics.tripDistanceKm / metrics.fuelLevelLitres) > 5 THEN 'Average'
        ELSE 'Poor'
    END as fuel_efficiency_rating
FROM bronze_ingest_year_2025
WHERE metrics.tripDistanceKm > 0 AND metrics.fuelLevelLitres > 0
ORDER BY km_per_liter DESC
LIMIT 30;

-- ============================================================================
-- VERIFICAÇÃO DE DADOS E QUALIDADE
-- ============================================================================

-- 21. Verificar structs não nulos
SELECT 
    COUNT(*) as total_records,
    COUNT(metrics) as records_with_metrics,
    COUNT(market) as records_with_market,
    COUNT(carinsurance) as records_with_insurance,
    COUNT(owner) as records_with_owner,
    COUNT(CASE WHEN metrics IS NULL THEN 1 END) as records_missing_metrics,
    COUNT(CASE WHEN market IS NULL THEN 1 END) as records_missing_market
FROM bronze_ingest_year_2025;

-- 22. Verificar campos obrigatórios
SELECT 
    COUNT(*) as total_records,
    COUNT(carchassis) as records_with_chassis,
    COUNT(manufacturer) as records_with_manufacturer,
    COUNT(metrics.metricTimestamp) as records_with_timestamp,
    COUNT(CASE WHEN carchassis IS NULL OR carchassis = '' THEN 1 END) as records_missing_chassis
FROM bronze_ingest_year_2025;

-- ============================================================================
-- EXPORT / REPORTING QUERIES
-- ============================================================================

-- 23. Relatório completo para exportação
SELECT 
    -- Identificação
    carchassis as chassis_id,
    manufacturer,
    model,
    year,
    color,
    
    -- Métricas do veículo
    metrics.engineTempCelsius as engine_temp_celsius,
    metrics.fuelLevelLitres as fuel_level_litres,
    metrics.fuelCapacityLitres as fuel_capacity_litres,
    ROUND((metrics.fuelLevelLitres / metrics.fuelCapacityLitres) * 100, 2) as fuel_percentage,
    metrics.speedKmh as speed_kmh,
    metrics.odometerKm as odometer_km,
    metrics.tripDistanceKm as trip_distance_km,
    metrics.metricTimestamp as metric_timestamp,
    
    -- Informações de mercado
    market.currentPrice as market_price,
    market.currency,
    market.marketRegion as market_region,
    market.marketSegment as market_segment,
    
    -- Seguro
    carinsurance.policyNumber as insurance_policy,
    carinsurance.provider as insurance_provider,
    carinsurance.coverageType as insurance_coverage,
    carinsurance.annualPremium as insurance_annual_premium,
    carinsurance.expiryDate as insurance_expiry_date,
    
    -- Proprietário
    owner.ownerId as owner_id,
    owner.ownerName as owner_name,
    owner.contactEmail as owner_email,
    owner.ownershipStartDate as ownership_start_date,
    
    -- Metadados de ingestão
    ingestion_timestamp,
    source_file,
    ingest_month,
    ingest_day
    
FROM bronze_ingest_year_2025
ORDER BY manufacturer, model
LIMIT 1000;

-- ============================================================================
-- NOTAS IMPORTANTES
-- ============================================================================
-- 
-- 1. Nome da tabela: bronze_ingest_year_2025 (não bronze_car_data)
-- 2. Database: datalake-pipeline-catalog-dev
-- 3. Structs preservados: metrics, market, carinsurance, owner
-- 4. Partições: ingest_month, ingest_day
-- 5. Use dot notation para acessar campos nested: struct_name.field_name
-- 6. Todos os nomes de colunas foram convertidos para lowercase pelo Glue
--    (carChassis → carchassis, carInsurance → carinsurance)
-- 
-- ============================================================================
