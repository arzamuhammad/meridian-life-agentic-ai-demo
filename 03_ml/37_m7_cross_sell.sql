/* =====================================================================
   MERIDIAN LIFE — 37_m7_cross_sell.sql
   M7: cross-sell recommender via association rules at CLASSIFICATION grain.

     support(A)     = customers holding A / all policy-holding customers
     confidence(A->B) = customers holding A and B / customers holding A
     lift(A->B)     = confidence(A->B) / support(B)

   Only classes the customer does NOT already hold are recommended, ranked
   by the best lift available from any class they DO hold. Top 3 per customer.
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

/* ---- customer x classification holdings ----------------------------- */
CREATE OR REPLACE TABLE CROSS_SELL_RULES AS
WITH holds AS (
    SELECT DISTINCT p.CUSTOMER_ID, d.CLASSIFICATION
    FROM FACT_POLICY p
    JOIN DIM_PRODUCT d ON d.PRODUCT_ID = p.PRODUCT_ID
),
total AS (SELECT COUNT(DISTINCT CUSTOMER_ID) AS N FROM holds),
sup AS (
    SELECT CLASSIFICATION, COUNT(*) AS HOLDERS,
           COUNT(*) / (SELECT N FROM total)::FLOAT AS SUPPORT
    FROM holds GROUP BY 1
),
pairs AS (
    SELECT a.CLASSIFICATION AS ANTECEDENT_CLASS,
           b.CLASSIFICATION AS CONSEQUENT_CLASS,
           COUNT(*) AS BOTH_HOLDERS
    FROM holds a
    JOIN holds b ON b.CUSTOMER_ID = a.CUSTOMER_ID
                AND b.CLASSIFICATION <> a.CLASSIFICATION
    GROUP BY 1,2
)
SELECT
    p.ANTECEDENT_CLASS,
    p.CONSEQUENT_CLASS,
    p.BOTH_HOLDERS,
    sa.HOLDERS                                                   AS ANTECEDENT_HOLDERS,
    sc.HOLDERS                                                   AS CONSEQUENT_HOLDERS,
    ROUND(p.BOTH_HOLDERS / (SELECT N FROM total)::FLOAT, 6)       AS PAIR_SUPPORT,
    ROUND(p.BOTH_HOLDERS / sa.HOLDERS::FLOAT, 6)                 AS CONFIDENCE,
    ROUND((p.BOTH_HOLDERS / sa.HOLDERS::FLOAT) / sc.SUPPORT, 6)  AS LIFT,
    ROUND(sc.SUPPORT, 6)                                         AS CONSEQUENT_SUPPORT
FROM pairs p
JOIN sup sa ON sa.CLASSIFICATION = p.ANTECEDENT_CLASS
JOIN sup sc ON sc.CLASSIFICATION = p.CONSEQUENT_CLASS
WHERE p.BOTH_HOLDERS >= 20;      -- minimum support so rules are not noise

/* ---- average premium per class (data-driven expected value) ---------- */
CREATE OR REPLACE VIEW V_CLASS_AVG_PREMIUM AS
SELECT d.CLASSIFICATION,
       ROUND(AVG(p.ANNUAL_PREMIUM), 2)::NUMBER(18,2) AS AVG_ANNUAL_PREMIUM,
       ROUND(MEDIAN(p.ANNUAL_PREMIUM), 2)::NUMBER(18,2) AS MEDIAN_ANNUAL_PREMIUM,
       COUNT(*) AS POLICIES
FROM FACT_POLICY p JOIN DIM_PRODUCT d ON d.PRODUCT_ID = p.PRODUCT_ID
GROUP BY 1;

/* ---- top-3 recommendation per customer ------------------------------ */
CREATE OR REPLACE TABLE CROSS_SELL_RECOMMENDATIONS AS
WITH holds AS (
    SELECT DISTINCT p.CUSTOMER_ID, d.CLASSIFICATION
    FROM FACT_POLICY p JOIN DIM_PRODUCT d ON d.PRODUCT_ID = p.PRODUCT_ID
),
classes AS (SELECT DISTINCT CLASSIFICATION FROM DIM_PRODUCT),
-- every (customer, class-not-held) candidate
cand AS (
    SELECT h.CUSTOMER_ID, c.CLASSIFICATION AS CANDIDATE_CLASS
    FROM (SELECT DISTINCT CUSTOMER_ID FROM holds) h
    CROSS JOIN classes c
    WHERE NOT EXISTS (
        SELECT 1 FROM holds x
        WHERE x.CUSTOMER_ID = h.CUSTOMER_ID AND x.CLASSIFICATION = c.CLASSIFICATION
    )
),
-- best rule reaching that candidate from something the customer holds.
-- LIFT >= 1 is mandatory: a rule with lift < 1 means the pairing is LESS
-- likely than the base rate, so recommending it would be worse than random.
-- Consequence: a customer may legitimately receive fewer than 3 (or zero)
-- recommendations rather than being padded with bad ones.
best AS (
    SELECT cd.CUSTOMER_ID, cd.CANDIDATE_CLASS,
           r.ANTECEDENT_CLASS, r.LIFT, r.CONFIDENCE, r.PAIR_SUPPORT, r.BOTH_HOLDERS
    FROM cand cd
    JOIN holds h            ON h.CUSTOMER_ID = cd.CUSTOMER_ID
    JOIN CROSS_SELL_RULES r ON r.ANTECEDENT_CLASS = h.CLASSIFICATION
                           AND r.CONSEQUENT_CLASS = cd.CANDIDATE_CLASS
    WHERE r.LIFT >= 1.0
    QUALIFY ROW_NUMBER() OVER (PARTITION BY cd.CUSTOMER_ID, cd.CANDIDATE_CLASS
                               ORDER BY r.LIFT DESC, r.CONFIDENCE DESC) = 1
),
ranked AS (
    SELECT b.*,
           ROW_NUMBER() OVER (PARTITION BY b.CUSTOMER_ID
                              ORDER BY b.LIFT DESC, b.CONFIDENCE DESC, b.CANDIDATE_CLASS) AS REC_RANK
    FROM best b
)
SELECT
    r.CUSTOMER_ID,
    cl.CUSTOMER_NAME,
    cl.PROVINCE,
    r.REC_RANK,
    r.CANDIDATE_CLASS                              AS RECOMMENDED_CLASS,
    r.ANTECEDENT_CLASS                             AS BASED_ON_CLASS,
    r.LIFT                                         AS BEST_LIFT,
    r.CONFIDENCE                                   AS BEST_CONFIDENCE,
    r.PAIR_SUPPORT                                 AS RULE_SUPPORT,
    r.BOTH_HOLDERS                                 AS RULE_EVIDENCE_CUSTOMERS,
    ap.AVG_ANNUAL_PREMIUM                          AS EXPECTED_ANNUAL_PREMIUM,
    clv.CLV_SEGMENT,
    clv.CLV,
    clv.POLICY_COUNT                               AS CURRENT_POLICY_COUNT,
    -- a single-product PLATINUM/GOLD customer is the sweetest cross-sell
    IFF(clv.POLICY_COUNT = 1 AND clv.CLV_SEGMENT IN ('PLATINUM','GOLD'), TRUE, FALSE)
                                                   AS IS_PRIORITY_TARGET,
    p.AGENT_ID                                     AS SERVICING_AGENT_ID,
    p.BRANCH_ID                                    AS SERVICING_BRANCH_ID,
    '2025-12-31'::DATE                             AS ASOF_DATE,
    'M7_assoc_rules_v1'                            AS MODEL_VERSION
FROM ranked r
JOIN DIM_CUSTOMER cl        ON cl.CUSTOMER_ID = r.CUSTOMER_ID
LEFT JOIN CUSTOMER_CLV_SCORES clv ON clv.CUSTOMER_ID = r.CUSTOMER_ID
LEFT JOIN V_CLASS_AVG_PREMIUM ap  ON ap.CLASSIFICATION = r.CANDIDATE_CLASS
-- the agent/branch that wrote the customer's most recent policy owns the lead
LEFT JOIN (
    SELECT CUSTOMER_ID, AGENT_ID, BRANCH_ID
    FROM FACT_POLICY
    QUALIFY ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY ISSUE_DATE DESC) = 1
) p ON p.CUSTOMER_ID = r.CUSTOMER_ID
WHERE r.REC_RANK <= 3;

/* ---- Verification --------------------------------------------------- */
SELECT COUNT(*) AS recommendations,
       COUNT(DISTINCT CUSTOMER_ID) AS customers,
       ROUND(MIN(BEST_LIFT),3) AS min_lift,
       ROUND(AVG(BEST_LIFT),3) AS avg_lift,
       ROUND(MAX(BEST_LIFT),3) AS max_lift,
       COUNT_IF(IS_PRIORITY_TARGET) AS priority_targets
FROM CROSS_SELL_RECOMMENDATIONS;

SELECT ANTECEDENT_CLASS, CONSEQUENT_CLASS, BOTH_HOLDERS,
       CONFIDENCE, LIFT
FROM CROSS_SELL_RULES ORDER BY LIFT DESC LIMIT 8;

SELECT RECOMMENDED_CLASS, COUNT(*) AS recs, ROUND(AVG(BEST_LIFT),3) AS avg_lift,
       'Rp ' || TO_VARCHAR(MAX(EXPECTED_ANNUAL_PREMIUM), '999,999,999') AS expected_premium
FROM CROSS_SELL_RECOMMENDATIONS GROUP BY 1 ORDER BY recs DESC;
