/* =====================================================================
   MERIDIAN LIFE — 27_verify_stop1.sql
   STOP 1 gate: row counts for all 14 foundation tables + proof that the
   designed patterns (a)-(g) are actually present in the generated data.
   Run this any time to re-validate the data foundation.
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

/* ---- 1. Row counts vs target ---------------------------------------- */
WITH actual AS (
  SELECT 'DIM_BRANCH' t, COUNT(*) n FROM DIM_BRANCH
  UNION ALL SELECT 'DIM_AGENT',                COUNT(*) FROM DIM_AGENT
  UNION ALL SELECT 'DIM_CUSTOMER',             COUNT(*) FROM DIM_CUSTOMER
  UNION ALL SELECT 'DIM_PRODUCT',              COUNT(*) FROM DIM_PRODUCT
  UNION ALL SELECT 'FACT_POLICY',              COUNT(*) FROM FACT_POLICY
  UNION ALL SELECT 'FACT_POLICY_PAYMENT',      COUNT(*) FROM FACT_POLICY_PAYMENT
  UNION ALL SELECT 'FACT_POLICY_RIDER',        COUNT(*) FROM FACT_POLICY_RIDER
  UNION ALL SELECT 'FACT_CLAIMS',              COUNT(*) FROM FACT_CLAIMS
  UNION ALL SELECT 'FACT_AGENT_PRODUCTION',    COUNT(*) FROM FACT_AGENT_PRODUCTION
  UNION ALL SELECT 'FACT_AGENT_ACTIVITY',      COUNT(*) FROM FACT_AGENT_ACTIVITY
  UNION ALL SELECT 'FACT_AGENT_APPS_BEHAVIOR', COUNT(*) FROM FACT_AGENT_APPS_BEHAVIOR
  UNION ALL SELECT 'FACT_TRAINING',            COUNT(*) FROM FACT_TRAINING
  UNION ALL SELECT 'FACT_BRANCH_TARGET',       COUNT(*) FROM FACT_BRANCH_TARGET
  UNION ALL SELECT 'FACT_CRM_TICKETS',         COUNT(*) FROM FACT_CRM_TICKETS
), tgt AS (
  SELECT * FROM VALUES
   ('DIM_BRANCH',23),('DIM_AGENT',1500),('DIM_CUSTOMER',4400),('DIM_PRODUCT',70),
   ('FACT_POLICY',7400),('FACT_POLICY_PAYMENT',45000),('FACT_POLICY_RIDER',10600),
   ('FACT_CLAIMS',2150),('FACT_AGENT_PRODUCTION',12650),('FACT_AGENT_ACTIVITY',100000),
   ('FACT_AGENT_APPS_BEHAVIOR',100000),('FACT_TRAINING',3400),('FACT_BRANCH_TARGET',66),
   ('FACT_CRM_TICKETS',2450) AS v(t,target)
)
SELECT a.t AS table_name, a.n AS actual_rows, g.target AS target_rows,
       ROUND(100.0 * a.n / g.target - 100, 1) AS pct_vs_target
FROM actual a JOIN tgt g ON g.t = a.t ORDER BY a.t;

/* ---- 2. Pattern (a): month-13 danger zone, censoring-corrected -------
   Raw lapse counts under-state the month-25 echo because policies issued
   after 2023-11 cannot reach month 25 before the 2025-12-31 cut-off.
   The correct measure is the monthly HAZARD = lapses / at-risk.        */
WITH obs AS (
  SELECT POLICY_MONTH_AT_LAPSE AS pm,
         DATEDIFF(month, ISSUE_DATE, '2025-12-31'::DATE) AS obsv
  FROM FACT_POLICY WHERE PAYMENT_MODE = 'Regular'
), m AS (SELECT SEQ4() + 2 AS pm FROM TABLE(GENERATOR(ROWCOUNT => 34))),
h AS (
  SELECT m.pm AS policy_month,
         COUNT_IF(o.obsv >= m.pm AND (o.pm IS NULL OR o.pm >= m.pm)) AS at_risk,
         COUNT_IF(o.pm = m.pm)                                       AS lapses
  FROM m CROSS JOIN obs o GROUP BY 1 HAVING at_risk > 100
), z AS (SELECT AVG(100.0 * lapses / at_risk) AS base FROM h WHERE policy_month NOT IN (13, 25))
SELECT policy_month, at_risk, lapses,
       ROUND(100.0 * lapses / at_risk, 2)                        AS hazard_pct,
       ROUND((100.0 * lapses / at_risk) / (SELECT base FROM z), 1) AS x_vs_baseline
FROM h WHERE policy_month IN (11,12,13,14,23,24,25,26) ORDER BY policy_month;

/* ---- 3. Pattern (b): lapse rate ordered by payment frequency -------- */
SELECT PAYMENT_FREQUENCY, COUNT(*) AS policies,
       ROUND(100.0 * COUNT_IF(POLICY_STATUS = 'Lapsed') / COUNT(*), 2) AS lapse_pct
FROM FACT_POLICY GROUP BY 1 ORDER BY lapse_pct;

/* ---- 4. Pattern (c): 2025 branch achievement spread ----------------- */
SELECT BRANCH_ID, BRANCH_NAME, PROVINCE,
       TARGET_FYAP, ACTUAL_FYAP, ACHIEVEMENT_PCT, ACHIEVEMENT_BAND
FROM V_BRANCH_ACHIEVEMENT WHERE FISCAL_YEAR = 2025 ORDER BY ACHIEVEMENT_PCT;

/* ---- 5. Pattern (d): cross-class co-occurrence lift > 1 ------------- */
WITH cp AS (
  SELECT DISTINCT p.CUSTOMER_ID, d.CLASSIFICATION
  FROM FACT_POLICY p JOIN DIM_PRODUCT d USING (PRODUCT_ID)
), tot AS (SELECT COUNT(DISTINCT CUSTOMER_ID) AS n FROM cp),
sup AS (SELECT CLASSIFICATION, COUNT(*) AS c FROM cp GROUP BY 1),
pair AS (
  SELECT a.CLASSIFICATION AS ant, b.CLASSIFICATION AS con, COUNT(*) AS both_cnt
  FROM cp a JOIN cp b ON a.CUSTOMER_ID = b.CUSTOMER_ID AND a.CLASSIFICATION <> b.CLASSIFICATION
  GROUP BY 1,2
)
SELECT p.ant AS antecedent, p.con AS consequent, p.both_cnt,
       ROUND(1.0 * p.both_cnt / sa.c, 3) AS confidence,
       ROUND((1.0 * p.both_cnt / sa.c) / (1.0 * sc.c / (SELECT n FROM tot)), 3) AS lift
FROM pair p JOIN sup sa ON sa.CLASSIFICATION = p.ant JOIN sup sc ON sc.CLASSIFICATION = p.con
WHERE p.both_cnt >= 40 ORDER BY lift DESC LIMIT 10;

/* ---- 6. Pattern (e): H2-2025 production spikes and drops ------------ */
SELECT v.BRANCH_ID, v.BRANCH_NAME, v.PRODUCTION_MONTH,
       v.ACTUAL_FYAP, v.MOM_CHANGE_PCT, e.EVENT_LABEL
FROM V_BRANCH_VARIANCE v
JOIN GEN_BRANCH_MONTH_EVENT e
  ON e.BRANCH_ID = v.BRANCH_ID AND e.EVENT_MONTH = v.PRODUCTION_MONTH
ORDER BY v.MOM_CHANGE_PCT DESC;

/* ---- 7. Pattern (f): CRM tickets concentrated on lapse-risk policies  */
SELECT IS_RETENTION_RELATED, COUNT(*) AS tickets,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM FACT_CRM_TICKETS GROUP BY 1;

/* ---- 8. Pattern (g): right-skewed premium distribution -------------- */
SELECT COUNT(*) AS policies,
       MIN(ANNUAL_PREMIUM)                        AS min_premium,
       APPROX_PERCENTILE(ANNUAL_PREMIUM, 0.50)    AS median_premium,
       APPROX_PERCENTILE(ANNUAL_PREMIUM, 0.99)    AS p99_premium,
       MAX(ANNUAL_PREMIUM)                        AS max_premium,
       ROUND(AVG(ANNUAL_PREMIUM) / APPROX_PERCENTILE(ANNUAL_PREMIUM, 0.5), 2) AS mean_over_median
FROM FACT_POLICY;

/* ---- 9. Referential integrity (must all be 0) ----------------------- */
SELECT 'policy -> customer' AS check_name,
       COUNT_IF(c.CUSTOMER_ID IS NULL) AS orphans
FROM FACT_POLICY p LEFT JOIN DIM_CUSTOMER c USING (CUSTOMER_ID)
UNION ALL
SELECT 'policy -> product', COUNT_IF(d.PRODUCT_ID IS NULL)
FROM FACT_POLICY p LEFT JOIN DIM_PRODUCT d USING (PRODUCT_ID)
UNION ALL
SELECT 'policy -> agent', COUNT_IF(a.AGENT_ID IS NULL)
FROM FACT_POLICY p LEFT JOIN DIM_AGENT a USING (AGENT_ID)
UNION ALL
SELECT 'policy -> branch', COUNT_IF(b.BRANCH_ID IS NULL)
FROM FACT_POLICY p LEFT JOIN DIM_BRANCH b USING (BRANCH_ID)
UNION ALL
SELECT 'payment -> policy', COUNT_IF(p.POLICY_ID IS NULL)
FROM FACT_POLICY_PAYMENT y LEFT JOIN FACT_POLICY p USING (POLICY_ID)
UNION ALL
SELECT 'claim -> policy', COUNT_IF(p.POLICY_ID IS NULL)
FROM FACT_CLAIMS c LEFT JOIN FACT_POLICY p USING (POLICY_ID)
UNION ALL
SELECT 'ticket -> policy', COUNT_IF(p.POLICY_ID IS NULL)
FROM FACT_CRM_TICKETS t LEFT JOIN FACT_POLICY p USING (POLICY_ID)
UNION ALL
SELECT 'production FYAP != policy FYAP',
       IFF((SELECT SUM(FYAP) FROM FACT_AGENT_PRODUCTION) = (SELECT SUM(FYAP) FROM FACT_POLICY), 0, 1);

/* ---- 10. Headline KPIs ---------------------------------------------- */
SELECT * FROM V_DASHBOARD_KPIS ORDER BY FISCAL_YEAR;
