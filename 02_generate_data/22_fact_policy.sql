/* =====================================================================
   MERIDIAN LIFE — 22_fact_policy.sql
   The core fact. Embeds the demo "story" patterns:
     (a) month-13 lapse danger zone (plus smaller month-25 echo)
     (b) lapse rate ordered by payment frequency (Yearly best -> Monthly worst)
     (c) branch achievement spread (driven later by FACT_BRANCH_TARGET)
     (d) non-uniform product-class co-occurrence  -> M7 lift > 1
     (e) 3 production spikes + 3 drops in H2-2025  -> M6 anomalies
     (g) right-skewed premium distribution        -> M5 CLV quartiles
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

/* ---------------------------------------------------------------------
   Weighted-pick scaffolding
   --------------------------------------------------------------------- */

-- Agent "lottery tickets" proportional to GEN_PRODUCTIVITY (Pareto emerges)
CREATE OR REPLACE TABLE GEN_AGENT_TICKET AS
SELECT ROW_NUMBER() OVER (ORDER BY a.AGENT_ID, g.i) AS TICKET_NO,
       a.AGENT_ID, a.BRANCH_ID
FROM (
  SELECT AGENT_ID, BRANCH_ID,
         GREATEST(1, ROUND(GEN_PRODUCTIVITY * 60)::INT) AS tix
  FROM DIM_AGENT
  WHERE AGENT_STATUS IN ('INFORCE','TERMINATED')
) a
JOIN (SELECT SEQ4() + 1 AS i FROM TABLE(GENERATOR(ROWCOUNT => 60))) g
  ON g.i <= a.tix;

-- Monthly new-business shape: growth trend x Indonesian seasonality
CREATE OR REPLACE VIEW GEN_MONTH_SHAPE AS
SELECT DATEADD(month, i, '2023-01-01'::DATE) AS MONTH_DATE,
       i                                     AS MONTH_IDX,
       (0.70 + 0.018 * i) *
       CASE MONTH(DATEADD(month, i, '2023-01-01'::DATE))
         WHEN 1 THEN 0.80 WHEN 2 THEN 0.88 WHEN 3  THEN 1.05 WHEN 4  THEN 0.95
         WHEN 5 THEN 0.90 WHEN 6 THEN 1.10 WHEN 7  THEN 0.92 WHEN 8  THEN 0.95
         WHEN 9 THEN 1.05 WHEN 10 THEN 1.00 WHEN 11 THEN 1.05 ELSE 1.35 END AS SHAPE
FROM (SELECT SEQ4() AS i FROM TABLE(GENERATOR(ROWCOUNT => 36)));

-- Branch x month cumulative pick ranges (spike/drop events folded in)
CREATE OR REPLACE VIEW GEN_BM_PICK AS
WITH bm AS (
  SELECT b.BRANCH_ID, m.MONTH_DATE, m.MONTH_IDX,
         m.SHAPE * COALESCE(e.FACTOR, 1.0) AS W
  FROM DIM_BRANCH b
  CROSS JOIN GEN_MONTH_SHAPE m
  LEFT JOIN GEN_BRANCH_MONTH_EVENT e
         ON e.BRANCH_ID = b.BRANCH_ID AND e.EVENT_MONTH = m.MONTH_DATE
  WHERE m.MONTH_DATE >= DATE_TRUNC('month', b.OPEN_DATE)
)
SELECT BRANCH_ID, MONTH_DATE, MONTH_IDX,
       (SUM(W) OVER (PARTITION BY BRANCH_ID ORDER BY MONTH_DATE
                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) - W)
         / SUM(W) OVER (PARTITION BY BRANCH_ID) AS LO,
        SUM(W) OVER (PARTITION BY BRANCH_ID ORDER BY MONTH_DATE
                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
         / SUM(W) OVER (PARTITION BY BRANCH_ID) AS HI
FROM bm;

-- First-policy classification pick ranges
CREATE OR REPLACE VIEW GEN_CLASS_BASE_PICK AS
SELECT CLASSIFICATION,
       (SUM(WEIGHT) OVER (ORDER BY CLASSIFICATION ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) - WEIGHT)
         / SUM(WEIGHT) OVER () AS LO,
        SUM(WEIGHT) OVER (ORDER BY CLASSIFICATION ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
         / SUM(WEIGHT) OVER () AS HI
FROM GEN_CLASS_BASE;

-- Subsequent-policy classification pick ranges (transition matrix)
CREATE OR REPLACE VIEW GEN_CLASS_TRANS_PICK AS
SELECT FROM_CLASS, TO_CLASS,
       (SUM(WEIGHT) OVER (PARTITION BY FROM_CLASS ORDER BY TO_CLASS
                          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) - WEIGHT)
         / SUM(WEIGHT) OVER (PARTITION BY FROM_CLASS) AS LO,
        SUM(WEIGHT) OVER (PARTITION BY FROM_CLASS ORDER BY TO_CLASS
                          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
         / SUM(WEIGHT) OVER (PARTITION BY FROM_CLASS) AS HI
FROM GEN_CLASS_TRANSITION;

-- Product pick ranges within a classification (entry tiers sell more)
CREATE OR REPLACE VIEW GEN_PRODUCT_PICK AS
WITH w AS (
  SELECT PRODUCT_ID, CLASSIFICATION, PREMIUM_FACTOR, MIN_ANNUAL_PREMIUM, DEFAULT_TERM_YEARS,
         CASE PRODUCT_TIER WHEN 1 THEN 0.17 WHEN 2 THEN 0.105 ELSE 0.08 END AS WEIGHT
  FROM DIM_PRODUCT
)
SELECT PRODUCT_ID, CLASSIFICATION,
       (SUM(WEIGHT) OVER (PARTITION BY CLASSIFICATION ORDER BY PRODUCT_ID
                          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) - WEIGHT)
         / SUM(WEIGHT) OVER (PARTITION BY CLASSIFICATION) AS LO,
        SUM(WEIGHT) OVER (PARTITION BY CLASSIFICATION ORDER BY PRODUCT_ID
                          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
         / SUM(WEIGHT) OVER (PARTITION BY CLASSIFICATION) AS HI
FROM w;

-- Sum-assured multiples per classification
CREATE OR REPLACE TABLE GEN_CLASS_SA (CLASSIFICATION VARCHAR(40), SA_LO INT, SA_HI INT);
INSERT INTO GEN_CLASS_SA VALUES
 ('Life',60,120),('Health',20,40),('Critical Illness',30,60),('Accident',80,200),
 ('Unit Link',8,20),('Savings',5,12),('Education',8,18),('Retirement',6,14);

/* ---------------------------------------------------------------------
   Candidate pool -> exactly 7,400 accepted policies
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE GEN_POLICY_CAND AS
WITH tn AS (SELECT MAX(TICKET_NO) AS mx FROM GEN_AGENT_TICKET),
c AS (
  SELECT 'X' || LPAD((SEQ4()+1)::VARCHAR, 6, '0') AS CK
  FROM TABLE(GENERATOR(ROWCOUNT => 60000))
),
pick_a AS (
  SELECT c.CK, t.AGENT_ID, t.BRANCH_ID
  FROM c CROSS JOIN tn
  JOIN GEN_AGENT_TICKET t ON t.TICKET_NO = 1 + MOD(ABS(HASH(c.CK, 501)), tn.mx)
),
pick_m AS (
  SELECT p.CK, p.AGENT_ID, p.BRANCH_ID, bm.MONTH_DATE
  FROM pick_a p
  JOIN GEN_BM_PICK bm
    ON bm.BRANCH_ID = p.BRANCH_ID
   AND RND(p.CK, 502) >= bm.LO
   AND RND(p.CK, 502) <  bm.HI
),
dated AS (
  SELECT m.CK, m.AGENT_ID, m.BRANCH_ID,
         DATEADD(day, RNDI(m.CK, 503, 0, 27), m.MONTH_DATE) AS ISSUE_DATE
  FROM pick_m m
)
SELECT d.CK, d.AGENT_ID, d.BRANCH_ID, d.ISSUE_DATE
FROM dated d
JOIN DIM_AGENT a ON a.AGENT_ID = d.AGENT_ID
WHERE d.ISSUE_DATE >= a.JOIN_DATE
  AND (a.TERMINATION_DATE IS NULL OR d.ISSUE_DATE <= a.TERMINATION_DATE)
  AND d.ISSUE_DATE BETWEEN '2023-01-01' AND '2025-12-31'
QUALIFY ROW_NUMBER() OVER (ORDER BY RND(d.CK, 599)) <= 7400;

/* ---------------------------------------------------------------------
   Customer slots (1-4 policies per customer)
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE GEN_CUST_SLOT AS
WITH c AS (
  SELECT CUSTOMER_ID,
         CASE WHEN RND(CUSTOMER_ID, 601) < 0.52 THEN 1
              WHEN RND(CUSTOMER_ID, 601) < 0.82 THEN 2
              WHEN RND(CUSTOMER_ID, 601) < 0.95 THEN 3
              ELSE 4 END AS n
  FROM DIM_CUSTOMER
)
SELECT c.CUSTOMER_ID, g.i AS SLOT_NO,
       ROW_NUMBER() OVER (ORDER BY RND(c.CUSTOMER_ID || '#' || g.i::VARCHAR, 602)) AS SLOT_RANK
FROM c
JOIN (SELECT SEQ4() + 1 AS i FROM TABLE(GENERATOR(ROWCOUNT => 4))) g
  ON g.i <= c.n;

/* ---------------------------------------------------------------------
   FACT_POLICY
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE FACT_POLICY AS
WITH cand AS (
  SELECT CK, AGENT_ID, BRANCH_ID, ISSUE_DATE,
         ROW_NUMBER() OVER (ORDER BY ISSUE_DATE, CK) AS rn
  FROM GEN_POLICY_CAND
),
joined AS (
  SELECT 'POL' || LPAD(c.rn::VARCHAR, 6, '0') AS POLICY_ID,
         s.CUSTOMER_ID, c.AGENT_ID, c.BRANCH_ID, c.ISSUE_DATE
  FROM cand c
  JOIN GEN_CUST_SLOT s ON s.SLOT_RANK = c.rn
),
seqd AS (
  SELECT j.*,
         ROW_NUMBER() OVER (PARTITION BY j.CUSTOMER_ID ORDER BY j.ISSUE_DATE, j.POLICY_ID) AS SEQ_NO
  FROM joined j
),
-- first policy per customer: base classification mix
cls1 AS (
  SELECT s.POLICY_ID, s.CUSTOMER_ID, p.CLASSIFICATION
  FROM seqd s
  JOIN GEN_CLASS_BASE_PICK p
    ON RND(s.POLICY_ID, 610) >= p.LO AND RND(s.POLICY_ID, 610) < p.HI
  WHERE s.SEQ_NO = 1
),
-- later policies: transition from the customer's first classification
clsN AS (
  SELECT s.POLICY_ID, s.CUSTOMER_ID, t.TO_CLASS AS CLASSIFICATION
  FROM seqd s
  JOIN cls1 f ON f.CUSTOMER_ID = s.CUSTOMER_ID
  JOIN GEN_CLASS_TRANS_PICK t
    ON t.FROM_CLASS = f.CLASSIFICATION
   AND RND(s.POLICY_ID, 611) >= t.LO AND RND(s.POLICY_ID, 611) < t.HI
  WHERE s.SEQ_NO > 1
),
allcls AS (
  SELECT POLICY_ID, CLASSIFICATION FROM cls1
  UNION ALL
  SELECT POLICY_ID, CLASSIFICATION FROM clsN
),
withprod AS (
  SELECT s.POLICY_ID, s.CUSTOMER_ID, s.AGENT_ID, s.BRANCH_ID, s.ISSUE_DATE, s.SEQ_NO,
         a.CLASSIFICATION, pp.PRODUCT_ID
  FROM seqd s
  JOIN allcls a ON a.POLICY_ID = s.POLICY_ID
  JOIN GEN_PRODUCT_PICK pp
    ON pp.CLASSIFICATION = a.CLASSIFICATION
   AND RND(s.POLICY_ID, 612) >= pp.LO AND RND(s.POLICY_ID, 612) < pp.HI
),
econ AS (
  SELECT w.*,
         d.PREMIUM_FACTOR, d.MIN_ANNUAL_PREMIUM, d.DEFAULT_TERM_YEARS,
         sa.SA_LO, sa.SA_HI,
         gbf.ACH_2025,
         -- (g) right-skewed premium (log-normal) scaled by product factor
         LEAST(400000000,
           GREATEST(d.MIN_ANNUAL_PREMIUM,
             ROUND(EXP(14.60 + 0.95 * RNDN(w.POLICY_ID, 620)) * d.PREMIUM_FACTOR, -5)
           ))::NUMBER(18,2)                                                     AS ANNUAL_PREMIUM,
         -- single-premium only for investment-linked classes
         CASE WHEN w.CLASSIFICATION IN ('Unit Link','Retirement','Education')
                   AND RND(w.POLICY_ID, 630) < 0.06 THEN 'Single' ELSE 'Regular' END AS PAYMENT_MODE,
         RND(w.POLICY_ID, 631)                                                  AS u_freq
  FROM withprod w
  JOIN DIM_PRODUCT   d   ON d.PRODUCT_ID = w.PRODUCT_ID
  JOIN GEN_CLASS_SA  sa  ON sa.CLASSIFICATION = w.CLASSIFICATION
  JOIN GEN_BRANCH_FACTOR gbf ON gbf.BRANCH_ID = w.BRANCH_ID
),
freq AS (
  SELECT e.*,
         -- mix calibrated so total instalments land on the ~45k target
         CASE WHEN PAYMENT_MODE = 'Single'  THEN 'Single'
              WHEN u_freq < 0.36 THEN 'Monthly'
              WHEN u_freq < 0.61 THEN 'Quarterly'
              WHEN u_freq < 0.79 THEN 'Semi-Annual'
              ELSE 'Yearly' END                                                AS PAYMENT_FREQUENCY
  FROM econ e
),
lapse AS (
  SELECT f.*,
         CASE PAYMENT_FREQUENCY
           WHEN 'Monthly'     THEN 0.42
           WHEN 'Quarterly'   THEN 0.33
           WHEN 'Semi-Annual' THEN 0.24
           WHEN 'Yearly'      THEN 0.13
           ELSE 0.00 END
         * IFF(COALESCE(ACH_2025, 1.0) < 0.60, 1.30, 1.00)                     AS LAPSE_PROPENSITY,
         -- (a) danger zone: 26% of lapses at month 13, 9% at month 25
         CASE WHEN RND(POLICY_ID, 640) < 0.26 THEN 13
              WHEN RND(POLICY_ID, 640) < 0.35 THEN 25
              ELSE RNDI(POLICY_ID, 641, 2, 35) END                             AS LAPSE_MONTH_CAND
  FROM freq f
),
resolved AS (
  SELECT l.*,
         RND(POLICY_ID, 642) < LAPSE_PROPENSITY                                AS WILL_LAPSE,
         DATEADD(month, LAPSE_MONTH_CAND, ISSUE_DATE)                          AS LAPSE_DATE_CAND,
         RNDI(POLICY_ID, 650, 6, 34)                                           AS TERM_MONTH_CAND,
         RND(POLICY_ID, 651)                                                   AS u_term
  FROM lapse l
)
SELECT
  POLICY_ID,
  'MRD-' || TO_VARCHAR(ISSUE_DATE,'YYYY') || '-' || RIGHT(POLICY_ID, 6)         AS POLICY_NUMBER,
  CUSTOMER_ID, PRODUCT_ID, AGENT_ID, BRANCH_ID,
  ISSUE_DATE,
  SEQ_NO                                                                        AS CUSTOMER_POLICY_SEQ,
  CASE
    WHEN WILL_LAPSE AND LAPSE_DATE_CAND <= '2025-12-31'::DATE THEN 'Lapsed'
    WHEN NOT WILL_LAPSE AND u_term < 0.045
         AND DATEADD(month, TERM_MONTH_CAND, ISSUE_DATE) <= '2025-12-31'::DATE  THEN 'Terminated'
    ELSE 'Inforce' END                                                          AS POLICY_STATUS,
  ANNUAL_PREMIUM,
  -- FYAP: full annualized premium for regular business, 10% credit for single premium
  IFF(PAYMENT_MODE = 'Single', ROUND(ANNUAL_PREMIUM * 0.10, 2), ANNUAL_PREMIUM)::NUMBER(18,2) AS FYAP,
  ROUND(ANNUAL_PREMIUM * RNDI(POLICY_ID, 660, SA_LO, SA_HI), -6)::NUMBER(20,2)  AS SUM_ASSURED,
  PAYMENT_MODE,
  PAYMENT_FREQUENCY,
  CASE PAYMENT_FREQUENCY WHEN 'Monthly' THEN 12 WHEN 'Quarterly' THEN 4
                         WHEN 'Semi-Annual' THEN 2 WHEN 'Yearly' THEN 1 ELSE 1 END AS INSTALLMENTS_PER_YEAR,
  ROUND(ANNUAL_PREMIUM /
        CASE PAYMENT_FREQUENCY WHEN 'Monthly' THEN 12 WHEN 'Quarterly' THEN 4
                               WHEN 'Semi-Annual' THEN 2 ELSE 1 END, 2)::NUMBER(18,2) AS INSTALLMENT_AMOUNT,
  DEFAULT_TERM_YEARS                                                            AS TERM_YEARS,
  DATEADD(year, DEFAULT_TERM_YEARS, ISSUE_DATE)                                 AS MATURITY_DATE,
  IFF(WILL_LAPSE AND LAPSE_DATE_CAND <= '2025-12-31'::DATE, LAPSE_DATE_CAND, NULL) AS LAPSE_DATE,
  IFF(WILL_LAPSE AND LAPSE_DATE_CAND <= '2025-12-31'::DATE, LAPSE_MONTH_CAND, NULL) AS POLICY_MONTH_AT_LAPSE,
  IFF(NOT WILL_LAPSE AND u_term < 0.045
      AND DATEADD(month, TERM_MONTH_CAND, ISSUE_DATE) <= '2025-12-31'::DATE,
      DATEADD(month, TERM_MONTH_CAND, ISSUE_DATE), NULL)                        AS TERMINATION_DATE,
  CASE WHEN NOT WILL_LAPSE AND u_term < 0.045
            AND DATEADD(month, TERM_MONTH_CAND, ISSUE_DATE) <= '2025-12-31'::DATE
       THEN CASE WHEN RND(POLICY_ID, 652) < 0.55 THEN 'Surrender'
                 WHEN RND(POLICY_ID, 652) < 0.75 THEN 'Death Claim'
                 WHEN RND(POLICY_ID, 652) < 0.85 THEN 'Maturity'
                 ELSE 'Free-Look Cancellation' END
  END                                                                           AS TERMINATION_REASON,
  -- next annual renewal (policy anniversary) after the observation cut-off
  CASE
    WHEN (WILL_LAPSE AND LAPSE_DATE_CAND <= '2025-12-31'::DATE)
      OR (NOT WILL_LAPSE AND u_term < 0.045
          AND DATEADD(month, TERM_MONTH_CAND, ISSUE_DATE) <= '2025-12-31'::DATE) THEN NULL
    ELSE DATEADD(year,
                 DATEDIFF(year, ISSUE_DATE, '2025-12-31'::DATE) + 1, ISSUE_DATE)
  END                                                                           AS NEXT_RENEWAL_DATE,
  IFF(ISSUE_DATE >= '2025-01-01'::DATE, TRUE, FALSE)                            AS IS_FIRST_YEAR_2025,
  CASE WHEN RND(POLICY_ID, 670) < 0.62 THEN 'e-Application'
       WHEN RND(POLICY_ID, 670) < 0.84 THEN 'Paper Application'
       ELSE 'Digital Self-Service' END                                          AS SUBMISSION_CHANNEL,
  CASE WHEN RND(POLICY_ID, 671) < 0.78 THEN 'Standard'
       WHEN RND(POLICY_ID, 671) < 0.92 THEN 'Substandard - Loading'
       ELSE 'Standard - Exclusion Applied' END                                  AS UNDERWRITING_DECISION,
  DATE_TRUNC('month', ISSUE_DATE)                                               AS ISSUE_MONTH,
  YEAR(ISSUE_DATE)                                                              AS ISSUE_YEAR
FROM resolved;

/* ---------------------------------------------------------------------
   Align customer geography with the branch of their first policy
   (a customer is served by the branch that wrote their first policy)
   --------------------------------------------------------------------- */
UPDATE DIM_CUSTOMER c
SET CITY = b.CITY, PROVINCE = b.PROVINCE, REGION = b.REGION
FROM (
  SELECT p.CUSTOMER_ID, br.CITY, br.PROVINCE, br.REGION
  FROM FACT_POLICY p
  JOIN DIM_BRANCH br ON br.BRANCH_ID = p.BRANCH_ID
  WHERE p.CUSTOMER_POLICY_SEQ = 1
) b
WHERE c.CUSTOMER_ID = b.CUSTOMER_ID;

/* ---------------------------------------------------------------------
   Verification of the embedded patterns
   --------------------------------------------------------------------- */
SELECT COUNT(*) AS policies, COUNT(DISTINCT CUSTOMER_ID) AS customers,
       COUNT(DISTINCT AGENT_ID) AS producing_agents, COUNT(DISTINCT BRANCH_ID) AS branches,
       MIN(ISSUE_DATE) AS first_issue, MAX(ISSUE_DATE) AS last_issue
FROM FACT_POLICY;

-- Pattern (a): month-13 spike
WITH d AS (
  SELECT POLICY_MONTH_AT_LAPSE AS m, COUNT(*) n
  FROM FACT_POLICY WHERE POLICY_STATUS = 'Lapsed' GROUP BY 1
), avg_other AS (
  SELECT AVG(n) a FROM d WHERE m NOT IN (13, 25)
)
SELECT d.m AS lapse_month, d.n AS lapses,
       ROUND(d.n / (SELECT a FROM avg_other), 1) AS x_vs_baseline
FROM d WHERE d.m IN (12,13,14,24,25,26) ORDER BY d.m;

-- Pattern (b): lapse rate by payment frequency
SELECT PAYMENT_FREQUENCY, COUNT(*) policies,
       ROUND(100.0 * SUM(IFF(POLICY_STATUS='Lapsed',1,0)) / COUNT(*), 2) AS lapse_pct
FROM FACT_POLICY GROUP BY 1 ORDER BY lapse_pct;
