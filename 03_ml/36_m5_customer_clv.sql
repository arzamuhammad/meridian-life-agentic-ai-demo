/* =====================================================================
   MERIDIAN LIFE — 36_m5_customer_clv.sql
   M5: actuarial Customer Lifetime Value (discounted cash flow).

       CLV = SUM over t=1..15 of  premium * retention^t / (1+r)^t
             r = 8% discount rate, horizon 15 years

   The geometric series is evaluated in closed form:
       let q = retention / (1 + r)
       SUM q^t (t=1..15) = q * (1 - q^15) / (1 - q)

   retention comes from M1: 1 - AVG(LAPSE_PROBABILITY) over the customer's
   in-force policies, clamped to [0.50, 0.99]. The M1 probability is a
   90-day figure, so it is first annualised:
       annual_lapse = 1 - (1 - p90)^4
   Customers with no scored policy fall back to the portfolio mean.
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

CREATE OR REPLACE TABLE CUSTOMER_CLV_SCORES AS
WITH params AS (
    SELECT 0.08::FLOAT AS DISCOUNT_RATE, 15 AS HORIZON_YEARS, '2025-12-31'::DATE AS REF_DATE
),
/* ---- in-force premium base per customer ---------------------------- */
prem AS (
    SELECT p.CUSTOMER_ID,
           SUM(IFF(p.POLICY_STATUS = 'Inforce', p.ANNUAL_PREMIUM, 0))  AS INFORCE_ANNUAL_PREMIUM,
           SUM(p.ANNUAL_PREMIUM)                                       AS TOTAL_ANNUAL_PREMIUM,
           COUNT(*)                                                    AS POLICY_COUNT,
           COUNT_IF(p.POLICY_STATUS = 'Inforce')                       AS INFORCE_POLICY_COUNT,
           COUNT_IF(p.POLICY_STATUS = 'Lapsed')                        AS LAPSED_POLICY_COUNT,
           MIN(p.ISSUE_DATE)                                           AS FIRST_ISSUE_DATE,
           MAX(p.ISSUE_DATE)                                           AS LAST_ISSUE_DATE,
           SUM(p.SUM_ASSURED)                                          AS TOTAL_SUM_ASSURED
    FROM FACT_POLICY p
    GROUP BY 1
),
/* ---- premium actually collected so far ----------------------------- */
paid AS (
    SELECT y.CUSTOMER_ID, SUM(y.PREMIUM_PAID_AMOUNT) AS PREMIUM_COLLECTED_TO_DATE
    FROM FACT_POLICY_PAYMENT y
    GROUP BY 1
),
/* ---- claims paid out (net value consideration) --------------------- */
clm AS (
    SELECT c.CUSTOMER_ID, SUM(c.APPROVED_AMOUNT) AS CLAIMS_PAID_TO_DATE
    FROM FACT_CLAIMS c
    GROUP BY 1
),
/* ---- retention from M1 --------------------------------------------- */
risk AS (
    SELECT CUSTOMER_ID, AVG(LAPSE_PROBABILITY) AS AVG_P90
    FROM LAPSE_RISK_SCORES
    GROUP BY 1
),
portfolio AS (SELECT AVG(LAPSE_PROBABILITY) AS MEAN_P90 FROM LAPSE_RISK_SCORES),
base AS (
    SELECT
        c.CUSTOMER_ID, c.CUSTOMER_NAME, c.AGE, c.AGE_BAND, c.GENDER,
        c.CITY, c.PROVINCE, c.REGION, c.OCCUPATION, c.INCOME_BAND, c.MARITAL_STATUS,
        pr.POLICY_COUNT, pr.INFORCE_POLICY_COUNT, pr.LAPSED_POLICY_COUNT,
        pr.INFORCE_ANNUAL_PREMIUM, pr.TOTAL_ANNUAL_PREMIUM, pr.TOTAL_SUM_ASSURED,
        pr.FIRST_ISSUE_DATE, pr.LAST_ISSUE_DATE,
        COALESCE(pd.PREMIUM_COLLECTED_TO_DATE, 0) AS PREMIUM_COLLECTED_TO_DATE,
        COALESCE(cl.CLAIMS_PAID_TO_DATE, 0)       AS CLAIMS_PAID_TO_DATE,
        DATEDIFF(month, pr.FIRST_ISSUE_DATE, (SELECT REF_DATE FROM params)) AS TENURE_MONTHS,
        COALESCE(rk.AVG_P90, (SELECT MEAN_P90 FROM portfolio))            AS AVG_P90
    FROM DIM_CUSTOMER c
    JOIN prem pr ON pr.CUSTOMER_ID = c.CUSTOMER_ID   -- only customers who own a policy
    LEFT JOIN paid pd ON pd.CUSTOMER_ID = c.CUSTOMER_ID
    LEFT JOIN clm  cl ON cl.CUSTOMER_ID = c.CUSTOMER_ID
    LEFT JOIN risk rk ON rk.CUSTOMER_ID = c.CUSTOMER_ID
),
calc AS (
    SELECT b.*,
           p.DISCOUNT_RATE, p.HORIZON_YEARS,
           -- 90-day probability -> annual, then retention, then clamp
           LEAST(0.99, GREATEST(0.50,
                 1.0 - (1.0 - POWER(1.0 - b.AVG_P90, 4)))) AS RETENTION_RATE
    FROM base b CROSS JOIN params p
),
dcf AS (
    SELECT c.*,
           (c.RETENTION_RATE / (1 + c.DISCOUNT_RATE)) AS q,
           -- multi-policy and long-tenure customers are structurally stickier
           (1.0 + 0.05 * GREATEST(0, c.POLICY_COUNT - 1)
                + 0.02 * LEAST(5, FLOOR(c.TENURE_MONTHS / 12.0))) AS LOYALTY_UPLIFT
    FROM calc c
),
valued AS (
    SELECT d.*,
           -- closed-form geometric sum of the 15 discounted retained years
           (d.q * (1 - POWER(d.q, d.HORIZON_YEARS)) / NULLIF(1 - d.q, 0)) AS ANNUITY_FACTOR,
           ROUND(
             GREATEST(d.INFORCE_ANNUAL_PREMIUM, 0)
             * (d.q * (1 - POWER(d.q, d.HORIZON_YEARS)) / NULLIF(1 - d.q, 0))
             * d.LOYALTY_UPLIFT
           , 2) AS CLV
    FROM dcf d
)
SELECT
    CUSTOMER_ID, CUSTOMER_NAME, AGE, AGE_BAND, GENDER,
    CITY, PROVINCE, REGION, OCCUPATION, INCOME_BAND, MARITAL_STATUS,
    POLICY_COUNT, INFORCE_POLICY_COUNT, LAPSED_POLICY_COUNT,
    INFORCE_ANNUAL_PREMIUM::NUMBER(20,2)        AS INFORCE_ANNUAL_PREMIUM,
    TOTAL_ANNUAL_PREMIUM::NUMBER(20,2)          AS TOTAL_ANNUAL_PREMIUM,
    TOTAL_SUM_ASSURED::NUMBER(20,2)             AS TOTAL_SUM_ASSURED,
    PREMIUM_COLLECTED_TO_DATE::NUMBER(20,2)     AS PREMIUM_COLLECTED_TO_DATE,
    CLAIMS_PAID_TO_DATE::NUMBER(20,2)           AS CLAIMS_PAID_TO_DATE,
    FIRST_ISSUE_DATE, LAST_ISSUE_DATE, TENURE_MONTHS,
    ROUND(AVG_P90, 6)                           AS AVG_LAPSE_PROB_90D,
    ROUND(RETENTION_RATE, 4)                    AS RETENTION_RATE,
    ROUND(LOYALTY_UPLIFT, 4)                    AS LOYALTY_UPLIFT,
    ROUND(ANNUITY_FACTOR, 4)                    AS ANNUITY_FACTOR,
    CLV::NUMBER(20,2)                           AS CLV,
    CASE NTILE(4) OVER (ORDER BY CLV DESC)
         WHEN 1 THEN 'PLATINUM' WHEN 2 THEN 'GOLD'
         WHEN 3 THEN 'SILVER'   ELSE 'BRONZE' END AS CLV_SEGMENT,
    NTILE(100) OVER (ORDER BY CLV DESC)         AS CLV_PERCENTILE,
    '2025-12-31'::DATE                          AS ASOF_DATE,
    'M5_actuarial_dcf_v1'                       AS MODEL_VERSION
FROM valued;

/* ---- Verification --------------------------------------------------- */
SELECT CLV_SEGMENT, COUNT(*) AS customers,
       'Rp ' || TO_VARCHAR(ROUND(MIN(CLV)/1e6,1), '999,990.0') || ' M' AS min_clv,
       'Rp ' || TO_VARCHAR(ROUND(AVG(CLV)/1e6,1), '999,990.0') || ' M' AS avg_clv,
       'Rp ' || TO_VARCHAR(ROUND(MAX(CLV)/1e6,1), '999,990.0') || ' M' AS max_clv,
       ROUND(AVG(RETENTION_RATE), 4) AS avg_retention,
       ROUND(AVG(POLICY_COUNT), 2)   AS avg_policies
FROM CUSTOMER_CLV_SCORES
GROUP BY 1
ORDER BY MIN(CLV) DESC;

SELECT COUNT(*) AS customers_scored,
       ROUND(SUM(CLV)/1e9, 2) AS total_clv_rp_bn,
       ROUND(MIN(RETENTION_RATE),4) AS min_retention,
       ROUND(MAX(RETENTION_RATE),4) AS max_retention
FROM CUSTOMER_CLV_SCORES;
