SELECT 
    carchassis,
    manufacturer,
    model,
    metrics.engineTempCelsius as engine_temp,
    metrics.fuelLevelLitres as fuel_level,
    market.currentPrice as price,
    market.currency,
    carinsurance.policyNumber as insurance_policy,
    owner.ownerName as owner
FROM bronze_ingest_year_2025
LIMIT 5;
