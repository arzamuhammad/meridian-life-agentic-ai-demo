/* =====================================================================
   MERIDIAN LIFE — 34_m6_anomaly_detection.sql
   M6: unsupervised production anomalies per branch.

   WHY A 3-MONTH ROLLING SERIES, NOT RAW MONTHLY FYAP
     A branch writes only 3-10 policies a month and premiums are heavily
     right-skewed, so raw monthly FYAP has a coefficient of variation of
     ~0.70. At that noise level a 99% prediction interval still produced a
     ~14% false-alarm rate and caught only half of the known events.
     A trailing 3-month sum cuts the CV to ~0.48 and matches how insurers
     actually monitor branch trend (rolling quarter). Both series are
     scored; ROLLING3 is the one the agent and dashboard consume.

   SNOWFLAKE.ML.ANOMALY_DETECTION requires every detection timestamp to be
   later than every training timestamp:
       train   2023-01 .. 2025-06        detect  2025-07 .. 2025-12
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

/* ---- Series definitions (ONLY series + timestamp + target) ---------- */
CREATE OR REPLACE VIEW V_ROLLING3_REVENUE_BY_BRANCH AS
SELECT BRANCH_ID,
       MONTH_DATE,
       SUM(TOTAL_FYAP) OVER (PARTITION BY BRANCH_ID ORDER BY MONTH_DATE
                             ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)::FLOAT AS ROLLING3_FYAP
FROM V_MONTHLY_REVENUE_BY_BRANCH;

CREATE OR REPLACE VIEW V_PRODUCTION_TRAIN AS
SELECT BRANCH_ID, MONTH_DATE, ROLLING3_FYAP
FROM V_ROLLING3_REVENUE_BY_BRANCH
WHERE MONTH_DATE <  '2025-07-01';

CREATE OR REPLACE VIEW V_PRODUCTION_DETECT AS
SELECT BRANCH_ID, MONTH_DATE, ROLLING3_FYAP
FROM V_ROLLING3_REVENUE_BY_BRANCH
WHERE MONTH_DATE >= '2025-07-01';

/* ---- Train + detect ------------------------------------------------- */
CREATE OR REPLACE SNOWFLAKE.ML.ANOMALY_DETECTION MERIDIAN_PRODUCTION_ANOMALY(
    INPUT_DATA        => TABLE(V_PRODUCTION_TRAIN),
    SERIES_COLNAME    => 'BRANCH_ID',
    TIMESTAMP_COLNAME => 'MONTH_DATE',
    TARGET_COLNAME    => 'ROLLING3_FYAP',
    LABEL_COLNAME     => '',
    CONFIG_OBJECT     => {'ON_ERROR': 'SKIP'}
);

CALL MERIDIAN_PRODUCTION_ANOMALY!DETECT_ANOMALIES(
    INPUT_DATA        => TABLE(V_PRODUCTION_DETECT),
    SERIES_COLNAME    => 'BRANCH_ID',
    TIMESTAMP_COLNAME => 'MONTH_DATE',
    TARGET_COLNAME    => 'ROLLING3_FYAP',
    CONFIG_OBJECT     => {'prediction_interval': 0.99}
);

CREATE OR REPLACE TABLE PRODUCTION_ANOMALIES AS
WITH det AS (
  SELECT
    REPLACE(r.SERIES::VARCHAR, '"', '')                               AS BRANCH_ID,
    r.TS::DATE                                                        AS PRODUCTION_MONTH,
    r.Y::NUMBER(20,2)                                                 AS ACTUAL_ROLLING3_FYAP,
    r.FORECAST::NUMBER(20,2)                                          AS EXPECTED_ROLLING3_FYAP,
    r.LOWER_BOUND::NUMBER(20,2)                                       AS LOWER_BOUND_99,
    r.UPPER_BOUND::NUMBER(20,2)                                       AS UPPER_BOUND_99,
    r.IS_ANOMALY                                                      AS IS_ANOMALY,
    r.DISTANCE::FLOAT                                                 AS ANOMALY_DISTANCE
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) r
),
joined AS (
  SELECT
    d.BRANCH_ID,
    d.PRODUCTION_MONTH,
    -- single-month actual is what a branch manager recognises
    m.TOTAL_FYAP::NUMBER(20,2)                                        AS ACTUAL_FYAP,
    d.ACTUAL_ROLLING3_FYAP,
    d.EXPECTED_ROLLING3_FYAP                                          AS EXPECTED_FYAP,
    d.LOWER_BOUND_99,
    d.UPPER_BOUND_99,
    d.IS_ANOMALY,
    d.ANOMALY_DISTANCE,
    ROUND(100.0 * (d.ACTUAL_ROLLING3_FYAP - d.EXPECTED_ROLLING3_FYAP)
          / NULLIF(ABS(d.EXPECTED_ROLLING3_FYAP), 0), 2)               AS PCT_DEVIATION,
    CASE WHEN d.IS_ANOMALY AND d.ACTUAL_ROLLING3_FYAP > d.EXPECTED_ROLLING3_FYAP THEN 'SPIKE'
         WHEN d.IS_ANOMALY AND d.ACTUAL_ROLLING3_FYAP < d.EXPECTED_ROLLING3_FYAP THEN 'DROP'
         ELSE 'NORMAL' END                                             AS ANOMALY_TYPE
  FROM det d
  LEFT JOIN V_MONTHLY_REVENUE_BY_BRANCH m
         ON m.BRANCH_ID = d.BRANCH_ID AND m.MONTH_DATE::DATE = d.PRODUCTION_MONTH
),
-- gaps-and-islands: length of the consecutive same-direction anomaly run
runs AS (
  SELECT j.*,
         DATEDIFF(month, '2025-07-01'::DATE, PRODUCTION_MONTH)
           - ROW_NUMBER() OVER (PARTITION BY BRANCH_ID, ANOMALY_TYPE
                                ORDER BY PRODUCTION_MONTH) AS grp
  FROM joined j
  WHERE IS_ANOMALY
),
runlen AS (
  SELECT BRANCH_ID, PRODUCTION_MONTH, ANOMALY_TYPE,
         COUNT(*) OVER (PARTITION BY BRANCH_ID, ANOMALY_TYPE, grp) AS RUN_LENGTH
  FROM runs
)
SELECT j.*,
       COALESCE(r.RUN_LENGTH, 0)                        AS CONSECUTIVE_ANOMALY_MONTHS,
       -- a single flagged month on a 3-10 policy/month branch is usually
       -- noise; two consecutive months in the same direction is a signal
       COALESCE(r.RUN_LENGTH, 0) >= 2                   AS IS_CONFIRMED_ANOMALY,
       'M6_ml_anomaly_rolling3_v1'                      AS MODEL_VERSION,
       CURRENT_TIMESTAMP()                              AS GENERATED_AT
FROM joined j
LEFT JOIN runlen r
       ON r.BRANCH_ID = j.BRANCH_ID
      AND r.PRODUCTION_MONTH = j.PRODUCTION_MONTH
      AND r.ANOMALY_TYPE = j.ANOMALY_TYPE;

/* ---- Analyst-facing alert view -------------------------------------- */
CREATE OR REPLACE VIEW V_PRODUCTION_ANOMALY_ALERTS AS
SELECT
    a.BRANCH_ID, b.BRANCH_NAME, b.PROVINCE, b.REGION,
    a.PRODUCTION_MONTH, a.ANOMALY_TYPE,
    a.ACTUAL_FYAP, a.ACTUAL_ROLLING3_FYAP, a.EXPECTED_FYAP,
    a.LOWER_BOUND_99, a.UPPER_BOUND_99, a.PCT_DEVIATION, a.ANOMALY_DISTANCE,
    (a.ACTUAL_ROLLING3_FYAP - a.EXPECTED_FYAP)::NUMBER(20,2) AS FYAP_GAP
FROM PRODUCTION_ANOMALIES a
JOIN DIM_BRANCH b ON b.BRANCH_ID = a.BRANCH_ID
WHERE a.IS_ANOMALY;

/* ---- Verification: measured against the planted events -------------- */
WITH e AS (
  SELECT DISTINCT BRANCH_ID, EVENT_MONTH FROM GEN_BRANCH_MONTH_EVENT WHERE EVENT_MONTH >= '2025-07-01'
)
SELECT (SELECT COUNT(*) FROM PRODUCTION_ANOMALIES)                     AS detect_rows,
       (SELECT COUNT_IF(IS_ANOMALY) FROM PRODUCTION_ANOMALIES)         AS flagged,
       (SELECT COUNT(*) FROM e)                                        AS planted_event_months,
       (SELECT COUNT(*) FROM PRODUCTION_ANOMALIES a JOIN e
          ON e.BRANCH_ID = a.BRANCH_ID AND e.EVENT_MONTH = a.PRODUCTION_MONTH
        WHERE a.IS_ANOMALY)                                            AS true_positives,
       (SELECT COUNT(*) FROM PRODUCTION_ANOMALIES a LEFT JOIN e
          ON e.BRANCH_ID = a.BRANCH_ID AND e.EVENT_MONTH = a.PRODUCTION_MONTH
        WHERE a.IS_ANOMALY AND e.BRANCH_ID IS NULL)                    AS unplanted_flags;

SELECT a.BRANCH_ID, a.BRANCH_NAME, a.PRODUCTION_MONTH, a.ANOMALY_TYPE,
       a.PCT_DEVIATION, e.EVENT_LABEL AS planted_event
FROM V_PRODUCTION_ANOMALY_ALERTS a
LEFT JOIN (SELECT DISTINCT BRANCH_ID, EVENT_MONTH, EVENT_LABEL FROM GEN_BRANCH_MONTH_EVENT) e
       ON e.BRANCH_ID = a.BRANCH_ID AND e.EVENT_MONTH = a.PRODUCTION_MONTH
ORDER BY a.ANOMALY_TYPE, ABS(a.PCT_DEVIATION) DESC;
