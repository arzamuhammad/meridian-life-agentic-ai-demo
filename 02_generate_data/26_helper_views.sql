/* =====================================================================
   MERIDIAN LIFE — 26_helper_views.sql
   Reporting / anti-fan-out views consumed by the semantic view,
   the ML models and the Streamlit Command Center.

   V_BRANCH_ACHIEVEMENT is the ONLY sanctioned source of achievement %.
   It pre-aggregates production and target SEPARATELY before joining, so
   a target x production join can never fan out and inflate the numbers.
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

/* ---------------------------------------------------------------------
   1. V_BRANCH_PRODUCTION_YEARLY — one row per branch-year
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW V_BRANCH_PRODUCTION_YEARLY AS
SELECT
    p.BRANCH_ID,
    b.BRANCH_NAME,
    b.CITY,
    b.PROVINCE,
    b.REGION,
    p.PRODUCTION_YEAR                                   AS PRODUCTION_YEAR,
    SUM(p.FYAP)::NUMBER(20,2)                           AS ACTUAL_FYAP,
    SUM(p.TOTAL_ANNUAL_PREMIUM)::NUMBER(20,2)           AS ACTUAL_ANNUAL_PREMIUM,
    SUM(p.NEW_POLICIES)                                 AS ACTUAL_POLICIES,
    SUM(p.COMMISSION_AMOUNT)::NUMBER(20,2)              AS TOTAL_COMMISSION,
    COUNT(DISTINCT p.AGENT_ID)                          AS PRODUCING_AGENTS,
    COUNT(DISTINCT IFF(p.NEW_POLICIES > 0, p.AGENT_ID, NULL)) AS ACTIVE_AGENTS
FROM FACT_AGENT_PRODUCTION p
JOIN DIM_BRANCH b ON b.BRANCH_ID = p.BRANCH_ID
GROUP BY 1,2,3,4,5,6;

/* ---------------------------------------------------------------------
   2. V_BRANCH_ACHIEVEMENT — target vs actual, fan-out safe
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW V_BRANCH_ACHIEVEMENT AS
WITH prod AS (
    SELECT BRANCH_ID, PRODUCTION_YEAR AS FISCAL_YEAR,
           SUM(FYAP)         AS ACTUAL_FYAP,
           SUM(NEW_POLICIES) AS ACTUAL_POLICIES,
           COUNT(DISTINCT IFF(NEW_POLICIES > 0, AGENT_ID, NULL)) AS ACTIVE_AGENTS
    FROM FACT_AGENT_PRODUCTION
    GROUP BY 1,2
),
tgt AS (
    SELECT BRANCH_ID, TARGET_YEAR AS FISCAL_YEAR,
           SUM(TARGET_FYAP)     AS TARGET_FYAP,
           SUM(TARGET_POLICIES) AS TARGET_POLICIES,
           MAX(TARGET_ACTIVE_AGENTS) AS TARGET_ACTIVE_AGENTS
    FROM FACT_BRANCH_TARGET
    GROUP BY 1,2
)
SELECT
    t.BRANCH_ID,
    b.BRANCH_NAME,
    b.CITY,
    b.PROVINCE,
    b.REGION,
    b.BRANCH_TYPE,
    t.FISCAL_YEAR,
    t.TARGET_FYAP::NUMBER(20,2)                                   AS TARGET_FYAP,
    COALESCE(p.ACTUAL_FYAP, 0)::NUMBER(20,2)                      AS ACTUAL_FYAP,
    (COALESCE(p.ACTUAL_FYAP, 0) - t.TARGET_FYAP)::NUMBER(20,2)    AS FYAP_VARIANCE,
    ROUND(100.0 * COALESCE(p.ACTUAL_FYAP, 0) / NULLIF(t.TARGET_FYAP, 0), 2) AS ACHIEVEMENT_PCT,
    t.TARGET_POLICIES,
    COALESCE(p.ACTUAL_POLICIES, 0)                                AS ACTUAL_POLICIES,
    ROUND(100.0 * COALESCE(p.ACTUAL_POLICIES, 0) / NULLIF(t.TARGET_POLICIES, 0), 2) AS POLICY_ACHIEVEMENT_PCT,
    t.TARGET_ACTIVE_AGENTS,
    COALESCE(p.ACTIVE_AGENTS, 0)                                  AS ACTIVE_AGENTS,
    CASE
        WHEN COALESCE(p.ACTUAL_FYAP,0) / NULLIF(t.TARGET_FYAP,0) >= 1.10 THEN 'Exceeding'
        WHEN COALESCE(p.ACTUAL_FYAP,0) / NULLIF(t.TARGET_FYAP,0) >= 1.00 THEN 'On Target'
        WHEN COALESCE(p.ACTUAL_FYAP,0) / NULLIF(t.TARGET_FYAP,0) >= 0.80 THEN 'Slightly Below'
        WHEN COALESCE(p.ACTUAL_FYAP,0) / NULLIF(t.TARGET_FYAP,0) >= 0.60 THEN 'Below Target'
        ELSE 'Critically Below'
    END                                                           AS ACHIEVEMENT_BAND
FROM tgt t
JOIN DIM_BRANCH b ON b.BRANCH_ID = t.BRANCH_ID
LEFT JOIN prod p  ON p.BRANCH_ID = t.BRANCH_ID AND p.FISCAL_YEAR = t.FISCAL_YEAR;

/* ---------------------------------------------------------------------
   3. V_MONTHLY_REVENUE_BY_BRANCH — M2 forecast input.
      MUST contain ONLY series + timestamp + target (no exogenous cols),
      otherwise SNOWFLAKE.ML.FORECAST treats extras as features.
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW V_MONTHLY_REVENUE_BY_BRANCH AS
SELECT
    BRANCH_ID                                   AS BRANCH_ID,
    PRODUCTION_MONTH::TIMESTAMP_NTZ             AS MONTH_DATE,
    SUM(FYAP)::FLOAT                            AS TOTAL_FYAP
FROM FACT_AGENT_PRODUCTION
GROUP BY 1,2;

/* ---------------------------------------------------------------------
   4. V_DASHBOARD_KPIS — headline KPIs per fiscal year
      FYAP, persistency, loss ratio, active agents
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW V_DASHBOARD_KPIS AS
WITH yrs AS (SELECT 2023 AS FISCAL_YEAR UNION ALL SELECT 2024 UNION ALL SELECT 2025),
fyap AS (
    SELECT PRODUCTION_YEAR AS FISCAL_YEAR,
           SUM(FYAP) AS TOTAL_FYAP, SUM(NEW_POLICIES) AS NEW_POLICIES,
           COUNT(DISTINCT IFF(NEW_POLICIES > 0, AGENT_ID, NULL)) AS ACTIVE_AGENTS
    FROM FACT_AGENT_PRODUCTION GROUP BY 1
),
tgt AS (
    SELECT TARGET_YEAR AS FISCAL_YEAR, SUM(TARGET_FYAP) AS TOTAL_TARGET_FYAP
    FROM FACT_BRANCH_TARGET GROUP BY 1
),
-- 13-month persistency, reported on the MEASUREMENT year: of the policies
-- whose month-13 anniversary falls in year Y, what share had not lapsed by then?
pers AS (
    SELECT YEAR(DATEADD(month, 13, ISSUE_DATE)) AS FISCAL_YEAR,
           COUNT(*) AS cohort,
           COUNT_IF(POLICY_MONTH_AT_LAPSE IS NULL OR POLICY_MONTH_AT_LAPSE > 13) AS persisted
    FROM FACT_POLICY
    WHERE PAYMENT_MODE = 'Regular'
      AND DATEADD(month, 13, ISSUE_DATE) <= '2025-12-31'::DATE
    GROUP BY 1
),
prem AS (
    SELECT DUE_YEAR AS FISCAL_YEAR, SUM(PREMIUM_PAID_AMOUNT) AS PREMIUM_COLLECTED
    FROM FACT_POLICY_PAYMENT GROUP BY 1
),
clm AS (
    SELECT CLAIM_YEAR AS FISCAL_YEAR, SUM(APPROVED_AMOUNT) AS CLAIMS_PAID, COUNT(*) AS CLAIM_COUNT
    FROM FACT_CLAIMS GROUP BY 1
),
ag AS (
    SELECT COUNT(*) AS INFORCE_AGENTS FROM DIM_AGENT WHERE AGENT_STATUS = 'INFORCE'
)
SELECT
    y.FISCAL_YEAR,
    COALESCE(f.TOTAL_FYAP, 0)::NUMBER(20,2)                                  AS TOTAL_FYAP,
    COALESCE(t.TOTAL_TARGET_FYAP, 0)::NUMBER(20,2)                           AS TARGET_FYAP,
    ROUND(100.0 * COALESCE(f.TOTAL_FYAP,0) / NULLIF(t.TOTAL_TARGET_FYAP,0),2) AS ACHIEVEMENT_PCT,
    COALESCE(f.NEW_POLICIES, 0)                                              AS NEW_POLICIES,
    COALESCE(f.ACTIVE_AGENTS, 0)                                             AS ACTIVE_AGENTS,
    (SELECT INFORCE_AGENTS FROM ag)                                          AS INFORCE_AGENTS,
    ROUND(100.0 * p.persisted / NULLIF(p.cohort, 0), 2)                      AS PERSISTENCY_13M_PCT,
    COALESCE(pr.PREMIUM_COLLECTED, 0)::NUMBER(20,2)                          AS PREMIUM_COLLECTED,
    COALESCE(c.CLAIMS_PAID, 0)::NUMBER(20,2)                                 AS CLAIMS_PAID,
    COALESCE(c.CLAIM_COUNT, 0)                                               AS CLAIM_COUNT,
    ROUND(100.0 * COALESCE(c.CLAIMS_PAID,0) / NULLIF(pr.PREMIUM_COLLECTED,0), 2) AS LOSS_RATIO_PCT
FROM yrs y
LEFT JOIN fyap f ON f.FISCAL_YEAR = y.FISCAL_YEAR
LEFT JOIN tgt  t ON t.FISCAL_YEAR = y.FISCAL_YEAR
LEFT JOIN pers p ON p.FISCAL_YEAR = y.FISCAL_YEAR
LEFT JOIN prem pr ON pr.FISCAL_YEAR = y.FISCAL_YEAR
LEFT JOIN clm  c ON c.FISCAL_YEAR = y.FISCAL_YEAR;

/* ---------------------------------------------------------------------
   5. V_WEEKLY_PLAN_VS_ACTUAL — plan pro-rated to ISO week
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW V_WEEKLY_PLAN_VS_ACTUAL AS
WITH act AS (
    SELECT p.BRANCH_ID,
           DATE_TRUNC('week', p.ISSUE_DATE) AS WEEK_START,
           YEAR(p.ISSUE_DATE)               AS FISCAL_YEAR,
           SUM(p.FYAP)                      AS ACTUAL_FYAP,
           COUNT(*)                         AS ACTUAL_POLICIES
    FROM FACT_POLICY p
    GROUP BY 1,2,3
),
wk AS (   -- number of ISO weeks actually present per branch-year
    SELECT BRANCH_ID, FISCAL_YEAR, COUNT(*) AS week_cnt FROM act GROUP BY 1,2
),
tgt AS (
    SELECT BRANCH_ID, TARGET_YEAR AS FISCAL_YEAR, SUM(TARGET_FYAP) AS TARGET_FYAP
    FROM FACT_BRANCH_TARGET GROUP BY 1,2
)
SELECT
    a.BRANCH_ID,
    b.BRANCH_NAME,
    b.PROVINCE,
    a.WEEK_START,
    a.FISCAL_YEAR,
    a.ACTUAL_FYAP::NUMBER(20,2)                                     AS ACTUAL_FYAP,
    a.ACTUAL_POLICIES,
    ROUND(t.TARGET_FYAP / NULLIF(w.week_cnt, 0), 2)::NUMBER(20,2)   AS PLAN_FYAP,
    ROUND(a.ACTUAL_FYAP - t.TARGET_FYAP / NULLIF(w.week_cnt,0), 2)::NUMBER(20,2) AS WEEKLY_VARIANCE,
    ROUND(100.0 * a.ACTUAL_FYAP / NULLIF(t.TARGET_FYAP / NULLIF(w.week_cnt,0), 0), 2) AS WEEKLY_ACHIEVEMENT_PCT
FROM act a
JOIN DIM_BRANCH b ON b.BRANCH_ID = a.BRANCH_ID
LEFT JOIN wk  w ON w.BRANCH_ID = a.BRANCH_ID AND w.FISCAL_YEAR = a.FISCAL_YEAR
LEFT JOIN tgt t ON t.BRANCH_ID = a.BRANCH_ID AND t.FISCAL_YEAR = a.FISCAL_YEAR;

/* ---------------------------------------------------------------------
   6. V_BRANCH_VARIANCE — monthly variance + MoM/YoY movement,
      the drill-down feed for "why is this branch behind plan?"
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW V_BRANCH_VARIANCE AS
WITH m AS (
    SELECT p.BRANCH_ID, p.PRODUCTION_MONTH, p.PRODUCTION_YEAR,
           SUM(p.FYAP)         AS ACTUAL_FYAP,
           SUM(p.NEW_POLICIES) AS ACTUAL_POLICIES,
           COUNT(DISTINCT IFF(p.NEW_POLICIES > 0, p.AGENT_ID, NULL)) AS ACTIVE_AGENTS
    FROM FACT_AGENT_PRODUCTION p
    GROUP BY 1,2,3
),
tgt AS (
    SELECT BRANCH_ID, TARGET_YEAR, SUM(TARGET_FYAP) / 12.0 AS MONTHLY_PLAN_FYAP
    FROM FACT_BRANCH_TARGET GROUP BY 1,2
)
SELECT
    m.BRANCH_ID,
    b.BRANCH_NAME,
    b.PROVINCE,
    b.REGION,
    m.PRODUCTION_MONTH,
    m.PRODUCTION_YEAR,
    m.ACTUAL_FYAP::NUMBER(20,2)                                        AS ACTUAL_FYAP,
    ROUND(t.MONTHLY_PLAN_FYAP, 2)::NUMBER(20,2)                        AS MONTHLY_PLAN_FYAP,
    ROUND(m.ACTUAL_FYAP - t.MONTHLY_PLAN_FYAP, 2)::NUMBER(20,2)        AS VARIANCE_FYAP,
    ROUND(100.0 * m.ACTUAL_FYAP / NULLIF(t.MONTHLY_PLAN_FYAP, 0), 2)   AS MONTHLY_ACHIEVEMENT_PCT,
    m.ACTUAL_POLICIES,
    m.ACTIVE_AGENTS,
    LAG(m.ACTUAL_FYAP) OVER (PARTITION BY m.BRANCH_ID ORDER BY m.PRODUCTION_MONTH)::NUMBER(20,2) AS PREV_MONTH_FYAP,
    ROUND(100.0 * (m.ACTUAL_FYAP - LAG(m.ACTUAL_FYAP) OVER (PARTITION BY m.BRANCH_ID ORDER BY m.PRODUCTION_MONTH))
          / NULLIF(LAG(m.ACTUAL_FYAP) OVER (PARTITION BY m.BRANCH_ID ORDER BY m.PRODUCTION_MONTH), 0), 2) AS MOM_CHANGE_PCT,
    ROUND(100.0 * (m.ACTUAL_FYAP - LAG(m.ACTUAL_FYAP, 12) OVER (PARTITION BY m.BRANCH_ID ORDER BY m.PRODUCTION_MONTH))
          / NULLIF(LAG(m.ACTUAL_FYAP, 12) OVER (PARTITION BY m.BRANCH_ID ORDER BY m.PRODUCTION_MONTH), 0), 2) AS YOY_CHANGE_PCT
FROM m
JOIN DIM_BRANCH b ON b.BRANCH_ID = m.BRANCH_ID
LEFT JOIN tgt t ON t.BRANCH_ID = m.BRANCH_ID AND t.TARGET_YEAR = m.PRODUCTION_YEAR;

/* ---------------------------------------------------------------------
   Verification
   --------------------------------------------------------------------- */
SELECT * FROM V_DASHBOARD_KPIS ORDER BY FISCAL_YEAR;
