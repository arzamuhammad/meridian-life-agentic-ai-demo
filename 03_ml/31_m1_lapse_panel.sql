/* =====================================================================
   MERIDIAN LIFE — 31_m1_lapse_panel.sql
   M1 point-in-time panel for 90-day lapse prediction.

   FRAMING
     One row per (as-of date T, policy active at T).
     Label = the policy lapses within (T, T + 90 days].

   ANTI-LEAKAGE RULES ENFORCED HERE
     1. Every behavioural feature uses a TRAILING window ending strictly
        before T. Confirmed payments are filtered on
        COLLECTION_PAYMENT_DATE < T (never on DUE_DATE alone); an unpaid
        instalment is only visible if its DUE_DATE < T.
     2. NO lifetime aggregates (no TOTAL_PAYMENTS, no lifetime late count).
     3. Tenure is measured as-of T, never from CURRENT_DATE.
     4. These FACT_POLICY columns are label-bearing and are NEVER features:
        POLICY_STATUS, LAPSE_DATE, POLICY_MONTH_AT_LAPSE, TERMINATION_DATE,
        TERMINATION_REASON, NEXT_RENEWAL_DATE (NULL only when the policy
        already died -> a direct leak), IS_FIRST_YEAR_2025.
     5. Single-premium policies are excluded: they are structurally not at
        risk of lapse and would only pad the negatives.

   SPLIT
     Train  T <= 2024-12-01     Test  T in 2025-01-01 .. 2025-10-01
     Score  T  = 2025-12-01     (label not yet observable -> production set)
     A label is only observable when T + 90d <= 2025-12-31, i.e. T <= 2025-10-01.
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

CREATE OR REPLACE TABLE ML_LAPSE_PANEL AS
WITH snap AS (
  -- monthly as-of snapshots 2023-04-01 .. 2025-12-01
  SELECT DATEADD(month, SEQ4(), '2023-04-01'::DATE) AS T
  FROM TABLE(GENERATOR(ROWCOUNT => 33))
),
pol AS (
  SELECT p.POLICY_ID, p.CUSTOMER_ID, p.AGENT_ID, p.BRANCH_ID, p.PRODUCT_ID,
         p.ISSUE_DATE, p.ANNUAL_PREMIUM, p.INSTALLMENT_AMOUNT, p.INSTALLMENTS_PER_YEAR,
         p.PAYMENT_FREQUENCY, p.SUM_ASSURED, p.SUBMISSION_CHANNEL, p.UNDERWRITING_DECISION,
         p.LAPSE_DATE, p.TERMINATION_DATE,
         d.CLASSIFICATION, d.PRODUCT_TIER, d.PRODUCT_TYPE
  FROM FACT_POLICY p
  JOIN DIM_PRODUCT d ON d.PRODUCT_ID = p.PRODUCT_ID
  WHERE p.PAYMENT_MODE = 'Regular'
),
base AS (
  SELECT a.T, p.*
  FROM snap a
  JOIN pol  p
    ON p.ISSUE_DATE < a.T                                        -- already in force at T
   AND (p.LAPSE_DATE       IS NULL OR p.LAPSE_DATE       > a.T)  -- not already lapsed
   AND (p.TERMINATION_DATE IS NULL OR p.TERMINATION_DATE > a.T)  -- not already terminated
),
/* ---- trailing payment behaviour (the core signal) ------------------- */
pay AS (
  SELECT b.T, b.POLICY_ID,
    COUNT_IF(y.FEE_STATUS = 'Payment Confirmed'
             AND y.COLLECTION_PAYMENT_DATE >= DATEADD(day, -90,  b.T))          AS PAID_CNT_90D,
    COUNT_IF(y.FEE_STATUS = 'Payment Confirmed'
             AND y.COLLECTION_PAYMENT_DATE >= DATEADD(day, -365, b.T))          AS PAID_CNT_365D,
    COUNT_IF(y.IS_LATE
             AND y.COLLECTION_PAYMENT_DATE >= DATEADD(day, -90,  b.T))          AS LATE_CNT_90D,
    COUNT_IF(y.IS_LATE
             AND y.COLLECTION_PAYMENT_DATE >= DATEADD(day, -365, b.T))          AS LATE_CNT_365D,
    COUNT_IF(y.FEE_STATUS <> 'Payment Confirmed'
             AND y.DUE_DATE >= DATEADD(day, -90,  b.T))                         AS UNPAID_CNT_90D,
    COUNT_IF(y.FEE_STATUS <> 'Payment Confirmed'
             AND y.DUE_DATE >= DATEADD(day, -365, b.T))                         AS UNPAID_CNT_365D,
    AVG(IFF(y.COLLECTION_PAYMENT_DATE >= DATEADD(day, -365, b.T), y.DAYS_LATE, NULL))  AS AVG_DAYS_LATE_365D,
    MAX(IFF(y.COLLECTION_PAYMENT_DATE >= DATEADD(day, -365, b.T), y.DAYS_LATE, NULL))  AS MAX_DAYS_LATE_365D,
    DATEDIFF(day, MAX(y.COLLECTION_PAYMENT_DATE), b.T)                          AS DAYS_SINCE_LAST_PAYMENT,
    DATEDIFF(day, MAX(y.DUE_DATE), b.T)                                         AS DAYS_SINCE_LAST_DUE
  FROM base b
  LEFT JOIN FACT_POLICY_PAYMENT y
    ON y.POLICY_ID = b.POLICY_ID
   AND ( (y.FEE_STATUS =  'Payment Confirmed' AND y.COLLECTION_PAYMENT_DATE < b.T)
      OR (y.FEE_STATUS <> 'Payment Confirmed' AND y.DUE_DATE                < b.T) )
  GROUP BY 1,2
),
/* ---- trailing claims ------------------------------------------------ */
clm AS (
  SELECT b.T, b.POLICY_ID,
    COUNT(c.CLAIM_ID)                                                    AS CLAIM_CNT_365D,
    COUNT_IF(c.CLAIM_DECISION = 'Rejected')                              AS CLAIM_REJECTED_365D,
    COALESCE(SUM(c.APPROVED_AMOUNT), 0)                                  AS CLAIM_APPROVED_AMT_365D
  FROM base b
  LEFT JOIN FACT_CLAIMS c
    ON c.POLICY_ID = b.POLICY_ID
   AND c.DECISION_DATE < b.T                       -- decision must be known at T
   AND c.CLAIM_DATE   >= DATEADD(day, -365, b.T)
  GROUP BY 1,2
),
/* ---- trailing CRM tickets ------------------------------------------- */
tkt AS (
  SELECT b.T, b.POLICY_ID,
    COUNT(k.TICKET_ID)                                                   AS TICKET_CNT_365D,
    COUNT_IF(k.IS_RETENTION_RELATED)                                     AS RETENTION_TICKET_365D,
    COUNT_IF(k.SENTIMENT = 'Negative')                                   AS NEGATIVE_TICKET_365D
  FROM base b
  LEFT JOIN FACT_CRM_TICKETS k
    ON k.POLICY_ID  = b.POLICY_ID
   AND k.TICKET_DATE < b.T
   AND k.TICKET_DATE >= DATEADD(day, -365, b.T)
  GROUP BY 1,2
),
/* ---- riders attached before T --------------------------------------- */
rid AS (
  SELECT b.T, b.POLICY_ID,
    COUNT(r.RIDER_ID)                                                    AS RIDER_CNT,
    COALESCE(SUM(r.RIDER_PREMIUM), 0)                                    AS RIDER_PREMIUM_TOTAL
  FROM base b
  LEFT JOIN FACT_POLICY_RIDER r
    ON r.POLICY_ID = b.POLICY_ID AND r.ATTACH_DATE < b.T
  GROUP BY 1,2
),
/* ---- how many policies did this customer hold before T? ------------- */
cust_cnt AS (
  SELECT b.T, b.POLICY_ID, COUNT(o.POLICY_ID) AS CUST_POLICY_CNT_AT_T
  FROM base b
  LEFT JOIN FACT_POLICY o
    ON o.CUSTOMER_ID = b.CUSTOMER_ID AND o.ISSUE_DATE < b.T
  GROUP BY 1,2
)
SELECT
  b.T                                                                    AS ASOF_DATE,
  b.POLICY_ID, b.CUSTOMER_ID, b.AGENT_ID, b.BRANCH_ID, b.PRODUCT_ID,

  /* ---------- LABEL ---------- */
  IFF(b.LAPSE_DATE > b.T AND b.LAPSE_DATE <= DATEADD(day, 90, b.T), 1, 0) AS LAPSE_IN_90D,
  IFF(DATEADD(day, 90, b.T) <= '2025-12-31'::DATE, TRUE, FALSE)           AS LABEL_OBSERVABLE,
  CASE WHEN b.T <= '2024-12-01'::DATE                       THEN 'TRAIN'
       WHEN b.T <= '2025-10-01'::DATE                       THEN 'TEST'
       ELSE 'SCORE' END                                                   AS SPLIT_TAG,

  /* ---------- tenure features (as-of T, never CURRENT_DATE) ---------- */
  DATEDIFF(month, b.ISSUE_DATE, b.T)                                     AS TENURE_MONTHS,
  DATEDIFF(day,   b.ISSUE_DATE, b.T)                                     AS TENURE_DAYS,
  13 - DATEDIFF(month, b.ISSUE_DATE, b.T)                                AS MONTHS_TO_M13,
  IFF(DATEDIFF(month, b.ISSUE_DATE, b.T) BETWEEN 10 AND 13, 1, 0)        AS IN_M13_WINDOW,
  IFF(DATEDIFF(month, b.ISSUE_DATE, b.T) BETWEEN 22 AND 25, 1, 0)        AS IN_M25_WINDOW,
  MOD(DATEDIFF(month, b.ISSUE_DATE, b.T), 12)                            AS POLICY_MONTH_IN_YEAR,

  /* ---------- contract features (known at issue) -------------------- */
  b.ANNUAL_PREMIUM::FLOAT                                                AS ANNUAL_PREMIUM,
  b.INSTALLMENT_AMOUNT::FLOAT                                            AS INSTALLMENT_AMOUNT,
  b.INSTALLMENTS_PER_YEAR::FLOAT                                         AS INSTALLMENTS_PER_YEAR,
  b.SUM_ASSURED::FLOAT                                                   AS SUM_ASSURED,
  b.PRODUCT_TIER::FLOAT                                                  AS PRODUCT_TIER,
  b.PAYMENT_FREQUENCY, b.CLASSIFICATION, b.PRODUCT_TYPE,
  b.SUBMISSION_CHANNEL, b.UNDERWRITING_DECISION,

  /* ---------- trailing payment behaviour ---------------------------- */
  COALESCE(p.PAID_CNT_90D, 0)::FLOAT                                     AS PAID_CNT_90D,
  COALESCE(p.PAID_CNT_365D, 0)::FLOAT                                    AS PAID_CNT_365D,
  COALESCE(p.LATE_CNT_90D, 0)::FLOAT                                     AS LATE_CNT_90D,
  COALESCE(p.LATE_CNT_365D, 0)::FLOAT                                    AS LATE_CNT_365D,
  COALESCE(p.UNPAID_CNT_90D, 0)::FLOAT                                   AS UNPAID_CNT_90D,
  COALESCE(p.UNPAID_CNT_365D, 0)::FLOAT                                  AS UNPAID_CNT_365D,
  p.AVG_DAYS_LATE_365D::FLOAT                                            AS AVG_DAYS_LATE_365D,
  p.MAX_DAYS_LATE_365D::FLOAT                                            AS MAX_DAYS_LATE_365D,
  p.DAYS_SINCE_LAST_PAYMENT::FLOAT                                       AS DAYS_SINCE_LAST_PAYMENT,
  p.DAYS_SINCE_LAST_DUE::FLOAT                                           AS DAYS_SINCE_LAST_DUE,
  ROUND(COALESCE(p.PAID_CNT_365D,0)
        / NULLIF(COALESCE(p.PAID_CNT_365D,0) + COALESCE(p.UNPAID_CNT_365D,0), 0), 4)::FLOAT AS PAID_RATIO_365D,

  /* ---------- trailing claims / service ----------------------------- */
  COALESCE(c.CLAIM_CNT_365D, 0)::FLOAT                                   AS CLAIM_CNT_365D,
  COALESCE(c.CLAIM_REJECTED_365D, 0)::FLOAT                              AS CLAIM_REJECTED_365D,
  COALESCE(c.CLAIM_APPROVED_AMT_365D, 0)::FLOAT                          AS CLAIM_APPROVED_AMT_365D,
  COALESCE(k.TICKET_CNT_365D, 0)::FLOAT                                  AS TICKET_CNT_365D,
  COALESCE(k.RETENTION_TICKET_365D, 0)::FLOAT                            AS RETENTION_TICKET_365D,
  COALESCE(k.NEGATIVE_TICKET_365D, 0)::FLOAT                             AS NEGATIVE_TICKET_365D,

  /* ---------- product holding / customer ---------------------------- */
  COALESCE(r.RIDER_CNT, 0)::FLOAT                                        AS RIDER_CNT,
  COALESCE(r.RIDER_PREMIUM_TOTAL, 0)::FLOAT                              AS RIDER_PREMIUM_TOTAL,
  COALESCE(cc.CUST_POLICY_CNT_AT_T, 1)::FLOAT                            AS CUST_POLICY_CNT_AT_T,
  DATEDIFF(year, cu.BIRTH_DATE, b.T)::FLOAT                              AS CUSTOMER_AGE_AT_T,
  CASE cu.INCOME_BAND
       WHEN 'Below Rp 10M/month'    THEN 1 WHEN 'Rp 10M - 25M/month'  THEN 2
       WHEN 'Rp 25M - 50M/month'    THEN 3 WHEN 'Rp 50M - 100M/month' THEN 4
       ELSE 5 END::FLOAT                                                 AS INCOME_BAND_ORD,
  cu.MARITAL_STATUS, cu.OCCUPATION,

  /* ---------- servicing agent state at T ---------------------------- */
  DATEDIFF(month, ag.JOIN_DATE, b.T)::FLOAT                              AS AGENT_TENURE_MONTHS_AT_T,
  IFF(ag.TERMINATION_DATE IS NOT NULL AND ag.TERMINATION_DATE < b.T, 1, 0)::FLOAT AS AGENT_GONE_AT_T,
  ag.AGENT_LEVEL

FROM base b
LEFT JOIN pay      p  ON p.T  = b.T AND p.POLICY_ID  = b.POLICY_ID
LEFT JOIN clm      c  ON c.T  = b.T AND c.POLICY_ID  = b.POLICY_ID
LEFT JOIN tkt      k  ON k.T  = b.T AND k.POLICY_ID  = b.POLICY_ID
LEFT JOIN rid      r  ON r.T  = b.T AND r.POLICY_ID  = b.POLICY_ID
LEFT JOIN cust_cnt cc ON cc.T = b.T AND cc.POLICY_ID = b.POLICY_ID
JOIN DIM_CUSTOMER cu ON cu.CUSTOMER_ID = b.CUSTOMER_ID
JOIN DIM_AGENT    ag ON ag.AGENT_ID    = b.AGENT_ID;

/* ---------------------------------------------------------------------
   Panel diagnostics
   --------------------------------------------------------------------- */
SELECT SPLIT_TAG, COUNT(*) AS rows_, COUNT(DISTINCT ASOF_DATE) AS snapshots,
       COUNT(DISTINCT POLICY_ID) AS policies,
       SUM(LAPSE_IN_90D) AS positives,
       ROUND(100.0 * SUM(LAPSE_IN_90D) / COUNT(*), 3) AS positive_rate_pct,
       MIN(ASOF_DATE) AS first_asof, MAX(ASOF_DATE) AS last_asof
FROM ML_LAPSE_PANEL
GROUP BY 1 ORDER BY first_asof;
