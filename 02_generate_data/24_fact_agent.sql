/* =====================================================================
   MERIDIAN LIFE — 24_fact_agent.sql
   FACT_AGENT_PRODUCTION, FACT_AGENT_ACTIVITY, FACT_AGENT_APPS_BEHAVIOR,
   FACT_TRAINING
   FACT_AGENT_PRODUCTION is DERIVED from FACT_POLICY so branch/agent
   production always reconciles with the policy fact (no contradictions).
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

/* ---------------------------------------------------------------------
   Agent active window (clipped to the 2023-2025 observation period)
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE GEN_AGENT_WINDOW AS
SELECT AGENT_ID, BRANCH_ID, AGENT_STATUS, GEN_ACTIVITY_RATE, GEN_PRODUCTIVITY,
       GREATEST(JOIN_DATE, '2023-01-01'::DATE)                                   AS WIN_START,
       LEAST(COALESCE(TERMINATION_DATE, '2025-12-31'::DATE), '2025-12-31'::DATE)  AS WIN_END
FROM DIM_AGENT
WHERE AGENT_STATUS IN ('INFORCE','TERMINATED')
  AND GREATEST(JOIN_DATE, '2023-01-01'::DATE)
        < LEAST(COALESCE(TERMINATION_DATE, '2025-12-31'::DATE), '2025-12-31'::DATE);

/* =====================================================================
   FACT_AGENT_PRODUCTION  (monthly, per agent)
   Grain: every month from an agent's first to last producing month,
   keeping zero-production months only when within 2 months of activity
   (production reporting stops after prolonged inactivity).
   ===================================================================== */
CREATE OR REPLACE TABLE FACT_AGENT_PRODUCTION AS
WITH pol AS (
  SELECT AGENT_ID, BRANCH_ID, ISSUE_MONTH,
         COUNT(*)                AS NEW_POLICIES,
         SUM(FYAP)               AS FYAP,
         SUM(ANNUAL_PREMIUM)     AS TOTAL_ANNUAL_PREMIUM,
         SUM(SUM_ASSURED)        AS TOTAL_SUM_ASSURED
  FROM FACT_POLICY
  GROUP BY 1,2,3
),
span AS (
  SELECT AGENT_ID, BRANCH_ID, MIN(ISSUE_MONTH) AS m_first, MAX(ISSUE_MONTH) AS m_last
  FROM pol GROUP BY 1,2
),
grid AS (
  SELECT s.AGENT_ID, s.BRANCH_ID,
         DATEADD(month, g.i, s.m_first) AS PRODUCTION_MONTH
  FROM span s
  JOIN (SELECT SEQ4() AS i FROM TABLE(GENERATOR(ROWCOUNT => 36))) g
    ON DATEADD(month, g.i, s.m_first) <= s.m_last
),
kept AS (
  SELECT DISTINCT gr.AGENT_ID, gr.BRANCH_ID, gr.PRODUCTION_MONTH
  FROM grid gr
  JOIN pol p
    ON p.AGENT_ID = gr.AGENT_ID
   AND p.ISSUE_MONTH BETWEEN DATEADD(month, -2, gr.PRODUCTION_MONTH)
                         AND DATEADD(month,  2, gr.PRODUCTION_MONTH)
),
joined AS (
  SELECT k.AGENT_ID, k.BRANCH_ID, k.PRODUCTION_MONTH,
         COALESCE(p.NEW_POLICIES, 0)           AS NEW_POLICIES,
         COALESCE(p.FYAP, 0)                   AS FYAP,
         COALESCE(p.TOTAL_ANNUAL_PREMIUM, 0)   AS TOTAL_ANNUAL_PREMIUM,
         COALESCE(p.TOTAL_SUM_ASSURED, 0)      AS TOTAL_SUM_ASSURED,
         k.AGENT_ID || '-' || TO_VARCHAR(k.PRODUCTION_MONTH,'YYYYMM') AS PK
  FROM kept k
  LEFT JOIN pol p ON p.AGENT_ID = k.AGENT_ID AND p.ISSUE_MONTH = k.PRODUCTION_MONTH
)
SELECT
  'PRD' || LPAD(ROW_NUMBER() OVER (ORDER BY AGENT_ID, PRODUCTION_MONTH)::VARCHAR, 7, '0') AS PRODUCTION_ID,
  AGENT_ID, BRANCH_ID,
  PRODUCTION_MONTH,
  YEAR(PRODUCTION_MONTH)                                                AS PRODUCTION_YEAR,
  MONTH(PRODUCTION_MONTH)                                               AS PRODUCTION_MONTH_NO,
  NEW_POLICIES,
  NEW_POLICIES                                                          AS CASE_COUNT,
  FYAP::NUMBER(18,2)                                                    AS FYAP,
  TOTAL_ANNUAL_PREMIUM::NUMBER(18,2)                                    AS TOTAL_ANNUAL_PREMIUM,
  TOTAL_SUM_ASSURED::NUMBER(20,2)                                       AS TOTAL_SUM_ASSURED,
  -- first-year commission 25-35% of FYAP
  ROUND(FYAP * (0.25 + 0.10 * RND(PK, 900)), 2)::NUMBER(18,2)            AS COMMISSION_AMOUNT,
  RNDI(PK, 901, 8, 24)                                                  AS ACTIVE_DAYS,
  IFF(NEW_POLICIES = 0, TRUE, FALSE)                                    AS IS_ZERO_MONTH
FROM joined;

/* =====================================================================
   FACT_AGENT_ACTIVITY  (~100,000)
   ===================================================================== */
CREATE OR REPLACE TABLE GEN_ACTIVITY_TICKET AS
SELECT ROW_NUMBER() OVER (ORDER BY w.AGENT_ID, g.i) AS TICKET_NO, w.AGENT_ID
FROM (SELECT AGENT_ID, GREATEST(1, ROUND(GEN_ACTIVITY_RATE * 40)::INT) AS tix FROM GEN_AGENT_WINDOW) w
JOIN (SELECT SEQ4() + 1 AS i FROM TABLE(GENERATOR(ROWCOUNT => 40))) g
  ON g.i <= w.tix;

CREATE OR REPLACE TABLE FACT_AGENT_ACTIVITY AS
WITH tn AS (SELECT MAX(TICKET_NO) AS mx FROM GEN_ACTIVITY_TICKET),
r AS (
  SELECT 'ACT' || LPAD((SEQ4()+1)::VARCHAR, 7, '0') AS ACTIVITY_ID
  FROM TABLE(GENERATOR(ROWCOUNT => 100000))
),
pick AS (
  SELECT r.ACTIVITY_ID, t.AGENT_ID
  FROM r CROSS JOIN tn
  JOIN GEN_ACTIVITY_TICKET t ON t.TICKET_NO = 1 + MOD(ABS(HASH(r.ACTIVITY_ID, 910)), tn.mx)
),
dated AS (
  SELECT p.ACTIVITY_ID, p.AGENT_ID, w.BRANCH_ID,
         DATEADD(day, RNDI(p.ACTIVITY_ID, 911, 0, DATEDIFF(day, w.WIN_START, w.WIN_END)), w.WIN_START) AS ACTIVITY_DATE
  FROM pick p JOIN GEN_AGENT_WINDOW w ON w.AGENT_ID = p.AGENT_ID
),
typed AS (
  SELECT d.*, RND(d.ACTIVITY_ID, 912) AS u_type, RND(d.ACTIVITY_ID, 913) AS u_out
  FROM dated d
)
SELECT
  ACTIVITY_ID, AGENT_ID, BRANCH_ID, ACTIVITY_DATE,
  DATE_TRUNC('month', ACTIVITY_DATE)                                    AS ACTIVITY_MONTH,
  YEAR(ACTIVITY_DATE)                                                   AS ACTIVITY_YEAR,
  CASE WHEN u_type < 0.30 THEN 'Prospecting Call'
       WHEN u_type < 0.52 THEN 'Follow Up'
       WHEN u_type < 0.70 THEN 'Client Meeting'
       WHEN u_type < 0.82 THEN 'Product Presentation'
       WHEN u_type < 0.90 THEN 'Policy Review'
       WHEN u_type < 0.96 THEN 'Referral Request'
       ELSE 'Claim Assistance' END                                      AS ACTIVITY_TYPE,
  CASE WHEN u_out < 0.22 THEN 'Follow Up Scheduled'
       WHEN u_out < 0.40 THEN 'Interested'
       WHEN u_out < 0.54 THEN 'No Response'
       WHEN u_out < 0.70 THEN 'Not Interested'
       WHEN u_out < 0.86 THEN 'Proposal Submitted'
       ELSE 'Closed Won' END                                            AS ACTIVITY_OUTCOME,
  ARRAY_CONSTRUCT('Phone','WhatsApp','In Person','Video Call','Email')[RNDI(ACTIVITY_ID,914,0,4)]::VARCHAR AS CHANNEL,
  RNDI(ACTIVITY_ID, 915, 5, 95)                                         AS DURATION_MINUTES,
  'LEAD' || LPAD(RNDI(ACTIVITY_ID, 916, 1, 60000)::VARCHAR, 6, '0')     AS LEAD_ID,
  IFF(u_out < 0.40 OR u_out >= 0.70, TRUE, FALSE)                       AS IS_QUALIFIED_LEAD
FROM typed;

/* =====================================================================
   FACT_AGENT_APPS_BEHAVIOR  (~100,000) — mobile app telemetry
   ===================================================================== */
CREATE OR REPLACE TABLE FACT_AGENT_APPS_BEHAVIOR AS
WITH tn AS (SELECT MAX(TICKET_NO) AS mx FROM GEN_ACTIVITY_TICKET),
r AS (
  SELECT 'BHV' || LPAD((SEQ4()+1)::VARCHAR, 7, '0') AS BEHAVIOR_ID
  FROM TABLE(GENERATOR(ROWCOUNT => 100000))
),
pick AS (
  SELECT r.BEHAVIOR_ID, t.AGENT_ID
  FROM r CROSS JOIN tn
  JOIN GEN_ACTIVITY_TICKET t ON t.TICKET_NO = 1 + MOD(ABS(HASH(r.BEHAVIOR_ID, 930)), tn.mx)
),
dated AS (
  SELECT p.BEHAVIOR_ID, p.AGENT_ID, w.BRANCH_ID,
         DATEADD(day, RNDI(p.BEHAVIOR_ID, 931, 0, DATEDIFF(day, w.WIN_START, w.WIN_END)), w.WIN_START) AS EVENT_DATE,
         RND(p.BEHAVIOR_ID, 932) AS u_evt
  FROM pick p JOIN GEN_AGENT_WINDOW w ON w.AGENT_ID = p.AGENT_ID
)
SELECT
  BEHAVIOR_ID, AGENT_ID, BRANCH_ID,
  EVENT_DATE,
  DATEADD(minute, RNDI(BEHAVIOR_ID, 933, 0, 839), DATEADD(hour, 7, EVENT_DATE::TIMESTAMP_NTZ)) AS EVENT_TIMESTAMP,
  DATE_TRUNC('month', EVENT_DATE)                                       AS EVENT_MONTH,
  YEAR(EVENT_DATE)                                                      AS EVENT_YEAR,
  CASE WHEN u_evt < 0.34 THEN 'Login'
       WHEN u_evt < 0.51 THEN 'View Lead List'
       WHEN u_evt < 0.64 THEN 'Open Recommendation'
       WHEN u_evt < 0.75 THEN 'Run Illustration'
       WHEN u_evt < 0.83 THEN 'Submit e-Application'
       WHEN u_evt < 0.90 THEN 'View Commission Statement'
       WHEN u_evt < 0.96 THEN 'Update Client Profile'
       ELSE 'Complete Training Module' END                              AS EVENT_TYPE,
  RNDI(BEHAVIOR_ID, 934, 1, 42)                                         AS SESSION_MINUTES,
  ARRAY_CONSTRUCT('Android','Android','iOS','Web')[RNDI(BEHAVIOR_ID,935,0,3)]::VARCHAR AS DEVICE,
  ARRAY_CONSTRUCT('4.2.1','4.3.0','4.4.2','5.0.1','5.1.0')[RNDI(BEHAVIOR_ID,936,0,4)]::VARCHAR AS APP_VERSION,
  -- closed-loop signal: was an AI recommendation opened and acted on?
  IFF(u_evt >= 0.51 AND u_evt < 0.64 AND RND(BEHAVIOR_ID, 937) < 0.41, TRUE, FALSE) AS IS_RECOMMENDATION_ACTED
FROM dated;

/* =====================================================================
   FACT_TRAINING  (~3,400)
   ===================================================================== */
CREATE OR REPLACE TABLE FACT_TRAINING AS
WITH courses AS (
  SELECT * FROM VALUES
    ('TRN-001','Meridian Product Fundamentals','Product Knowledge', 8, FALSE),
    ('TRN-002','Unit Link Advanced Illustration','Product Knowledge', 12, FALSE),
    ('TRN-003','AAJI Licensing Refresher','Compliance', 16, TRUE),
    ('TRN-004','Syariah Insurance Principles','Compliance', 10, TRUE),
    ('TRN-005','Consultative Selling Skills','Sales Skills', 14, FALSE),
    ('TRN-006','Objection Handling Masterclass','Sales Skills', 6, FALSE),
    ('TRN-007','Persistency & Retention Playbook','Retention', 8, FALSE),
    ('TRN-008','Digital Tools & e-Application','Digital Enablement', 4, FALSE),
    ('TRN-009','Anti Money Laundering Essentials','Compliance', 6, TRUE),
    ('TRN-010','Financial Needs Analysis','Sales Skills', 10, FALSE),
    ('TRN-011','Health Underwriting Basics','Product Knowledge', 8, FALSE),
    ('TRN-012','Leadership for Unit Managers','Leadership', 20, TRUE)
    AS c(COURSE_CODE, COURSE_NAME, CATEGORY, DURATION_HOURS, IS_CERTIFICATION)
),
n AS (
  SELECT AGENT_ID, BRANCH_ID, WIN_START, WIN_END,
         CASE WHEN RND(AGENT_ID, 950) < 0.06 THEN 0
              WHEN RND(AGENT_ID, 950) < 0.20 THEN 1
              WHEN RND(AGENT_ID, 950) < 0.42 THEN 2
              WHEN RND(AGENT_ID, 950) < 0.66 THEN 3
              WHEN RND(AGENT_ID, 950) < 0.84 THEN 4
              WHEN RND(AGENT_ID, 950) < 0.95 THEN 5
              ELSE 6 END AS n_courses
  FROM GEN_AGENT_WINDOW
),
ex AS (
  SELECT n.*, g.i, n.AGENT_ID || '-T' || g.i::VARCHAR AS PK
  FROM n JOIN (SELECT SEQ4() + 1 AS i FROM TABLE(GENERATOR(ROWCOUNT => 6))) g
    ON g.i <= n.n_courses
),
withc AS (
  SELECT ex.*, c.COURSE_CODE, c.COURSE_NAME, c.CATEGORY, c.DURATION_HOURS, c.IS_CERTIFICATION
  FROM ex
  JOIN courses c ON c.COURSE_CODE = 'TRN-' || LPAD((1 + MOD(ABS(HASH(ex.PK, 951)), 12))::VARCHAR, 3, '0')
)
SELECT
  'TRG' || LPAD(ROW_NUMBER() OVER (ORDER BY AGENT_ID, i)::VARCHAR, 6, '0')       AS TRAINING_ID,
  AGENT_ID, BRANCH_ID, COURSE_CODE, COURSE_NAME, CATEGORY,
  DATEADD(day, RNDI(PK, 952, 0, DATEDIFF(day, WIN_START, WIN_END)), WIN_START)   AS TRAINING_DATE,
  CASE WHEN RND(PK, 953) < 0.82 THEN 'Completed'
       WHEN RND(PK, 953) < 0.94 THEN 'In Progress'
       ELSE 'Not Started' END                                                    AS COMPLETION_STATUS,
  IFF(RND(PK, 953) < 0.82, RNDI(PK, 954, 55, 100), NULL)                         AS SCORE,
  DURATION_HOURS,
  IS_CERTIFICATION,
  ARRAY_CONSTRUCT('Meridian Academy','External - AAJI','E-Learning Platform')[RNDI(PK,955,0,2)]::VARCHAR AS PROVIDER,
  IFF(RND(PK, 956) < 0.55, 'Classroom', 'Online')                                AS DELIVERY_MODE
FROM withc
QUALIFY ROW_NUMBER() OVER (PARTITION BY AGENT_ID, COURSE_CODE ORDER BY i) = 1;   -- no duplicate course per agent

/* ---------------------------------------------------------------------
   Verification
   --------------------------------------------------------------------- */
SELECT 'FACT_AGENT_PRODUCTION' t, COUNT(*) n FROM FACT_AGENT_PRODUCTION
UNION ALL SELECT 'FACT_AGENT_ACTIVITY',      COUNT(*) FROM FACT_AGENT_ACTIVITY
UNION ALL SELECT 'FACT_AGENT_APPS_BEHAVIOR', COUNT(*) FROM FACT_AGENT_APPS_BEHAVIOR
UNION ALL SELECT 'FACT_TRAINING',            COUNT(*) FROM FACT_TRAINING;

-- Production must reconcile exactly with FACT_POLICY
SELECT (SELECT ROUND(SUM(FYAP),2) FROM FACT_POLICY)            AS policy_fyap,
       (SELECT ROUND(SUM(FYAP),2) FROM FACT_AGENT_PRODUCTION)  AS production_fyap,
       (SELECT COUNT(*) FROM FACT_POLICY)                      AS policy_cnt,
       (SELECT SUM(NEW_POLICIES) FROM FACT_AGENT_PRODUCTION)   AS production_cnt;
