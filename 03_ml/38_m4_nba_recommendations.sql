/* =====================================================================
   MERIDIAN LIFE — 38_m4_nba_recommendations.sql
   M4 (v3): Next-Best-Action rule engine over the ML outputs.

   DESIGN
     Deterministic SQL CASE rules on top of ML signals. NO LLM in the batch
     path, so every row is auditable and reproducible. The Cortex Agent does
     the interactive LLM reasoning and writes into the SAME table.

   ENRICHMENTS (A-G)
     A  per-policy / per-customer granularity (names the exact policy)
     B  specific cross-sell class from M7 with its lift
     C  data-driven EXPECTED_VALUE (real premium / class average / gap)
     D  URGENCY_SCORE 0-100 to rank the whole queue across action types
     E  multi-recommendation per agent (one row per signal, not a cascade)
     F  CLV priority (PLATINUM -> HIGH, GOLD -> MEDIUM)
     G  CRM ticket signal boosts retention urgency

   URGENCY FORMULAS
     RETENTION_CALL      lapse_prob*100 * CLV_factor * ticket_factor (cap 100)
     RENEWAL_FOLLOW_UP   40 + (60 - days_to_renewal)/60 * 20
     CROSS_SELL          30 + lift_norm*15 + CLV_bonus
     COACHING_ACTIVITY   50
     REACTIVATION        55
     BRANCH_BELOW_TARGET 70 + (1 - achievement) * 30
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

/* ---- branch context the agent and the rules both read ---------------- */
CREATE OR REPLACE VIEW BRANCH_NBA_CONTEXT AS
SELECT
    a.BRANCH_ID, a.BRANCH_NAME, a.PROVINCE, a.REGION, a.BRANCH_TYPE,
    a.FISCAL_YEAR, a.TARGET_FYAP, a.ACTUAL_FYAP, a.FYAP_VARIANCE,
    a.ACHIEVEMENT_PCT, a.ACHIEVEMENT_BAND, a.ACTIVE_AGENTS,
    an.ANOMALY_TYPE                AS LATEST_ANOMALY_TYPE,
    an.PRODUCTION_MONTH            AS LATEST_ANOMALY_MONTH,
    an.PCT_DEVIATION               AS LATEST_ANOMALY_DEVIATION
FROM V_BRANCH_ACHIEVEMENT a
LEFT JOIN (
    SELECT BRANCH_ID, ANOMALY_TYPE, PRODUCTION_MONTH, PCT_DEVIATION
    FROM PRODUCTION_ANOMALIES
    WHERE IS_ANOMALY
    QUALIFY ROW_NUMBER() OVER (PARTITION BY BRANCH_ID ORDER BY PRODUCTION_MONTH DESC) = 1
) an ON an.BRANCH_ID = a.BRANCH_ID
WHERE a.FISCAL_YEAR = 2025;

CREATE OR REPLACE TABLE AI_RECOMMENDATIONS (
    RECOMMENDATION_ID   VARCHAR(40),
    GENERATED_AT        TIMESTAMP_NTZ,
    ASOF_DATE           DATE,
    RECOMMENDATION_TYPE VARCHAR(40),
    URGENCY_SCORE       FLOAT,
    PRIORITY            VARCHAR(10),
    AGENT_ID            VARCHAR(20),
    AGENT_NAME          VARCHAR(80),
    BRANCH_ID           VARCHAR(10),
    BRANCH_NAME         VARCHAR(80),
    CUSTOMER_ID         VARCHAR(20),
    CUSTOMER_NAME       VARCHAR(120),
    POLICY_ID           VARCHAR(20),
    TITLE               VARCHAR(200),
    RECOMMENDED_ACTION  VARCHAR(1000),
    REASON              VARCHAR(1000),
    EXPECTED_VALUE      NUMBER(20,2),
    SIGNAL_SOURCE       VARCHAR(60),
    STATUS              VARCHAR(20),
    CREATED_BY          VARCHAR(40)
) COMMENT = 'M4 Next-Best-Action queue. Written by the batch rule engine AND by the Cortex Agent.';

/* =====================================================================
   Rule 1 — RETENTION_CALL (per policy, from M1 + M5 + CRM tickets)
   ===================================================================== */
INSERT INTO AI_RECOMMENDATIONS
WITH r AS (
    SELECT
        l.POLICY_ID, l.CUSTOMER_ID, l.AGENT_ID, l.BRANCH_ID,
        l.LAPSE_PROBABILITY, l.RISK_SEGMENT, l.IS_DANGER_ZONE, l.TENURE_MONTHS,
        l.ANNUAL_PREMIUM, l.PAYMENT_FREQUENCY, l.LATE_CNT_365D, l.UNPAID_CNT_90D,
        l.RETENTION_TICKET_365D,
        a.AGENT_NAME, b.BRANCH_NAME, c.CUSTOMER_NAME,
        COALESCE(v.CLV_SEGMENT, 'BRONZE') AS CLV_SEGMENT,
        CASE COALESCE(v.CLV_SEGMENT, 'BRONZE')
             WHEN 'PLATINUM' THEN 1.30 WHEN 'GOLD' THEN 1.15
             WHEN 'SILVER'   THEN 1.00 ELSE 0.90 END AS CLV_FACTOR,
        IFF(l.RETENTION_TICKET_365D > 0, 1.15, 1.00) AS TICKET_FACTOR
    FROM LAPSE_RISK_SCORES l
    JOIN DIM_AGENT    a ON a.AGENT_ID    = l.AGENT_ID
    JOIN DIM_BRANCH   b ON b.BRANCH_ID   = l.BRANCH_ID
    JOIN DIM_CUSTOMER c ON c.CUSTOMER_ID = l.CUSTOMER_ID
    LEFT JOIN CUSTOMER_CLV_SCORES v ON v.CUSTOMER_ID = l.CUSTOMER_ID
    WHERE l.RISK_SEGMENT IN ('MEDIUM','HIGH','CRITICAL')
)
SELECT
    'REC-RET-' || POLICY_ID,
    CURRENT_TIMESTAMP(), '2025-12-01'::DATE,
    'RETENTION_CALL',
    LEAST(100, ROUND(LAPSE_PROBABILITY * 100 * CLV_FACTOR * TICKET_FACTOR, 2)),
    CASE WHEN CLV_SEGMENT = 'PLATINUM' THEN 'HIGH'
         WHEN LEAST(100, LAPSE_PROBABILITY*100*CLV_FACTOR*TICKET_FACTOR) >= 70 THEN 'HIGH'
         WHEN CLV_SEGMENT = 'GOLD' THEN 'MEDIUM'
         WHEN LEAST(100, LAPSE_PROBABILITY*100*CLV_FACTOR*TICKET_FACTOR) >= 30 THEN 'MEDIUM'
         ELSE 'LOW' END,
    AGENT_ID, AGENT_NAME, BRANCH_ID, BRANCH_NAME, CUSTOMER_ID, CUSTOMER_NAME, POLICY_ID,
    'Retention call: ' || CUSTOMER_NAME || ' (' || POLICY_ID || ') at ' ||
        ROUND(LAPSE_PROBABILITY * 100, 1) || '% lapse risk',
    'Call ' || CUSTOMER_NAME || ' about policy ' || POLICY_ID ||
        '. Confirm the ' || PAYMENT_FREQUENCY || ' premium of Rp ' ||
        TO_VARCHAR(ANNUAL_PREMIUM, '999,999,999') ||
        ' and offer to move them to auto-debit' ||
        IFF(IS_DANGER_ZONE, '. This policy is in the month-13 danger zone - secure the first renewal.', '.'),
    'M1 lapse probability ' || ROUND(LAPSE_PROBABILITY * 100, 1) || '% (' || RISK_SEGMENT ||
        '); tenure ' || TENURE_MONTHS || ' months; ' || LATE_CNT_365D::INT ||
        ' late payments in 12m; ' || UNPAID_CNT_90D::INT || ' unpaid in 90d; CLV segment ' || CLV_SEGMENT ||
        IFF(RETENTION_TICKET_365D > 0, '; customer already raised a retention ticket', ''),
    ANNUAL_PREMIUM,
    'M1_LAPSE + M5_CLV' || IFF(RETENTION_TICKET_365D > 0, ' + CRM_TICKETS', ''),
    'OPEN', 'M4_RULE_ENGINE'
FROM r;

/* =====================================================================
   Rule 2 — RENEWAL_FOLLOW_UP (per policy, renewal due within 60 days)
   ===================================================================== */
INSERT INTO AI_RECOMMENDATIONS
WITH r AS (
    SELECT p.POLICY_ID, p.CUSTOMER_ID, p.AGENT_ID, p.BRANCH_ID,
           p.NEXT_RENEWAL_DATE, p.ANNUAL_PREMIUM, p.PAYMENT_FREQUENCY,
           DATEDIFF(day, '2025-12-31'::DATE, p.NEXT_RENEWAL_DATE) AS DAYS_TO_RENEWAL,
           a.AGENT_NAME, b.BRANCH_NAME, c.CUSTOMER_NAME,
           COALESCE(v.CLV_SEGMENT, 'BRONZE') AS CLV_SEGMENT
    FROM FACT_POLICY p
    JOIN DIM_AGENT    a ON a.AGENT_ID    = p.AGENT_ID
    JOIN DIM_BRANCH   b ON b.BRANCH_ID   = p.BRANCH_ID
    JOIN DIM_CUSTOMER c ON c.CUSTOMER_ID = p.CUSTOMER_ID
    LEFT JOIN CUSTOMER_CLV_SCORES v ON v.CUSTOMER_ID = p.CUSTOMER_ID
    WHERE p.POLICY_STATUS = 'Inforce'
      AND p.NEXT_RENEWAL_DATE IS NOT NULL
      AND DATEDIFF(day, '2025-12-31'::DATE, p.NEXT_RENEWAL_DATE) BETWEEN 0 AND 60
)
SELECT
    'REC-RNW-' || POLICY_ID,
    CURRENT_TIMESTAMP(), '2025-12-01'::DATE,
    'RENEWAL_FOLLOW_UP',
    ROUND(40 + (60 - DAYS_TO_RENEWAL) / 60.0 * 20, 2),
    CASE WHEN CLV_SEGMENT = 'PLATINUM' THEN 'HIGH'
         WHEN CLV_SEGMENT = 'GOLD' THEN 'MEDIUM'
         WHEN DAYS_TO_RENEWAL <= 21 THEN 'MEDIUM' ELSE 'LOW' END,
    AGENT_ID, AGENT_NAME, BRANCH_ID, BRANCH_NAME, CUSTOMER_ID, CUSTOMER_NAME, POLICY_ID,
    'Renewal due in ' || DAYS_TO_RENEWAL || ' days: ' || CUSTOMER_NAME || ' (' || POLICY_ID || ')',
    'Contact ' || CUSTOMER_NAME || ' before ' || TO_VARCHAR(NEXT_RENEWAL_DATE, 'DD Mon YYYY') ||
        ' to confirm renewal of policy ' || POLICY_ID || ' (Rp ' ||
        TO_VARCHAR(ANNUAL_PREMIUM, '999,999,999') || ' ' || PAYMENT_FREQUENCY || ').',
    'Policy anniversary falls in ' || DAYS_TO_RENEWAL || ' days; CLV segment ' || CLV_SEGMENT ||
        '. Early confirmation materially reduces lapse at renewal.',
    ANNUAL_PREMIUM,
    'FACT_POLICY renewal calendar + M5_CLV',
    'OPEN', 'M4_RULE_ENGINE'
FROM r;

/* =====================================================================
   Rule 3 — CROSS_SELL (per customer, specific class from M7)
   ===================================================================== */
INSERT INTO AI_RECOMMENDATIONS
WITH lift_range AS (
    SELECT MIN(BEST_LIFT) AS lo, MAX(BEST_LIFT) AS hi FROM CROSS_SELL_RECOMMENDATIONS
),
r AS (
    SELECT x.CUSTOMER_ID, x.CUSTOMER_NAME, x.RECOMMENDED_CLASS, x.BASED_ON_CLASS,
           x.BEST_LIFT, x.BEST_CONFIDENCE, x.EXPECTED_ANNUAL_PREMIUM,
           x.CLV_SEGMENT, x.CURRENT_POLICY_COUNT, x.IS_PRIORITY_TARGET,
           x.SERVICING_AGENT_ID AS AGENT_ID, x.SERVICING_BRANCH_ID AS BRANCH_ID,
           a.AGENT_NAME, b.BRANCH_NAME,
           (x.BEST_LIFT - lr.lo) / NULLIF(lr.hi - lr.lo, 0) AS LIFT_NORM,
           CASE x.CLV_SEGMENT WHEN 'PLATINUM' THEN 12 WHEN 'GOLD' THEN 8
                              WHEN 'SILVER' THEN 4 ELSE 0 END AS CLV_BONUS
    FROM CROSS_SELL_RECOMMENDATIONS x
    CROSS JOIN lift_range lr
    JOIN DIM_AGENT  a ON a.AGENT_ID  = x.SERVICING_AGENT_ID
    JOIN DIM_BRANCH b ON b.BRANCH_ID = x.SERVICING_BRANCH_ID
    WHERE x.REC_RANK = 1                      -- best single offer per customer
      AND x.CLV_SEGMENT IN ('PLATINUM','GOLD','SILVER')
)
SELECT
    'REC-XSL-' || CUSTOMER_ID,
    CURRENT_TIMESTAMP(), '2025-12-01'::DATE,
    'CROSS_SELL',
    ROUND(30 + COALESCE(LIFT_NORM, 0) * 15 + CLV_BONUS, 2),
    CASE WHEN CLV_SEGMENT = 'PLATINUM' THEN 'HIGH'
         WHEN CLV_SEGMENT = 'GOLD' THEN 'MEDIUM' ELSE 'LOW' END,
    AGENT_ID, AGENT_NAME, BRANCH_ID, BRANCH_NAME, CUSTOMER_ID, CUSTOMER_NAME, NULL,
    'Cross-sell ' || RECOMMENDED_CLASS || ' to ' || CUSTOMER_NAME ||
        ' (lift ' || ROUND(BEST_LIFT, 2) || ')',
    'Offer a Meridian ' || RECOMMENDED_CLASS || ' product to ' || CUSTOMER_NAME ||
        '. Expected annual premium about Rp ' ||
        TO_VARCHAR(EXPECTED_ANNUAL_PREMIUM, '999,999,999') || '.',
    'M7 association rule ' || BASED_ON_CLASS || ' -> ' || RECOMMENDED_CLASS ||
        ': lift ' || ROUND(BEST_LIFT, 2) || ', confidence ' || ROUND(BEST_CONFIDENCE * 100, 1) ||
        '%. Customer holds ' || CURRENT_POLICY_COUNT || ' policy(ies); CLV segment ' || CLV_SEGMENT ||
        IFF(IS_PRIORITY_TARGET, '. Single-product high-value customer - priority target.', '.'),
    EXPECTED_ANNUAL_PREMIUM,
    'M7_CROSS_SELL + M5_CLV',
    'OPEN', 'M4_RULE_ENGINE'
FROM r;

/* =====================================================================
   Rule 4 — COACHING_ACTIVITY (per agent, from M3)
   ===================================================================== */
INSERT INTO AI_RECOMMENDATIONS
WITH r AS (
    SELECT s.AGENT_ID, s.AGENT_NAME, s.BRANCH_ID, s.BRANCH_NAME,
           s.COMPOSITE_SCORE, s.PERFORMANCE_CATEGORY, s.PRODUCTION_SCORE,
           s.ACTIVITY_SCORE, s.TRAINING_SCORE, s.RETENTION_SCORE,
           s.ACTIVITIES_12M, s.COURSES_COMPLETED, s.FYAP_12M, s.RANK_IN_BRANCH,
           -- the weakest pillar tells the leader what to coach
           CASE LEAST(s.PRODUCTION_SCORE, s.ACTIVITY_SCORE, s.TRAINING_SCORE, s.RETENTION_SCORE)
                WHEN s.ACTIVITY_SCORE   THEN 'activity discipline (prospecting volume)'
                WHEN s.TRAINING_SCORE   THEN 'product training and certification'
                WHEN s.RETENTION_SCORE  THEN 'persistency and after-sales servicing'
                ELSE 'production and closing skills' END AS WEAKEST_PILLAR
    FROM AGENT_PERFORMANCE_SCORES s
    WHERE s.PERFORMANCE_CATEGORY IN ('NEEDS_COACHING','AT_RISK')
      AND s.ACTIVITIES_12M > 0            -- genuinely active but underperforming
)
SELECT
    'REC-CCH-' || AGENT_ID,
    CURRENT_TIMESTAMP(), '2025-12-01'::DATE,
    'COACHING_ACTIVITY',
    50.00,
    IFF(PERFORMANCE_CATEGORY = 'AT_RISK', 'MEDIUM', 'LOW'),
    AGENT_ID, AGENT_NAME, BRANCH_ID, BRANCH_NAME, NULL, NULL, NULL,
    'Coach ' || AGENT_NAME || ' (' || PERFORMANCE_CATEGORY || ', score ' ||
        ROUND(COMPOSITE_SCORE, 1) || ')',
    'Run a coaching session with ' || AGENT_NAME || ' focused on ' || WEAKEST_PILLAR ||
        '. Agree a weekly activity commitment and review in 30 days.',
    'M3 composite score ' || ROUND(COMPOSITE_SCORE, 1) || '/100 (' || PERFORMANCE_CATEGORY ||
        '), rank ' || RANK_IN_BRANCH || ' in branch. Pillars - production ' ||
        ROUND(PRODUCTION_SCORE) || ', activity ' || ROUND(ACTIVITY_SCORE) ||
        ', training ' || ROUND(TRAINING_SCORE) || ', retention ' || ROUND(RETENTION_SCORE) || '.',
    -- value = lifting this agent to the branch median FYAP
    GREATEST(0, ROUND((SELECT MEDIAN(FYAP_12M) FROM AGENT_PERFORMANCE_SCORES) - FYAP_12M, 2)),
    'M3_AGENT_SCORE',
    'OPEN', 'M4_RULE_ENGINE'
FROM r;

/* =====================================================================
   Rule 5 — REACTIVATION (per agent: INFORCE but no production in 3 months)
   ===================================================================== */
INSERT INTO AI_RECOMMENDATIONS
WITH recent AS (
    SELECT AGENT_ID, SUM(NEW_POLICIES) AS POLICIES_Q4
    FROM FACT_AGENT_PRODUCTION
    WHERE PRODUCTION_MONTH >= '2025-10-01'
    GROUP BY 1
),
r AS (
    SELECT s.AGENT_ID, s.AGENT_NAME, s.BRANCH_ID, s.BRANCH_NAME,
           s.COMPOSITE_SCORE, s.FYAP_12M, s.POLICIES_12M, s.ACTIVITIES_12M,
           s.APP_EVENTS_12M, s.TENURE_MONTHS
    FROM AGENT_PERFORMANCE_SCORES s
    LEFT JOIN recent rc ON rc.AGENT_ID = s.AGENT_ID
    WHERE COALESCE(rc.POLICIES_Q4, 0) = 0        -- silent for the last quarter
      AND s.POLICIES_12M > 0                     -- but did produce earlier in the year
)
SELECT
    'REC-RAC-' || AGENT_ID,
    CURRENT_TIMESTAMP(), '2025-12-01'::DATE,
    'REACTIVATION',
    55.00,
    'MEDIUM',
    AGENT_ID, AGENT_NAME, BRANCH_ID, BRANCH_NAME, NULL, NULL, NULL,
    'Reactivate ' || AGENT_NAME || ' - zero production since Oct 2025',
    'Reach out to ' || AGENT_NAME || ' to understand the stall, refresh their lead list ' ||
        'and set a 2-case commitment for the next 30 days.',
    'Produced ' || POLICIES_12M || ' policies in 2025 (Rp ' ||
        TO_VARCHAR(ROUND(FYAP_12M), '999,999,999') || ' FYAP) but ZERO in Q4. ' ||
        ACTIVITIES_12M || ' logged activities, ' || APP_EVENTS_12M ||
        ' app events, tenure ' || TENURE_MONTHS || ' months.',
    ROUND(FYAP_12M / GREATEST(1, POLICIES_12M) * 2, 2),   -- 2 cases at their own average
    'M3_AGENT_SCORE + FACT_AGENT_PRODUCTION',
    'OPEN', 'M4_RULE_ENGINE'
FROM r;

/* =====================================================================
   Rule 6 — BRANCH_BELOW_TARGET (per branch, AGENT_ID is NULL by design)
   ===================================================================== */
INSERT INTO AI_RECOMMENDATIONS
WITH r AS (
    SELECT c.BRANCH_ID, c.BRANCH_NAME, c.PROVINCE, c.ACHIEVEMENT_PCT,
           c.TARGET_FYAP, c.ACTUAL_FYAP, c.FYAP_VARIANCE, c.ACHIEVEMENT_BAND,
           c.ACTIVE_AGENTS, c.LATEST_ANOMALY_TYPE, c.LATEST_ANOMALY_MONTH,
           c.LATEST_ANOMALY_DEVIATION,
           (SELECT COUNT(*) FROM AGENT_PERFORMANCE_SCORES s
            WHERE s.BRANCH_ID = c.BRANCH_ID
              AND s.PERFORMANCE_CATEGORY IN ('NEEDS_COACHING','AT_RISK')) AS WEAK_AGENTS
    FROM BRANCH_NBA_CONTEXT c
    WHERE c.ACHIEVEMENT_PCT < 100
)
SELECT
    'REC-BRT-' || BRANCH_ID,
    CURRENT_TIMESTAMP(), '2025-12-01'::DATE,
    'BRANCH_BELOW_TARGET',
    LEAST(100, ROUND(70 + (1 - ACHIEVEMENT_PCT / 100.0) * 30, 2)),
    CASE WHEN ACHIEVEMENT_PCT < 60 THEN 'HIGH'
         WHEN ACHIEVEMENT_PCT < 85 THEN 'MEDIUM' ELSE 'LOW' END,
    NULL, NULL, BRANCH_ID, BRANCH_NAME, NULL, NULL, NULL,
    BRANCH_NAME || ' at ' || ROUND(ACHIEVEMENT_PCT, 1) || '% of 2025 plan (' || ACHIEVEMENT_BAND || ')',
    'Run a branch recovery review for ' || BRANCH_NAME || '. Close the Rp ' ||
        TO_VARCHAR(ROUND(ABS(FYAP_VARIANCE)), '999,999,999') || ' gap by reactivating idle agents' ||
        IFF(WEAK_AGENTS > 0, ' and coaching the ' || WEAK_AGENTS || ' agents below standard', '') || '.',
    'Achievement ' || ROUND(ACHIEVEMENT_PCT, 1) || '% (actual Rp ' ||
        TO_VARCHAR(ROUND(ACTUAL_FYAP), '999,999,999') || ' vs plan Rp ' ||
        TO_VARCHAR(ROUND(TARGET_FYAP), '999,999,999') || '), ' || ACTIVE_AGENTS ||
        ' active agents, ' || WEAK_AGENTS || ' below standard' ||
        IFF(LATEST_ANOMALY_TYPE IS NOT NULL,
            '. M6 flagged a ' || LATEST_ANOMALY_TYPE || ' in ' ||
            TO_VARCHAR(LATEST_ANOMALY_MONTH, 'Mon YYYY') || ' (' ||
            ROUND(LATEST_ANOMALY_DEVIATION, 1) || '% vs expected)', '') || '.',
    ABS(FYAP_VARIANCE),
    'V_BRANCH_ACHIEVEMENT + M6_ANOMALY + M3_AGENT_SCORE',
    'OPEN', 'M4_RULE_ENGINE'
FROM r;

/* ---- Verification --------------------------------------------------- */
SELECT RECOMMENDATION_TYPE, COUNT(*) AS recs,
       ROUND(MIN(URGENCY_SCORE), 1) AS min_urgency,
       ROUND(AVG(URGENCY_SCORE), 1) AS avg_urgency,
       ROUND(MAX(URGENCY_SCORE), 1) AS max_urgency,
       ROUND(SUM(EXPECTED_VALUE) / 1e9, 2) AS pipeline_rp_bn
FROM AI_RECOMMENDATIONS
GROUP BY 1 ORDER BY avg_urgency DESC;

SELECT PRIORITY, COUNT(*) AS recs FROM AI_RECOMMENDATIONS GROUP BY 1 ORDER BY 2 DESC;

SELECT COUNT(*) AS total_recs,
       COUNT(DISTINCT AGENT_ID) AS agents_with_actions,
       COUNT(DISTINCT BRANCH_ID) AS branches,
       ROUND(SUM(EXPECTED_VALUE) / 1e9, 2) AS total_pipeline_rp_bn
FROM AI_RECOMMENDATIONS;

-- top of the queue, exactly as the Action Queue page will show it
SELECT RECOMMENDATION_TYPE, URGENCY_SCORE, PRIORITY, AGENT_NAME, BRANCH_NAME, TITLE
FROM AI_RECOMMENDATIONS ORDER BY URGENCY_SCORE DESC LIMIT 8;
