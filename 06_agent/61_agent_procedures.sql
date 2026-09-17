/* =====================================================================
   MERIDIAN LIFE — 61_agent_procedures.sql
   Stored procedures exposed to the Cortex Agent as `generic` tools.

   CRITICAL CONTRACT
     Every procedure RETURNS VARCHAR holding a SINGLE-CELL JSON array:
         COALESCE(TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT(*))), '[]')
     A procedure with RETURNS TABLE is NOT readable by a generic agent tool.

   NOTES
     * Inside a LANGUAGE SQL body, parameters must be referenced with a
       colon prefix (:P_BRANCH_ID). Without it Snowflake treats them as
       column identifiers and raises "invalid identifier".
     * LIMIT does not accept a bind variable, so row capping uses
       QUALIFY ROW_NUMBER() <= :P_LIMIT.
     * Empty string is treated as "not supplied" because the agent often
       passes '' rather than NULL for an optional argument.
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

/* ---------------------------------------------------------------------
   TOOL 3 — predict_lapse_risk  (M1)
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE GET_LAPSE_RISK(
    P_BRANCH_ID    VARCHAR,
    P_RISK_SEGMENT VARCHAR,
    P_LIMIT        INT
)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'M1: policies ranked by 90-day lapse probability, with servicing agent, CLV segment and danger-zone flag.'
AS
$$
DECLARE
  res VARCHAR;
BEGIN
  SELECT COALESCE(TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT(*))), '[]') INTO :res
  FROM (
      SELECT l.POLICY_ID,
             c.CUSTOMER_NAME,
             a.AGENT_NAME,
             b.BRANCH_NAME,
             b.PROVINCE,
             ROUND(l.LAPSE_PROBABILITY, 4)          AS LAPSE_PROBABILITY,
             l.RISK_SEGMENT,
             l.TENURE_MONTHS,
             l.IS_DANGER_ZONE,
             l.PAYMENT_FREQUENCY,
             l.ANNUAL_PREMIUM,
             l.LATE_CNT_365D                        AS LATE_PAYMENTS_12M,
             l.UNPAID_CNT_90D                       AS UNPAID_90D,
             l.RETENTION_TICKET_365D                AS RETENTION_TICKETS_12M,
             COALESCE(v.CLV_SEGMENT, 'BRONZE')      AS CLV_SEGMENT,
             v.CLV
      FROM LAPSE_RISK_SCORES l
      JOIN DIM_CUSTOMER c ON c.CUSTOMER_ID = l.CUSTOMER_ID
      JOIN DIM_AGENT    a ON a.AGENT_ID    = l.AGENT_ID
      JOIN DIM_BRANCH   b ON b.BRANCH_ID   = l.BRANCH_ID
      LEFT JOIN CUSTOMER_CLV_SCORES v ON v.CUSTOMER_ID = l.CUSTOMER_ID
      WHERE (:P_BRANCH_ID    IS NULL OR :P_BRANCH_ID    = '' OR b.BRANCH_ID = :P_BRANCH_ID OR b.BRANCH_NAME ILIKE '%' || :P_BRANCH_ID || '%')
        AND (:P_RISK_SEGMENT IS NULL OR :P_RISK_SEGMENT = '' OR l.RISK_SEGMENT = UPPER(:P_RISK_SEGMENT))
      QUALIFY ROW_NUMBER() OVER (ORDER BY l.LAPSE_PROBABILITY DESC) <= COALESCE(:P_LIMIT, 20)
  );
  RETURN :res;
END;
$$;

/* ---------------------------------------------------------------------
   TOOL 4 — get_revenue_forecast  (M2)
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE GET_REVENUE_FORECAST(P_BRANCH_ID VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'M2: 6-month 2026 FYAP forecast per branch with a 95% interval and comparison to the monthly plan.'
AS
$$
DECLARE
  res VARCHAR;
BEGIN
  SELECT COALESCE(TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT(*))), '[]') INTO :res
  FROM (
      SELECT BRANCH_ID, BRANCH_NAME, PROVINCE,
             TO_VARCHAR(FORECAST_MONTH, 'YYYY-MM')      AS FORECAST_MONTH,
             ROUND(FORECAST_FYAP)                       AS FORECAST_FYAP,
             ROUND(LOWER_BOUND_95)                      AS LOWER_BOUND_95,
             ROUND(UPPER_BOUND_95)                      AS UPPER_BOUND_95,
             ROUND(MONTHLY_PLAN_FYAP)                   AS MONTHLY_PLAN_FYAP,
             FORECAST_ACHIEVEMENT_PCT,
             AT_RISK_VS_PLAN
      FROM V_FORECAST_VS_PLAN
      WHERE (:P_BRANCH_ID IS NULL OR :P_BRANCH_ID = ''
             OR BRANCH_ID = :P_BRANCH_ID OR BRANCH_NAME ILIKE '%' || :P_BRANCH_ID || '%')
      ORDER BY BRANCH_NAME, FORECAST_MONTH
  );
  RETURN :res;
END;
$$;

/* ---------------------------------------------------------------------
   TOOL 5 — score_agent_performance  (M3)
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE GET_AGENT_PERFORMANCE(
    P_BRANCH_ID VARCHAR,
    P_CATEGORY  VARCHAR,
    P_LIMIT     INT
)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'M3: composite agent scores with the four pillars. Behaviour-based; there is no per-agent target in this model.'
AS
$$
DECLARE
  res VARCHAR;
BEGIN
  SELECT COALESCE(TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT(*))), '[]') INTO :res
  FROM (
      SELECT AGENT_ID, AGENT_NAME, BRANCH_NAME, PROVINCE, AGENT_LEVEL,
             COMPOSITE_SCORE, PERFORMANCE_CATEGORY,
             PRODUCTION_SCORE, ACTIVITY_SCORE, TRAINING_SCORE, RETENTION_SCORE,
             ROUND(FYAP_12M)      AS FYAP_12M,
             POLICIES_12M, ACTIVITIES_12M, QUALIFIED_LEADS_12M,
             COURSES_COMPLETED, PERSISTENCY_PCT,
             RANK_IN_BRANCH, RANK_OVERALL
      FROM AGENT_PERFORMANCE_SCORES
      WHERE (:P_BRANCH_ID IS NULL OR :P_BRANCH_ID = ''
             OR BRANCH_ID = :P_BRANCH_ID OR BRANCH_NAME ILIKE '%' || :P_BRANCH_ID || '%')
        AND (:P_CATEGORY  IS NULL OR :P_CATEGORY  = '' OR PERFORMANCE_CATEGORY = UPPER(:P_CATEGORY))
      QUALIFY ROW_NUMBER() OVER (ORDER BY COMPOSITE_SCORE DESC) <= COALESCE(:P_LIMIT, 20)
  );
  RETURN :res;
END;
$$;

/* ---------------------------------------------------------------------
   TOOL 6 — get_customer_clv  (M5)
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE GET_CUSTOMER_CLV(
    P_CUSTOMER  VARCHAR,
    P_SEGMENT   VARCHAR,
    P_LIMIT     INT
)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'M5: actuarial customer lifetime value with retention rate and CLV segment. Accepts a customer id or a partial name.'
AS
$$
DECLARE
  res VARCHAR;
BEGIN
  SELECT COALESCE(TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT(*))), '[]') INTO :res
  FROM (
      SELECT CUSTOMER_ID, CUSTOMER_NAME, AGE_BAND, PROVINCE, OCCUPATION, INCOME_BAND,
             POLICY_COUNT, INFORCE_POLICY_COUNT, LAPSED_POLICY_COUNT,
             ROUND(INFORCE_ANNUAL_PREMIUM)  AS INFORCE_ANNUAL_PREMIUM,
             ROUND(PREMIUM_COLLECTED_TO_DATE) AS PREMIUM_COLLECTED_TO_DATE,
             ROUND(CLAIMS_PAID_TO_DATE)     AS CLAIMS_PAID_TO_DATE,
             TENURE_MONTHS, RETENTION_RATE,
             ROUND(CLV)                     AS CLV,
             CLV_SEGMENT, CLV_PERCENTILE
      FROM CUSTOMER_CLV_SCORES
      WHERE (:P_CUSTOMER IS NULL OR :P_CUSTOMER = ''
             OR CUSTOMER_ID = :P_CUSTOMER OR CUSTOMER_NAME ILIKE '%' || :P_CUSTOMER || '%')
        AND (:P_SEGMENT  IS NULL OR :P_SEGMENT  = '' OR CLV_SEGMENT = UPPER(:P_SEGMENT))
      QUALIFY ROW_NUMBER() OVER (ORDER BY CLV DESC) <= COALESCE(:P_LIMIT, 20)
  );
  RETURN :res;
END;
$$;

/* ---------------------------------------------------------------------
   TOOL 7 — detect_production_anomalies  (M6)
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE GET_PRODUCTION_ANOMALIES(P_BRANCH_ID VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'M6: production anomalies (SPIKE or DROP) on a 3-month rolling FYAP series for H2 2025.'
AS
$$
DECLARE
  res VARCHAR;
BEGIN
  SELECT COALESCE(TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT(*))), '[]') INTO :res
  FROM (
      SELECT a.BRANCH_ID, b.BRANCH_NAME, b.PROVINCE,
             TO_VARCHAR(a.PRODUCTION_MONTH, 'YYYY-MM') AS PRODUCTION_MONTH,
             a.ANOMALY_TYPE,
             ROUND(a.ACTUAL_FYAP)            AS ACTUAL_FYAP_THAT_MONTH,
             ROUND(a.ACTUAL_ROLLING3_FYAP)   AS ACTUAL_ROLLING3_FYAP,
             ROUND(a.EXPECTED_FYAP)          AS EXPECTED_ROLLING3_FYAP,
             a.PCT_DEVIATION,
             a.CONSECUTIVE_ANOMALY_MONTHS,
             a.IS_CONFIRMED_ANOMALY
      FROM PRODUCTION_ANOMALIES a
      JOIN DIM_BRANCH b ON b.BRANCH_ID = a.BRANCH_ID
      WHERE a.IS_ANOMALY
        AND (:P_BRANCH_ID IS NULL OR :P_BRANCH_ID = ''
             OR a.BRANCH_ID = :P_BRANCH_ID OR b.BRANCH_NAME ILIKE '%' || :P_BRANCH_ID || '%')
      ORDER BY ABS(a.PCT_DEVIATION) DESC
  );
  RETURN :res;
END;
$$;

/* ---------------------------------------------------------------------
   TOOL 8 — get_cross_sell_suggestions  (M7)
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE GET_CROSS_SELL_SUGGESTIONS(
    P_CUSTOMER VARCHAR,
    P_BRANCH_ID VARCHAR,
    P_LIMIT    INT
)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'M7: association-rule cross-sell offers (lift >= 1) for classes the customer does not already hold.'
AS
$$
DECLARE
  res VARCHAR;
BEGIN
  SELECT COALESCE(TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT(*))), '[]') INTO :res
  FROM (
      SELECT x.CUSTOMER_ID, x.CUSTOMER_NAME, x.PROVINCE,
             x.REC_RANK, x.RECOMMENDED_CLASS, x.BASED_ON_CLASS,
             x.BEST_LIFT, x.BEST_CONFIDENCE, x.RULE_EVIDENCE_CUSTOMERS,
             ROUND(x.EXPECTED_ANNUAL_PREMIUM) AS EXPECTED_ANNUAL_PREMIUM,
             x.CLV_SEGMENT, ROUND(x.CLV) AS CLV,
             x.CURRENT_POLICY_COUNT, x.IS_PRIORITY_TARGET,
             a.AGENT_NAME AS SERVICING_AGENT, b.BRANCH_NAME AS SERVICING_BRANCH
      FROM CROSS_SELL_RECOMMENDATIONS x
      LEFT JOIN DIM_AGENT  a ON a.AGENT_ID  = x.SERVICING_AGENT_ID
      LEFT JOIN DIM_BRANCH b ON b.BRANCH_ID = x.SERVICING_BRANCH_ID
      WHERE (:P_CUSTOMER  IS NULL OR :P_CUSTOMER  = ''
             OR x.CUSTOMER_ID = :P_CUSTOMER OR x.CUSTOMER_NAME ILIKE '%' || :P_CUSTOMER || '%')
        AND (:P_BRANCH_ID IS NULL OR :P_BRANCH_ID = ''
             OR x.SERVICING_BRANCH_ID = :P_BRANCH_ID OR b.BRANCH_NAME ILIKE '%' || :P_BRANCH_ID || '%')
      QUALIFY ROW_NUMBER() OVER (ORDER BY x.IS_PRIORITY_TARGET DESC, x.BEST_LIFT DESC) <= COALESCE(:P_LIMIT, 20)
  );
  RETURN :res;
END;
$$;

/* ---------------------------------------------------------------------
   TOOL 9a — save_agent_recommendation (write-back, per agent/customer)
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE SAVE_AGENT_RECOMMENDATION(
    P_AGENT_ID    VARCHAR,
    P_REC_TYPE    VARCHAR,
    P_TITLE       VARCHAR,
    P_ACTION      VARCHAR,
    P_REASON      VARCHAR,
    P_URGENCY     FLOAT,
    P_POLICY_ID   VARCHAR,
    P_CUSTOMER_ID VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Write-back: save an agent-level recommendation created during a chat into AI_RECOMMENDATIONS.'
AS
$$
DECLARE
  res VARCHAR;
  new_id VARCHAR;
BEGIN
  new_id := 'REC-AGT-' || REPLACE(UUID_STRING(), '-', '');
  INSERT INTO AI_RECOMMENDATIONS
    (RECOMMENDATION_ID, GENERATED_AT, ASOF_DATE, RECOMMENDATION_TYPE, URGENCY_SCORE,
     PRIORITY, AGENT_ID, AGENT_NAME, BRANCH_ID, BRANCH_NAME, CUSTOMER_ID, CUSTOMER_NAME,
     POLICY_ID, TITLE, RECOMMENDED_ACTION, REASON, EXPECTED_VALUE, SIGNAL_SOURCE,
     STATUS, CREATED_BY)
  SELECT :new_id, CURRENT_TIMESTAMP(), CURRENT_DATE(),
         COALESCE(NULLIF(:P_REC_TYPE, ''), 'AGENT_ACTION'),
         COALESCE(:P_URGENCY, 50),
         CASE WHEN COALESCE(:P_URGENCY, 50) >= 70 THEN 'HIGH'
              WHEN COALESCE(:P_URGENCY, 50) >= 45 THEN 'MEDIUM' ELSE 'LOW' END,
         a.AGENT_ID, a.AGENT_NAME, a.BRANCH_ID, b.BRANCH_NAME,
         NULLIF(:P_CUSTOMER_ID, ''), c.CUSTOMER_NAME, NULLIF(:P_POLICY_ID, ''),
         :P_TITLE, :P_ACTION, :P_REASON, NULL,
         'CORTEX_AGENT', 'OPEN', 'CORTEX_AGENT'
  FROM DIM_AGENT a
  JOIN DIM_BRANCH b ON b.BRANCH_ID = a.BRANCH_ID
  LEFT JOIN DIM_CUSTOMER c ON c.CUSTOMER_ID = NULLIF(:P_CUSTOMER_ID, '')
  WHERE a.AGENT_ID = :P_AGENT_ID;

  SELECT COALESCE(TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT(*))), '[]') INTO :res
  FROM (SELECT RECOMMENDATION_ID, RECOMMENDATION_TYPE, AGENT_NAME, BRANCH_NAME,
               TITLE, URGENCY_SCORE, PRIORITY, STATUS, 'SAVED' AS RESULT
        FROM AI_RECOMMENDATIONS WHERE RECOMMENDATION_ID = :new_id);
  RETURN :res;
END;
$$;

/* ---------------------------------------------------------------------
   TOOL 9b — save_branch_recommendation (write-back, per branch)
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE SAVE_BRANCH_RECOMMENDATION(
    P_BRANCH_ID VARCHAR,
    P_REC_TYPE  VARCHAR,
    P_TITLE     VARCHAR,
    P_ACTION    VARCHAR,
    P_REASON    VARCHAR,
    P_URGENCY   FLOAT
)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Write-back: save a branch-level recommendation. AGENT_ID stays NULL by design.'
AS
$$
DECLARE
  res VARCHAR;
  new_id VARCHAR;
BEGIN
  new_id := 'REC-BRN-' || REPLACE(UUID_STRING(), '-', '');
  INSERT INTO AI_RECOMMENDATIONS
    (RECOMMENDATION_ID, GENERATED_AT, ASOF_DATE, RECOMMENDATION_TYPE, URGENCY_SCORE,
     PRIORITY, AGENT_ID, AGENT_NAME, BRANCH_ID, BRANCH_NAME, CUSTOMER_ID, CUSTOMER_NAME,
     POLICY_ID, TITLE, RECOMMENDED_ACTION, REASON, EXPECTED_VALUE, SIGNAL_SOURCE,
     STATUS, CREATED_BY)
  SELECT :new_id, CURRENT_TIMESTAMP(), CURRENT_DATE(),
         COALESCE(NULLIF(:P_REC_TYPE, ''), 'BRANCH_ACTION'),
         COALESCE(:P_URGENCY, 60),
         CASE WHEN COALESCE(:P_URGENCY, 60) >= 70 THEN 'HIGH'
              WHEN COALESCE(:P_URGENCY, 60) >= 45 THEN 'MEDIUM' ELSE 'LOW' END,
         NULL, NULL, b.BRANCH_ID, b.BRANCH_NAME, NULL, NULL, NULL,
         :P_TITLE, :P_ACTION, :P_REASON,
         ABS(COALESCE(v.FYAP_VARIANCE, 0)),
         'CORTEX_AGENT', 'OPEN', 'CORTEX_AGENT'
  FROM DIM_BRANCH b
  LEFT JOIN V_BRANCH_ACHIEVEMENT v ON v.BRANCH_ID = b.BRANCH_ID AND v.FISCAL_YEAR = 2025
  WHERE b.BRANCH_ID = :P_BRANCH_ID OR b.BRANCH_NAME ILIKE '%' || :P_BRANCH_ID || '%';

  SELECT COALESCE(TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT(*))), '[]') INTO :res
  FROM (SELECT RECOMMENDATION_ID, RECOMMENDATION_TYPE, BRANCH_NAME, TITLE,
               URGENCY_SCORE, PRIORITY, EXPECTED_VALUE, STATUS, 'SAVED' AS RESULT
        FROM AI_RECOMMENDATIONS WHERE RECOMMENDATION_ID = :new_id);
  RETURN :res;
END;
$$;

/* ---------------------------------------------------------------------
   TOOL 13 — assign_retention_calls (BATCH — avoids the agent looping
   once per agent, which is slow and burns tokens)
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE ASSIGN_RETENTION_CALLS(
    P_BRANCH_ID VARCHAR,
    P_LIMIT     INT
)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Batch-assign the highest-urgency open RETENTION_CALL actions in a branch to their servicing agents in ONE call.'
AS
$$
DECLARE
  res VARCHAR;
  n INT;
BEGIN
  CREATE OR REPLACE TEMPORARY TABLE _assign_batch AS
  SELECT RECOMMENDATION_ID
  FROM AI_RECOMMENDATIONS r
  WHERE r.RECOMMENDATION_TYPE = 'RETENTION_CALL'
    AND r.STATUS = 'OPEN'
    AND (:P_BRANCH_ID IS NULL OR :P_BRANCH_ID = ''
         OR r.BRANCH_ID = :P_BRANCH_ID OR r.BRANCH_NAME ILIKE '%' || :P_BRANCH_ID || '%')
  QUALIFY ROW_NUMBER() OVER (ORDER BY r.URGENCY_SCORE DESC) <= COALESCE(:P_LIMIT, 25);

  UPDATE AI_RECOMMENDATIONS
     SET STATUS = 'ASSIGNED'
   WHERE RECOMMENDATION_ID IN (SELECT RECOMMENDATION_ID FROM _assign_batch);

  SELECT COUNT(*) INTO :n FROM _assign_batch;

  SELECT COALESCE(TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT(*))), '[]') INTO :res
  FROM (
      SELECT r.RECOMMENDATION_ID, r.AGENT_NAME, r.BRANCH_NAME, r.CUSTOMER_NAME,
             r.POLICY_ID, r.URGENCY_SCORE, r.PRIORITY, r.EXPECTED_VALUE, r.STATUS,
             :n AS TOTAL_ASSIGNED
      FROM AI_RECOMMENDATIONS r
      WHERE r.RECOMMENDATION_ID IN (SELECT RECOMMENDATION_ID FROM _assign_batch)
      ORDER BY r.URGENCY_SCORE DESC
  );
  RETURN :res;
END;
$$;

/* ---------------------------------------------------------------------
   TOOL 14 — get_branch_scorecard (one call for the whole diagnosis:
   achievement + anomaly + weak agents + lapse exposure)
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE GET_BRANCH_SCORECARD(P_BRANCH_ID VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'One-shot branch diagnosis: 2025 achievement, latest M6 anomaly, agent mix from M3, and lapse exposure from M1.'
AS
$$
DECLARE
  res VARCHAR;
BEGIN
  SELECT COALESCE(TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT(*))), '[]') INTO :res
  FROM (
      SELECT c.BRANCH_ID, c.BRANCH_NAME, c.PROVINCE, c.REGION, c.BRANCH_TYPE,
             ROUND(c.TARGET_FYAP)   AS TARGET_FYAP_2025,
             ROUND(c.ACTUAL_FYAP)   AS ACTUAL_FYAP_2025,
             ROUND(c.FYAP_VARIANCE) AS FYAP_GAP,
             c.ACHIEVEMENT_PCT, c.ACHIEVEMENT_BAND, c.ACTIVE_AGENTS,
             c.LATEST_ANOMALY_TYPE,
             TO_VARCHAR(c.LATEST_ANOMALY_MONTH, 'YYYY-MM') AS LATEST_ANOMALY_MONTH,
             c.LATEST_ANOMALY_DEVIATION,
             s.TOTAL_AGENTS, s.TOP_PERFORMERS, s.WEAK_AGENTS, s.AVG_AGENT_SCORE,
             l.POLICIES_SCORED, l.HIGH_RISK_POLICIES,
             ROUND(l.PREMIUM_AT_RISK) AS PREMIUM_AT_RISK,
             o.OPEN_ACTIONS, ROUND(o.PIPELINE_VALUE) AS OPEN_PIPELINE_VALUE
      FROM BRANCH_NBA_CONTEXT c
      LEFT JOIN (
          SELECT BRANCH_ID, COUNT(*) AS TOTAL_AGENTS,
                 COUNT_IF(PERFORMANCE_CATEGORY = 'TOP_PERFORMER') AS TOP_PERFORMERS,
                 COUNT_IF(PERFORMANCE_CATEGORY IN ('NEEDS_COACHING','AT_RISK')) AS WEAK_AGENTS,
                 ROUND(AVG(COMPOSITE_SCORE), 1) AS AVG_AGENT_SCORE
          FROM AGENT_PERFORMANCE_SCORES GROUP BY 1
      ) s ON s.BRANCH_ID = c.BRANCH_ID
      LEFT JOIN (
          SELECT BRANCH_ID, COUNT(*) AS POLICIES_SCORED,
                 COUNT_IF(RISK_SEGMENT IN ('HIGH','CRITICAL')) AS HIGH_RISK_POLICIES,
                 SUM(IFF(RISK_SEGMENT IN ('HIGH','CRITICAL'), ANNUAL_PREMIUM, 0)) AS PREMIUM_AT_RISK
          FROM LAPSE_RISK_SCORES GROUP BY 1
      ) l ON l.BRANCH_ID = c.BRANCH_ID
      LEFT JOIN (
          SELECT BRANCH_ID, COUNT(*) AS OPEN_ACTIONS, SUM(EXPECTED_VALUE) AS PIPELINE_VALUE
          FROM AI_RECOMMENDATIONS WHERE STATUS = 'OPEN' GROUP BY 1
      ) o ON o.BRANCH_ID = c.BRANCH_ID
      WHERE (:P_BRANCH_ID IS NULL OR :P_BRANCH_ID = ''
             OR c.BRANCH_ID = :P_BRANCH_ID OR c.BRANCH_NAME ILIKE '%' || :P_BRANCH_ID || '%')
      ORDER BY c.ACHIEVEMENT_PCT ASC
  );
  RETURN :res;
END;
$$;

/* ---------------------------------------------------------------------
   Smoke tests — every procedure must return a JSON array, never NULL
   --------------------------------------------------------------------- */
CALL GET_LAPSE_RISK('Jember', 'CRITICAL', 3);
CALL GET_REVENUE_FORECAST('Jember');
CALL GET_AGENT_PERFORMANCE('', 'TOP_PERFORMER', 3);
CALL GET_CUSTOMER_CLV('', 'PLATINUM', 3);
CALL GET_PRODUCTION_ANOMALIES('Malang');
CALL GET_CROSS_SELL_SUGGESTIONS('', '', 3);
CALL GET_BRANCH_SCORECARD('Jember');
