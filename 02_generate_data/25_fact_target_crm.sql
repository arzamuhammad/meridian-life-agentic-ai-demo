/* =====================================================================
   MERIDIAN LIFE — 25_fact_target_crm.sql
   FACT_BRANCH_TARGET  (branch-level ONLY — there is no per-agent target)
   FACT_CRM_TICKETS    (pattern (f): tickets concentrated on lapse-risk policies)

   TARGET_FYAP is derived as ACTUAL_FYAP / designed achievement ratio, so
   pattern (c) is exact and reproducible:
     under-performers 0.44-0.58   over-performers 1.12-1.31
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

/* =====================================================================
   FACT_BRANCH_TARGET  (23 branches x 3 years, minus 3 branch-years for
   the branches that only opened in 2024 = 66 rows)
   ===================================================================== */
CREATE OR REPLACE TABLE FACT_BRANCH_TARGET AS
WITH actual AS (
  SELECT BRANCH_ID, PRODUCTION_YEAR AS TARGET_YEAR,
         SUM(FYAP)         AS ACTUAL_FYAP,
         SUM(NEW_POLICIES) AS ACTUAL_POLICIES
  FROM FACT_AGENT_PRODUCTION
  GROUP BY 1,2
),
ach AS (
  SELECT f.BRANCH_ID, y.TARGET_YEAR,
         CASE y.TARGET_YEAR WHEN 2023 THEN f.ACH_2023
                            WHEN 2024 THEN f.ACH_2024
                            ELSE f.ACH_2025 END AS ACH
  FROM GEN_BRANCH_FACTOR f
  CROSS JOIN (SELECT 2023 AS TARGET_YEAR UNION ALL SELECT 2024 UNION ALL SELECT 2025) y
),
joined AS (
  SELECT a.BRANCH_ID, a.TARGET_YEAR, a.ACH,
         COALESCE(act.ACTUAL_FYAP, 0)     AS ACTUAL_FYAP,
         COALESCE(act.ACTUAL_POLICIES, 0) AS ACTUAL_POLICIES
  FROM ach a
  LEFT JOIN actual act ON act.BRANCH_ID = a.BRANCH_ID AND act.TARGET_YEAR = a.TARGET_YEAR
  WHERE a.ACH IS NOT NULL          -- branches opened in 2024 have no 2023 target
)
SELECT
  'TGT-' || BRANCH_ID || '-' || TARGET_YEAR::VARCHAR                              AS TARGET_ID,
  BRANCH_ID,
  TARGET_YEAR,
  GREATEST(100000000, ROUND(ACTUAL_FYAP / ACH, -6))::NUMBER(20,2)                 AS TARGET_FYAP,
  GREATEST(1, ROUND(ACTUAL_POLICIES / ACH))::INT                                  AS TARGET_POLICIES,
  GREATEST(5, ROUND(ACTUAL_POLICIES / ACH / 6))::INT                              AS TARGET_ACTIVE_AGENTS,
  'Annual FYAP Plan'                                                              AS TARGET_TYPE,
  ((TARGET_YEAR - 1)::VARCHAR || '-12-15')::DATE                                  AS SET_DATE,
  IFF(TARGET_YEAR = 2025, 'Active', 'Closed')                                     AS TARGET_STATUS,
  'IDR'                                                                           AS CURRENCY
FROM joined;

/* =====================================================================
   FACT_CRM_TICKETS  (~2,450)
   ~55% deliberately attached to lapse-risk policies (lapsed, or Inforce
   with a late-payment history) using retention-flavoured subjects, so the
   ticket signal in M4 (NBA) genuinely fires.
   ===================================================================== */
CREATE OR REPLACE TABLE FACT_CRM_TICKETS AS
WITH late AS (
  SELECT POLICY_ID,
         COUNT_IF(IS_LATE)                       AS late_cnt,
         COUNT_IF(FEE_STATUS <> 'Payment Confirmed') AS unpaid_cnt
  FROM FACT_POLICY_PAYMENT
  GROUP BY 1
),
risky AS (   -- the lapse-risk pool
  SELECT p.POLICY_ID, p.CUSTOMER_ID, p.BRANCH_ID, p.AGENT_ID, p.ISSUE_DATE,
         LEAST('2025-12-31'::DATE, COALESCE(p.LAPSE_DATE, p.TERMINATION_DATE, '2025-12-31'::DATE)) AS END_DATE,
         TRUE AS IS_RISK
  FROM FACT_POLICY p
  LEFT JOIN late l ON l.POLICY_ID = p.POLICY_ID
  WHERE p.POLICY_STATUS = 'Lapsed'
     OR COALESCE(l.late_cnt, 0) >= 2
     OR COALESCE(l.unpaid_cnt, 0) >= 1
),
normal AS (  -- everything else
  SELECT p.POLICY_ID, p.CUSTOMER_ID, p.BRANCH_ID, p.AGENT_ID, p.ISSUE_DATE,
         LEAST('2025-12-31'::DATE, COALESCE(p.LAPSE_DATE, p.TERMINATION_DATE, '2025-12-31'::DATE)) AS END_DATE,
         FALSE AS IS_RISK
  FROM FACT_POLICY p
  WHERE p.POLICY_ID NOT IN (SELECT POLICY_ID FROM risky)
),
sampled AS (
  SELECT * FROM (SELECT * FROM risky  QUALIFY ROW_NUMBER() OVER (ORDER BY RND(POLICY_ID, 1000)) <= 1200)
  UNION ALL
  SELECT * FROM (SELECT * FROM normal QUALIFY ROW_NUMBER() OVER (ORDER BY RND(POLICY_ID, 1001)) <= 980)
),
ex AS (   -- a few policies raise a second ticket
  SELECT s.*, g.i, s.POLICY_ID || '-TK' || g.i::VARCHAR AS PK
  FROM sampled s
  JOIN (SELECT SEQ4() + 1 AS i FROM TABLE(GENERATOR(ROWCOUNT => 2))) g
    ON g.i = 1 OR RND(s.POLICY_ID, 1002) < 0.12
)
SELECT
  'TKT' || LPAD(ROW_NUMBER() OVER (ORDER BY POLICY_ID, i)::VARCHAR, 7, '0')        AS TICKET_ID,
  POLICY_ID, CUSTOMER_ID, BRANCH_ID, AGENT_ID,
  DATEADD(day, RNDI(PK, 1010, 20, GREATEST(21, DATEDIFF(day, ISSUE_DATE, END_DATE))), ISSUE_DATE) AS TICKET_DATE,
  CASE WHEN IS_RISK THEN
         ARRAY_CONSTRUCT('Lapse / Reinstatement','Premium due reminder','Surrender inquiry',
                         'Payment failure','Premium due reminder','Lapse / Reinstatement',
                         'Grace period question','Auto-debit rejected')[RNDI(PK,1011,0,7)]::VARCHAR
       ELSE
         ARRAY_CONSTRUCT('Address change','Claim status inquiry','Policy document request',
                         'Beneficiary change','Product information','Complaint - agent service',
                         'e-Statement access','Fund switch request')[RNDI(PK,1012,0,7)]::VARCHAR
  END                                                                             AS SUBJECT,
  CASE WHEN IS_RISK THEN 'Retention & Billing' ELSE
    CASE WHEN RND(PK,1013) < 0.30 THEN 'Policy Servicing'
         WHEN RND(PK,1013) < 0.55 THEN 'Claims'
         WHEN RND(PK,1013) < 0.75 THEN 'Product Inquiry'
         WHEN RND(PK,1013) < 0.90 THEN 'Complaint'
         ELSE 'Digital Access' END
  END                                                                             AS CATEGORY,
  ARRAY_CONSTRUCT('Call Center','WhatsApp','Email','Branch Walk-in','Mobile App','Web Portal')[RNDI(PK,1014,0,5)]::VARCHAR AS CHANNEL,
  CASE WHEN IS_RISK AND RND(PK,1015) < 0.42 THEN 'High'
       WHEN RND(PK,1015) < 0.30 THEN 'High'
       WHEN RND(PK,1015) < 0.75 THEN 'Medium'
       ELSE 'Low' END                                                             AS PRIORITY,
  CASE WHEN RND(PK,1016) < 0.79 THEN 'Closed'
       WHEN RND(PK,1016) < 0.92 THEN 'In Progress'
       ELSE 'Escalated' END                                                       AS TICKET_STATUS,
  RNDI(PK, 1017, 1, 21)                                                           AS RESOLUTION_DAYS,
  CASE WHEN IS_RISK AND RND(PK,1018) < 0.46 THEN 'Negative'
       WHEN RND(PK,1018) < 0.22 THEN 'Negative'
       WHEN RND(PK,1018) < 0.68 THEN 'Neutral'
       ELSE 'Positive' END                                                        AS SENTIMENT,
  IS_RISK                                                                         AS IS_RETENTION_RELATED
FROM ex;

/* ---------------------------------------------------------------------
   Verification — pattern (c) and (f)
   --------------------------------------------------------------------- */
SELECT 'FACT_BRANCH_TARGET' t, COUNT(*) n FROM FACT_BRANCH_TARGET
UNION ALL SELECT 'FACT_CRM_TICKETS', COUNT(*) FROM FACT_CRM_TICKETS;

SELECT IS_RETENTION_RELATED, COUNT(*) n, ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),1) pct
FROM FACT_CRM_TICKETS GROUP BY 1;
