/* =====================================================================
   MERIDIAN LIFE — 33_m2_revenue_forecast.sql
   M2: 6-month FYAP forecast per branch with SNOWFLAKE.ML.FORECAST.

   The input view MUST expose ONLY series + timestamp + target. Any extra
   column is interpreted as an exogenous feature and the forecast call then
   demands future values for it.
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

-- Sanity: the input view must have exactly 3 columns
SELECT COUNT(*) AS column_count
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'CORE' AND TABLE_NAME = 'V_MONTHLY_REVENUE_BY_BRANCH';

CREATE OR REPLACE SNOWFLAKE.ML.FORECAST MERIDIAN_REVENUE_FORECAST(
    INPUT_DATA        => TABLE(V_MONTHLY_REVENUE_BY_BRANCH),
    SERIES_COLNAME    => 'BRANCH_ID',
    TIMESTAMP_COLNAME => 'MONTH_DATE',
    TARGET_COLNAME    => 'TOTAL_FYAP',
    CONFIG_OBJECT     => {'ON_ERROR': 'SKIP'}
);

CALL MERIDIAN_REVENUE_FORECAST!FORECAST(
    FORECASTING_PERIODS => 6,
    CONFIG_OBJECT       => {'prediction_interval': 0.95}
);

CREATE OR REPLACE TABLE REVENUE_FORECAST_RESULTS AS
SELECT
    REPLACE(r.SERIES::VARCHAR, '"', '')            AS BRANCH_ID,
    r.TS::DATE                                     AS FORECAST_MONTH,
    GREATEST(0, r.FORECAST)::NUMBER(20,2)          AS FORECAST_FYAP,
    GREATEST(0, r.LOWER_BOUND)::NUMBER(20,2)       AS LOWER_BOUND_95,
    GREATEST(0, r.UPPER_BOUND)::NUMBER(20,2)       AS UPPER_BOUND_95,
    'M2_ml_forecast_v1'                            AS MODEL_VERSION,
    CURRENT_TIMESTAMP()                            AS GENERATED_AT
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) r;

-- Enrich with branch attributes and a plan reference (2025 plan / 12)
CREATE OR REPLACE VIEW V_FORECAST_VS_PLAN AS
WITH plan AS (
    SELECT BRANCH_ID, SUM(TARGET_FYAP) / 12.0 AS MONTHLY_PLAN_FYAP
    FROM FACT_BRANCH_TARGET WHERE TARGET_YEAR = 2025 GROUP BY 1
)
SELECT
    f.BRANCH_ID,
    b.BRANCH_NAME,
    b.PROVINCE,
    b.REGION,
    f.FORECAST_MONTH,
    f.FORECAST_FYAP,
    f.LOWER_BOUND_95,
    f.UPPER_BOUND_95,
    ROUND(p.MONTHLY_PLAN_FYAP, 2)::NUMBER(20,2)                              AS MONTHLY_PLAN_FYAP,
    ROUND(100.0 * f.FORECAST_FYAP / NULLIF(p.MONTHLY_PLAN_FYAP, 0), 2)       AS FORECAST_ACHIEVEMENT_PCT,
    ROUND(f.FORECAST_FYAP - p.MONTHLY_PLAN_FYAP, 2)::NUMBER(20,2)            AS FORECAST_GAP_VS_PLAN,
    IFF(f.FORECAST_FYAP < p.MONTHLY_PLAN_FYAP, TRUE, FALSE)                  AS AT_RISK_VS_PLAN
FROM REVENUE_FORECAST_RESULTS f
JOIN DIM_BRANCH b ON b.BRANCH_ID = f.BRANCH_ID
LEFT JOIN plan  p ON p.BRANCH_ID = f.BRANCH_ID;

/* ---- Verification --------------------------------------------------- */
SELECT COUNT(*) AS forecast_rows,
       COUNT(DISTINCT BRANCH_ID) AS branches,
       MIN(FORECAST_MONTH) AS first_month,
       MAX(FORECAST_MONTH) AS last_month
FROM REVENUE_FORECAST_RESULTS;

SELECT BRANCH_ID, BRANCH_NAME, FORECAST_MONTH,
       FORECAST_FYAP, LOWER_BOUND_95, UPPER_BOUND_95, FORECAST_ACHIEVEMENT_PCT
FROM V_FORECAST_VS_PLAN
WHERE BRANCH_ID IN ('B13','B16')
ORDER BY BRANCH_ID, FORECAST_MONTH;
