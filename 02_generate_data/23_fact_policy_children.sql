/* =====================================================================
   MERIDIAN LIFE — 23_fact_policy_children.sql
   FACT_POLICY_PAYMENT, FACT_POLICY_RIDER, FACT_CLAIMS
   Payment behaviour deliberately degrades in the months before a lapse
   (late days ramp, then Failed) so that M1 has genuine trailing-window
   signal WITHOUT any leakage of the label.
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

/* =====================================================================
   FACT_POLICY_PAYMENT
   ===================================================================== */
CREATE OR REPLACE TABLE FACT_POLICY_PAYMENT AS
WITH p AS (
  SELECT POLICY_ID, CUSTOMER_ID, BRANCH_ID, AGENT_ID, ISSUE_DATE, POLICY_STATUS,
         PAYMENT_MODE, PAYMENT_FREQUENCY, INSTALLMENTS_PER_YEAR, INSTALLMENT_AMOUNT,
         LAPSE_DATE, TERMINATION_DATE,
         LEAST('2025-12-31'::DATE, COALESCE(LAPSE_DATE, TERMINATION_DATE, '2025-12-31'::DATE)) AS END_DATE,
         (12 / INSTALLMENTS_PER_YEAR)::INT AS MONTH_STEP,
         -- Only ~55% of lapses are preceded by visible billing deterioration.
         -- The rest are "silent" lapses (deliberate non-renewal by an
         -- always-on-time payer) -- without this the pre-lapse ramp becomes a
         -- near-deterministic function of the label and M1 scores an
         -- unrealistic AUC ~0.97.
         IFF(RND(POLICY_ID, 760) < 0.55, TRUE, FALSE)  AS SIGNAL_VISIBLE,
         -- ~14% of policies that never lapse still go through a late episode
         -- and recover. These false alarms are what make the problem hard.
         IFF(RND(POLICY_ID, 761) < 0.14, TRUE, FALSE)  AS FALSE_ALARM,
         RNDI(POLICY_ID, 762, 2, 24)                   AS STRESS_START
  FROM FACT_POLICY
),
sched AS (
  SELECT p.*,
         g.k,
         DATEADD(month, g.k * p.MONTH_STEP, p.ISSUE_DATE) AS DUE_DATE
  FROM p
  JOIN (SELECT SEQ4() AS k FROM TABLE(GENERATOR(ROWCOUNT => 40))) g
    ON DATEADD(month, g.k * p.MONTH_STEP, p.ISSUE_DATE) <= p.END_DATE
  WHERE p.PAYMENT_MODE = 'Regular' OR g.k = 0        -- single premium = one instalment
),
tagged AS (
  SELECT s.*,
         s.POLICY_ID || '-' || s.k::VARCHAR                        AS PK,
         DATEDIFF(month, s.DUE_DATE, s.END_DATE)                   AS MONTHS_TO_END,
         IFF(s.POLICY_STATUS = 'Lapsed', TRUE, FALSE)              AS IS_LAPSING
  FROM sched s
),
behaved AS (
  SELECT t.*,
         -- Gradual deterioration spread over up to 8 months before a lapse
         -- (not a cliff inside the 90-day label window), plus a symmetric
         -- false-alarm episode for policies that recover. The two
         -- distributions deliberately OVERLAP.
         GREATEST(0,
           ROUND( (RNDN(t.PK, 700) * 7.0 - 2.0)
                  + IFF(t.IS_LAPSING AND t.SIGNAL_VISIBLE
                        AND t.MONTHS_TO_END BETWEEN 0 AND 8,
                        6 + RNDI(t.PK, 701, 0, 30), 0)
                  + IFF(NOT t.IS_LAPSING AND t.FALSE_ALARM
                        AND DATEDIFF(month, t.ISSUE_DATE, t.DUE_DATE)
                            BETWEEN t.STRESS_START AND t.STRESS_START + 8,
                        6 + RNDI(t.PK, 702, 0, 30), 0) )
         )::INT                                                    AS DAYS_LATE,
         RND(t.PK, 710)                                            AS u_status
  FROM tagged t
)
SELECT
  'PAY' || LPAD(ROW_NUMBER() OVER (ORDER BY POLICY_ID, k)::VARCHAR, 8, '0')      AS PAYMENT_ID,
  POLICY_ID, CUSTOMER_ID, BRANCH_ID, AGENT_ID,
  k + 1                                                                          AS INSTALLMENT_NO,
  DUE_DATE,
  FEE_STATUS,
  IFF(FEE_STATUS = 'Payment Confirmed', DATEADD(day, DAYS_LATE, DUE_DATE), NULL)  AS COLLECTION_PAYMENT_DATE,
  INSTALLMENT_AMOUNT                                                             AS PREMIUM_DUE_AMOUNT,
  IFF(FEE_STATUS = 'Payment Confirmed', INSTALLMENT_AMOUNT, 0)::NUMBER(18,2)      AS PREMIUM_PAID_AMOUNT,
  IFF(FEE_STATUS = 'Payment Confirmed', DAYS_LATE, NULL)                          AS DAYS_LATE,
  IFF(FEE_STATUS = 'Payment Confirmed' AND DAYS_LATE > 5, TRUE, FALSE)            AS IS_LATE,
  PAYMENT_FREQUENCY,
  CASE WHEN RND(PK, 720) < 0.38 THEN 'Auto Debit'
       WHEN RND(PK, 720) < 0.62 THEN 'Credit Card'
       WHEN RND(PK, 720) < 0.80 THEN 'Bank Transfer'
       WHEN RND(PK, 720) < 0.92 THEN 'Virtual Account'
       ELSE 'e-Wallet' END                                                        AS PAYMENT_CHANNEL,
  DATE_TRUNC('month', DUE_DATE)                                                   AS DUE_MONTH,
  YEAR(DUE_DATE)                                                                  AS DUE_YEAR
FROM (
  SELECT b.*,
         CASE
           -- Even at the point of lapse the final instalment is not always
           -- "Failed": 25% of lapsers pay it and still lapse at renewal.
           -- This decouples the unpaid flag from the label.
           WHEN b.IS_LAPSING AND b.MONTHS_TO_END <= 1
                THEN CASE WHEN RND(b.PK, 711) < 0.55 THEN 'Failed'
                          WHEN RND(b.PK, 711) < 0.75 THEN 'Pending'
                          ELSE 'Payment Confirmed' END
           WHEN b.u_status < 0.945 THEN 'Payment Confirmed'
           WHEN b.u_status < 0.972 THEN 'Pending'
           ELSE 'Failed'
         END AS FEE_STATUS
  FROM behaved b
);

/* =====================================================================
   FACT_POLICY_RIDER
   ===================================================================== */
CREATE OR REPLACE TABLE FACT_POLICY_RIDER AS
WITH p AS (
  SELECT f.POLICY_ID, f.CUSTOMER_ID, f.BRANCH_ID, f.ISSUE_DATE, f.POLICY_STATUS,
         f.ANNUAL_PREMIUM, f.SUM_ASSURED, d.CLASSIFICATION,
         CASE WHEN RND(f.POLICY_ID, 750) < 0.18 THEN 0
              WHEN RND(f.POLICY_ID, 750) < 0.52 THEN 1
              WHEN RND(f.POLICY_ID, 750) < 0.82 THEN 2
              ELSE 3 END AS n_riders
  FROM FACT_POLICY f JOIN DIM_PRODUCT d ON d.PRODUCT_ID = f.PRODUCT_ID
),
ex AS (
  SELECT p.*, g.i,
         p.POLICY_ID || '-R' || g.i::VARCHAR AS PK
  FROM p JOIN (SELECT SEQ4() + 1 AS i FROM TABLE(GENERATOR(ROWCOUNT => 3))) g
    ON g.i <= p.n_riders
),
named AS (
  SELECT ex.*,
         ARRAY_CONSTRUCT('Waiver of Premium','Accidental Death Benefit','Critical Illness Rider',
                         'Hospital Cash Benefit','Total Permanent Disability','Payor Benefit',
                         'Health Booster','Term Life Rider')[RNDI(PK, 751, 0, 7)]::VARCHAR AS RIDER_TYPE
  FROM ex
)
SELECT
  'RID' || LPAD(ROW_NUMBER() OVER (ORDER BY POLICY_ID, i)::VARCHAR, 7, '0')       AS RIDER_ID,
  POLICY_ID, CUSTOMER_ID, BRANCH_ID,
  i                                                                              AS RIDER_SEQ,
  'Meridian ' || RIDER_TYPE                                                      AS RIDER_NAME,
  RIDER_TYPE,
  CASE WHEN RIDER_TYPE IN ('Critical Illness Rider','Total Permanent Disability') THEN 'Living Benefit'
       WHEN RIDER_TYPE IN ('Waiver of Premium','Payor Benefit')                   THEN 'Premium Protection'
       WHEN RIDER_TYPE IN ('Hospital Cash Benefit','Health Booster')              THEN 'Health'
       ELSE 'Life Protection' END                                                AS RIDER_CATEGORY,
  ROUND(ANNUAL_PREMIUM * (0.05 + 0.20 * RND(PK, 752)), -3)::NUMBER(18,2)          AS RIDER_PREMIUM,
  ROUND(SUM_ASSURED   * (0.10 + 0.40 * RND(PK, 753)), -6)::NUMBER(20,2)           AS RIDER_SUM_ASSURED,
  DATEADD(day, IFF(RND(PK,754) < 0.82, 0, RNDI(PK, 755, 30, 400)), ISSUE_DATE)    AS ATTACH_DATE,
  CASE WHEN POLICY_STATUS = 'Lapsed'     THEN 'Lapsed'
       WHEN POLICY_STATUS = 'Terminated' THEN 'Terminated'
       WHEN RND(PK, 756) < 0.04          THEN 'Cancelled'
       ELSE 'Inforce' END                                                         AS RIDER_STATUS
FROM named;

/* =====================================================================
   FACT_CLAIMS
   Death claims are reconciled with FACT_POLICY.TERMINATION_REASON so the
   two facts never contradict each other.
   ===================================================================== */
CREATE OR REPLACE TABLE FACT_CLAIMS AS
WITH p AS (
  SELECT f.POLICY_ID, f.CUSTOMER_ID, f.BRANCH_ID, f.AGENT_ID, f.PRODUCT_ID,
         f.ISSUE_DATE, f.POLICY_STATUS, f.TERMINATION_REASON, f.TERMINATION_DATE,
         f.SUM_ASSURED, f.ANNUAL_PREMIUM, d.CLASSIFICATION,
         LEAST('2025-12-31'::DATE,
               COALESCE(f.LAPSE_DATE, f.TERMINATION_DATE, '2025-12-31'::DATE)) AS END_DATE
  FROM FACT_POLICY f JOIN DIM_PRODUCT d ON d.PRODUCT_ID = f.PRODUCT_ID
),
rate AS (
  SELECT p.*,
         CASE CLASSIFICATION
           WHEN 'Health'           THEN 0.50
           WHEN 'Critical Illness' THEN 0.22
           WHEN 'Accident'         THEN 0.20
           WHEN 'Life'             THEN 0.058
           WHEN 'Unit Link'        THEN 0.042
           WHEN 'Education'        THEN 0.033
           WHEN 'Retirement'       THEN 0.033
           ELSE 0.025 END AS claim_rate
  FROM p
),
cnt AS (
  SELECT r.*,
         CASE
           WHEN r.TERMINATION_REASON = 'Death Claim' THEN 1
           WHEN RND(r.POLICY_ID, 800) >= r.claim_rate THEN 0
           WHEN r.CLASSIFICATION = 'Health' THEN 1 + RNDI(r.POLICY_ID, 801, 0, 2)
           ELSE 1
         END AS n_claims
  FROM rate r
  WHERE DATEDIFF(day, ISSUE_DATE, END_DATE) > 40      -- claims need an exposure window
),
ex AS (
  SELECT c.*, g.i, c.POLICY_ID || '-CL' || g.i::VARCHAR AS PK
  FROM cnt c JOIN (SELECT SEQ4() + 1 AS i FROM TABLE(GENERATOR(ROWCOUNT => 3))) g
    ON g.i <= c.n_claims
),
typed AS (
  SELECT ex.*,
         CASE
           WHEN TERMINATION_REASON = 'Death Claim' AND i = 1 THEN 'Death'
           WHEN CLASSIFICATION = 'Health'
             THEN ARRAY_CONSTRUCT('Inpatient','Outpatient','Surgery','Inpatient','Maternity')[RNDI(PK,810,0,4)]::VARCHAR
           WHEN CLASSIFICATION = 'Critical Illness' THEN 'Critical Illness'
           WHEN CLASSIFICATION = 'Accident'
             THEN ARRAY_CONSTRUCT('Accident','Accident','Disability')[RNDI(PK,811,0,2)]::VARCHAR
           ELSE ARRAY_CONSTRUCT('Inpatient','Surgery','Disability','Accident')[RNDI(PK,812,0,3)]::VARCHAR
         END AS CLAIM_TYPE,
         IFF(TERMINATION_REASON = 'Death Claim' AND i = 1,
             TERMINATION_DATE,
             DATEADD(day, 30 + RNDI(PK, 813, 0, GREATEST(1, DATEDIFF(day, ISSUE_DATE, END_DATE) - 35)), ISSUE_DATE)
            ) AS CLAIM_DATE
  FROM ex
),
sev AS (
  SELECT t.*,
         CASE CLAIM_TYPE
           WHEN 'Death'            THEN 1.00
           WHEN 'Critical Illness' THEN 0.098 + 0.230 * RND(PK, 820)
           WHEN 'Disability'       THEN 0.205 + 0.369 * RND(PK, 820)
           WHEN 'Surgery'          THEN 0.0082 + 0.0369 * RND(PK, 820)
           WHEN 'Inpatient'        THEN 0.0033 + 0.0180 * RND(PK, 820)
           WHEN 'Accident'         THEN 0.0164 + 0.0738 * RND(PK, 820)
           WHEN 'Maternity'        THEN 0.0049 + 0.0131 * RND(PK, 820)
           ELSE 0.0016 + 0.0082 * RND(PK, 820)
         END AS severity
  FROM typed t
),
decided AS (
  SELECT s.*,
         ROUND(GREATEST(500000, s.SUM_ASSURED * s.severity), -5)::NUMBER(18,2) AS CLAIM_AMOUNT,
         IFF(s.CLAIM_TYPE = 'Death', 'Approved',
             IFF(RND(s.PK, 830) < 0.78, 'Approved', 'Rejected'))               AS CLAIM_DECISION
  FROM sev s
)
SELECT
  'CLM' || LPAD(ROW_NUMBER() OVER (ORDER BY POLICY_ID, i)::VARCHAR, 7, '0')       AS CLAIM_ID,
  POLICY_ID, CUSTOMER_ID, POLICY_ID AS POLICY_REF, BRANCH_ID, AGENT_ID, PRODUCT_ID,
  CLAIM_DATE,
  CLAIM_TYPE,
  CASE WHEN CLAIM_TYPE IN ('Inpatient','Outpatient','Surgery','Maternity') THEN 'Health Benefit'
       WHEN CLAIM_TYPE IN ('Critical Illness','Disability')                THEN 'Living Benefit'
       WHEN CLAIM_TYPE = 'Death'                                          THEN 'Death Benefit'
       ELSE 'Accident Benefit' END                                                AS CLAIM_CATEGORY,
  CLAIM_AMOUNT,
  CLAIM_DECISION,
  IFF(CLAIM_DECISION = 'Approved',
      ROUND(CLAIM_AMOUNT * (0.72 + 0.28 * RND(PK, 831)), -3), 0)::NUMBER(18,2)    AS APPROVED_AMOUNT,
  DATEADD(day, RNDI(PK, 840, 5, 45), CLAIM_DATE)                                  AS DECISION_DATE,
  CASE WHEN RND(PK, 841) < 0.88 THEN 'Settled'
       WHEN RND(PK, 841) < 0.96 THEN 'In Review'
       ELSE 'Pending Document' END                                                AS CLAIM_STATUS,
  IFF(CLAIM_DECISION = 'Rejected',
      ARRAY_CONSTRUCT('Waiting period not met','Pre-existing condition','Policy exclusion applied',
                      'Incomplete documentation','Non-disclosure at underwriting')[RNDI(PK,842,0,4)]::VARCHAR,
      NULL)                                                                       AS REJECTION_REASON,
  RNDI(PK, 843, 3, 40)                                                            AS PROCESSING_DAYS,
  DATE_TRUNC('month', CLAIM_DATE)                                                 AS CLAIM_MONTH,
  YEAR(CLAIM_DATE)                                                                AS CLAIM_YEAR
FROM decided
WHERE CLAIM_DATE <= '2025-12-31'::DATE;

/* ---------------------------------------------------------------------
   Verification
   --------------------------------------------------------------------- */
SELECT 'FACT_POLICY_PAYMENT' t, COUNT(*) n FROM FACT_POLICY_PAYMENT
UNION ALL SELECT 'FACT_POLICY_RIDER', COUNT(*) FROM FACT_POLICY_RIDER
UNION ALL SELECT 'FACT_CLAIMS',       COUNT(*) FROM FACT_CLAIMS;

SELECT FEE_STATUS, COUNT(*) n, ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),2) pct,
       ROUND(AVG(DAYS_LATE),1) avg_days_late
FROM FACT_POLICY_PAYMENT GROUP BY 1 ORDER BY n DESC;

SELECT CLAIM_DECISION, COUNT(*) n, ROUND(SUM(APPROVED_AMOUNT)/1e9,2) approved_rp_bn
FROM FACT_CLAIMS GROUP BY 1;

-- Loss ratio sanity check (should land in a plausible 30-60% band)
SELECT ROUND(100.0 * (SELECT SUM(APPROVED_AMOUNT) FROM FACT_CLAIMS)
                   / (SELECT SUM(PREMIUM_PAID_AMOUNT) FROM FACT_POLICY_PAYMENT), 2) AS loss_ratio_pct;
