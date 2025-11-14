# AWS Support Escalation - Iceberg Gold Layer Issue

## Problem Summary
Gold layer Iceberg table creation fails consistently with `AnalysisException: Cannot find column 'event_id'` despite `event_id` NOT being in the DataFrame used for table creation. The error persists across 15+ different implementation approaches.

## Environment
- **AWS Glue Version:** 4.0
- **Spark Version:** 3.3.0  
- **Iceberg Format:** Enabled via `--datalake-formats=iceberg`
- **Region:** us-east-1
- **Account:** dev environment

## Working vs Failing Pattern
✅ **Silver Layer:** 100% functional (10+ successful runs)
- Uses: `df.writeTo(table).using("iceberg").createOrReplace()`
- Result: Table created successfully, data written, queryable in Athena

❌ **Gold Layer:** 0% success (15+ failed attempts)
- Uses: Same pattern as Silver
- Result: `AnalysisException: Cannot find column 'event_id'`

## Key Evidence

### Error Message (Consistent across all attempts)
```
AnalysisException: Cannot find column 'event_id' of the target table among the INSERT columns: 
gold_processing_timestamp, telemetry_timestamp, model, car_chassis, event_timestamp, year, 
insurance_provider, current_mileage_km, insurance_valid_until, insurance_days_expired, 
insurance_status, manufacturer, fuel_available_liters. 

INSERT clauses must provide values for all columns of the target table.
```

### Observations
1. **event_id is NOT in DataFrame:** The error message lists 13 columns, all correct for Gold layer
2. **event_id IS in target table:** Glue Catalog shows `event_id` as first column
3. **DataFrame.select() ignored:** Explicit `.select()` with 14 Gold columns still creates table with 19 columns including `event_id`
4. **Consistent across APIs:** Fails with `writeTo().createOrReplace()`, `.write().saveAsTable()`, both with/without pre-created Athena DDL tables

### Table Schema Created (INCORRECT - Has Silver columns)
```json
[
  {"Name": "event_id", "Type": "string"},              ← Should NOT exist
  {"Name": "car_chassis", "Type": "string"},
  {"Name": "event_primary_timestamp", "Type": "string"}, ← Should NOT exist
  {"Name": "telemetry_timestamp", "Type": "timestamp"},
  {"Name": "current_mileage_km", "Type": "double"},
  {"Name": "fuel_available_liters", "Type": "double"},
  {"Name": "manufacturer", "Type": "string"},
  {"Name": "model", "Type": "string"},
  {"Name": "year", "Type": "int"},
  {"Name": "gas_type", "Type": "string"},
  {"Name": "insurance_provider", "Type": "string"},
  {"Name": "insurance_valid_until", "Type": "string"},
  {"Name": "event_year", "Type": "int"},               ← Should NOT exist
  {"Name": "event_month", "Type": "int"},              ← Should NOT exist
  {"Name": "event_day", "Type": "int"},                ← Should NOT exist
  {"Name": "insurance_status", "Type": "string"},
  {"Name": "insurance_days_expired", "Type": "int"},
  {"Name": "event_timestamp", "Type": "timestamp"},
  {"Name": "gold_processing_timestamp", "Type": "timestamp"}
]
```

### Expected Gold Schema (14 columns)
```python
df_gold = df_with_kpis.select(
    "car_chassis", "manufacturer", "model", "year", "gas_type",
    "insurance_provider", "insurance_valid_until", "current_mileage_km",
    "fuel_available_liters", "telemetry_timestamp", "insurance_status",
    "insurance_days_expired", "event_timestamp", "gold_processing_timestamp"
)
```

## Attempted Solutions (All Failed)

### Approach 1: Athena DDL Workaround
- Created table via `CREATE TABLE ... TBLPROPERTIES ('table_type'='ICEBERG')`
- Modified job to use INSERT OVERWRITE instead of createOrReplace()
- Result: "Cannot write incompatible data" → "Cannot find column 'event_id'"

### Approach 2: PySpark writeTo() API
- Used `df_gold.writeTo(table).using("iceberg").createOrReplace()`
- Result: Table created with wrong schema (19 columns including Silver-only fields)

### Approach 3: write().saveAsTable() API
- Used `df_gold.write.format("iceberg").mode("overwrite").saveAsTable(table)`
- Result: Same as Approach 2

### Approach 4: Schema Enforcement
- Added explicit `.select()` with only Gold columns
- Added `.cache()` and `.count()` to force materialization
- Added `.printSchema()` and column list logging
- Result: Logs show correct 14 columns, but table still created with 19

### Approach 5-15: Various combinations
- Hardcoded database name (no backticks)
- Different table names
- Dropped and recreated multiple times
- Cleaned S3 metadata before each run
- Changed column types (DATE → STRING)
- **All failed with identical error**

## Suspected Root Cause
Iceberg `writeTo()` and `.write()` APIs are using schema metadata from:
1. Glue Catalog (but table is deleted before each run)
2. S3 Iceberg metadata (but S3 is cleaned before each run)
3. **Some internal Spark/Iceberg cache that persists across job runs**

The DataFrame passed to `createOrReplace()` is being **ignored**, and an older/cached schema (from Silver layer) is being used instead.

## Request for AWS Support
1. **Why does Iceberg table creation ignore the DataFrame schema provided?**
2. **Where is the `event_id` column definition being pulled from?**
3. **Is there a Glue/Spark cache that persists across job runs?**
4. **Why does identical code work for Silver but fail for Gold?**

## Reproducible Test Case

### Working Silver Job (SUCCESS)
```python
df_silver.writeTo(f"glue_catalog.datalake_pipeline_catalog_dev.silver_car_telemetry") \
    .using("iceberg") \
    .createOrReplace()
# ✅ Result: Table created with correct schema from df_silver
```

### Failing Gold Job (FAILURE)
```python
df_gold = df_with_kpis.select(
    "car_chassis", "manufacturer", # ... 14 columns total
)
df_gold.writeTo(f"glue_catalog.datalake_pipeline_catalog_dev.gold_car_current_state_new") \
    .using("iceberg") \
    .createOrReplace()
# ❌ Result: Table created with 19 columns (df_with_kpis schema, NOT df_gold)
```

## Additional Context
- Both jobs use identical Spark configuration
- Both jobs have same IAM permissions
- Silver reads from Bronze (S3 Parquet), Gold reads from Silver (Iceberg)
- Problem started when implementing Gold layer; Silver had no issues
- Issue persisted through 2 full days of troubleshooting (30+ hours)

## Files Available for Review
- Full job scripts: `gold_car_current_state_job_iceberg.py`
- Terraform IaC: `terraform/glue_jobs.tf`, `terraform/iceberg_event_driven.tf`
- Complete issue log: `ICEBERG_MIGRATION_ISSUES.txt` (17 phases documented)
- Workflow Run IDs: 15+ failed runs documented

## Priority
**HIGH** - Blocking production data pipeline migration for 48+ hours

---

**Contact:** [Your contact information]  
**Preferred Response:** Root cause explanation + recommended solution  
**Alternative Acceptable:** Confirmed bug + workaround recommendation
