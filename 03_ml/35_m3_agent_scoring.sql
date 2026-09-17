/* =====================================================================
   MERIDIAN LIFE — 35_m3_agent_scoring.sql
   M3: agent performance composite score (deterministic, auditable SQL).

     Production 50%  +  Activity 20%  +  Training 15%  +  Retention 15%

   Each component is converted to a 0-100 PERCENT_RANK inside the scored
   population, so the composite is comparable across branches of very
   different size. Only INFORCE agents are scored.

   IMPORTANT: there is NO per-agent target in this data model (targets exist
   only at branch level), so M3 is deliberately BEHAVIOUR-based, not
   achievement-based. It complements branch achievement, it does not
   replace it.
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

CREATE OR REPLACE TABLE AGENT_PERFORMANCE_SCORES AS
WITH agents AS (
    SELECT a.AGENT_ID, a.AGENT_NAME, a.BRANCH_ID, a.AGENT_LEVEL, a.JOIN_DATE,
           a.LEADER_ID, b.BRANCH_NAME, b.PROVINCE, b.REGION
    FROM DIM_AGENT a
    JOIN DIM_BRANCH b ON b.BRANCH_ID = a.BRANCH_ID
    WHERE a.AGENT_STATUS = 'INFORCE'
),
/* ---- production: trailing 12 months (calendar 2025) ---------------- */
prod AS (
    SELECT AGENT_ID,
           SUM(FYAP)          AS FYAP_12M,
           SUM(NEW_POLICIES)  AS POLICIES_12M,
           COUNT_IF(NEW_POLICIES > 0) AS PRODUCTIVE_MONTHS_12M,
           SUM(COMMISSION_AMOUNT) AS COMMISSION_12M
    FROM FACT_AGENT_PRODUCTION
    WHERE PRODUCTION_MONTH >= '2025-01-01'
    GROUP BY 1
),
/* ---- activity ------------------------------------------------------ */
act AS (
    SELECT AGENT_ID,
           COUNT(*)                                  AS ACTIVITIES_12M,
           COUNT_IF(IS_QUALIFIED_LEAD)               AS QUALIFIED_LEADS_12M,
           COUNT_IF(ACTIVITY_OUTCOME = 'Closed Won') AS CLOSED_WON_12M,
           COUNT(DISTINCT ACTIVITY_MONTH)            AS ACTIVE_MONTHS_12M
    FROM FACT_AGENT_ACTIVITY
    WHERE ACTIVITY_DATE >= '2025-01-01'
    GROUP BY 1
),
/* ---- app engagement (secondary activity signal) -------------------- */
app AS (
    SELECT AGENT_ID,
           COUNT(*)                                AS APP_EVENTS_12M,
           COUNT_IF(IS_RECOMMENDATION_ACTED)       AS RECOMMENDATIONS_ACTED_12M
    FROM FACT_AGENT_APPS_BEHAVIOR
    WHERE EVENT_DATE >= '2025-01-01'
    GROUP BY 1
),
/* ---- training ------------------------------------------------------ */
trn AS (
    SELECT AGENT_ID,
           COUNT_IF(COMPLETION_STATUS = 'Completed')                  AS COURSES_COMPLETED,
           AVG(IFF(COMPLETION_STATUS = 'Completed', SCORE, NULL))     AS AVG_TRAINING_SCORE,
           COUNT_IF(IS_CERTIFICATION AND COMPLETION_STATUS = 'Completed') AS CERTIFICATIONS
    FROM FACT_TRAINING
    GROUP BY 1
),
/* ---- retention quality of the agent's own book --------------------- */
ret AS (
    SELECT AGENT_ID,
           COUNT(*)                                     AS POLICIES_WRITTEN,
           COUNT_IF(POLICY_STATUS = 'Lapsed')           AS POLICIES_LAPSED,
           1.0 - (COUNT_IF(POLICY_STATUS = 'Lapsed') / NULLIF(COUNT(*), 0)) AS PERSISTENCY_RATIO
    FROM FACT_POLICY
    GROUP BY 1
),
raw AS (
    SELECT
        ag.*,
        COALESCE(p.FYAP_12M, 0)                AS FYAP_12M,
        COALESCE(p.POLICIES_12M, 0)            AS POLICIES_12M,
        COALESCE(p.PRODUCTIVE_MONTHS_12M, 0)   AS PRODUCTIVE_MONTHS_12M,
        COALESCE(p.COMMISSION_12M, 0)          AS COMMISSION_12M,
        COALESCE(c.ACTIVITIES_12M, 0)          AS ACTIVITIES_12M,
        COALESCE(c.QUALIFIED_LEADS_12M, 0)     AS QUALIFIED_LEADS_12M,
        COALESCE(c.CLOSED_WON_12M, 0)          AS CLOSED_WON_12M,
        COALESCE(c.ACTIVE_MONTHS_12M, 0)       AS ACTIVE_MONTHS_12M,
        COALESCE(ap.APP_EVENTS_12M, 0)         AS APP_EVENTS_12M,
        COALESCE(ap.RECOMMENDATIONS_ACTED_12M, 0) AS RECOMMENDATIONS_ACTED_12M,
        COALESCE(t.COURSES_COMPLETED, 0)       AS COURSES_COMPLETED,
        t.AVG_TRAINING_SCORE                   AS AVG_TRAINING_SCORE,
        COALESCE(t.CERTIFICATIONS, 0)          AS CERTIFICATIONS,
        COALESCE(r.POLICIES_WRITTEN, 0)        AS POLICIES_WRITTEN,
        COALESCE(r.POLICIES_LAPSED, 0)         AS POLICIES_LAPSED,
        -- agents with no book yet are treated as neutral, not perfect
        COALESCE(r.PERSISTENCY_RATIO, 0.85)    AS PERSISTENCY_RATIO,
        -- composite raw inputs
        COALESCE(p.FYAP_12M, 0)                                              AS PROD_RAW,
        COALESCE(c.ACTIVITIES_12M, 0) + 3 * COALESCE(c.QUALIFIED_LEADS_12M, 0)
          + 0.05 * COALESCE(ap.APP_EVENTS_12M, 0)                            AS ACT_RAW,
        10 * COALESCE(t.COURSES_COMPLETED, 0) + COALESCE(t.AVG_TRAINING_SCORE, 0)
          + 15 * COALESCE(t.CERTIFICATIONS, 0)                               AS TRN_RAW,
        COALESCE(r.PERSISTENCY_RATIO, 0.85)                                  AS RET_RAW
    FROM agents ag
    LEFT JOIN prod p ON p.AGENT_ID = ag.AGENT_ID
    LEFT JOIN act  c ON c.AGENT_ID = ag.AGENT_ID
    LEFT JOIN app ap ON ap.AGENT_ID = ag.AGENT_ID
    LEFT JOIN trn  t ON t.AGENT_ID = ag.AGENT_ID
    LEFT JOIN ret  r ON r.AGENT_ID = ag.AGENT_ID
),
scored AS (
    SELECT raw.*,
           ROUND(100.0 * PERCENT_RANK() OVER (ORDER BY PROD_RAW), 2) AS PRODUCTION_SCORE,
           ROUND(100.0 * PERCENT_RANK() OVER (ORDER BY ACT_RAW),  2) AS ACTIVITY_SCORE,
           ROUND(100.0 * PERCENT_RANK() OVER (ORDER BY TRN_RAW),  2) AS TRAINING_SCORE,
           ROUND(100.0 * PERCENT_RANK() OVER (ORDER BY RET_RAW),  2) AS RETENTION_SCORE
    FROM raw
),
final AS (
    SELECT s.*,
           ROUND(0.50 * PRODUCTION_SCORE
               + 0.20 * ACTIVITY_SCORE
               + 0.15 * TRAINING_SCORE
               + 0.15 * RETENTION_SCORE, 2) AS COMPOSITE_SCORE
    FROM scored s
)
SELECT
    AGENT_ID, AGENT_NAME, BRANCH_ID, BRANCH_NAME, PROVINCE, REGION,
    AGENT_LEVEL, LEADER_ID, JOIN_DATE,
    DATEDIFF(month, JOIN_DATE, '2025-12-31'::DATE)          AS TENURE_MONTHS,
    FYAP_12M::NUMBER(20,2)                                  AS FYAP_12M,
    POLICIES_12M, PRODUCTIVE_MONTHS_12M,
    COMMISSION_12M::NUMBER(20,2)                            AS COMMISSION_12M,
    ACTIVITIES_12M, QUALIFIED_LEADS_12M, CLOSED_WON_12M, ACTIVE_MONTHS_12M,
    APP_EVENTS_12M, RECOMMENDATIONS_ACTED_12M,
    COURSES_COMPLETED, ROUND(AVG_TRAINING_SCORE, 1) AS AVG_TRAINING_SCORE, CERTIFICATIONS,
    POLICIES_WRITTEN, POLICIES_LAPSED,
    ROUND(100.0 * PERSISTENCY_RATIO, 2)                     AS PERSISTENCY_PCT,
    PRODUCTION_SCORE, ACTIVITY_SCORE, TRAINING_SCORE, RETENTION_SCORE,
    COMPOSITE_SCORE,
    CASE WHEN COMPOSITE_SCORE >= 75 THEN 'TOP_PERFORMER'
         WHEN COMPOSITE_SCORE >= 50 THEN 'SOLID'
         WHEN COMPOSITE_SCORE >= 25 THEN 'NEEDS_COACHING'
         ELSE 'AT_RISK' END                                  AS PERFORMANCE_CATEGORY,
    RANK() OVER (ORDER BY COMPOSITE_SCORE DESC)              AS RANK_OVERALL,
    RANK() OVER (PARTITION BY BRANCH_ID ORDER BY COMPOSITE_SCORE DESC) AS RANK_IN_BRANCH,
    '2025-12-31'::DATE                                       AS ASOF_DATE,
    'M3_composite_v1'                                        AS MODEL_VERSION
FROM final;

/* ---- Verification --------------------------------------------------- */
SELECT PERFORMANCE_CATEGORY, COUNT(*) AS agents,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct,
       ROUND(MIN(COMPOSITE_SCORE), 1) AS min_score,
       ROUND(MAX(COMPOSITE_SCORE), 1) AS max_score,
       ROUND(AVG(FYAP_12M) / 1e6, 1)  AS avg_fyap_rp_m
FROM AGENT_PERFORMANCE_SCORES
GROUP BY 1 ORDER BY min_score DESC;

SELECT AGENT_ID, AGENT_NAME, BRANCH_NAME, AGENT_LEVEL, COMPOSITE_SCORE,
       PRODUCTION_SCORE, ACTIVITY_SCORE, TRAINING_SCORE, RETENTION_SCORE,
       PERFORMANCE_CATEGORY
FROM AGENT_PERFORMANCE_SCORES ORDER BY COMPOSITE_SCORE DESC LIMIT 5;
