/* =====================================================================
   MERIDIAN LIFE — 41_generate_brochures.sql
   Step 3a: generate 24 FICTIONAL product brochures with AI_COMPLETE.

   The prompt is fed the product's REAL structured attributes (name, class,
   type, minimum premium, term) so the brochure text stays consistent with
   DIM_PRODUCT. That consistency is what lets the agent cross-reference
   Cortex Search answers against Cortex Analyst numbers.

   Everything is fictional: "Meridian Life" does not exist, the figures are
   illustrative, and no real policy wording is reproduced.
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

/* ---- pick 3 products per classification (one per tier) = 24 --------- */
CREATE OR REPLACE TABLE DOC_PRODUCT_PICK AS
SELECT PRODUCT_ID, PRODUCT_CODE, PRODUCT_NAME, CLASSIFICATION, PRODUCT_TYPE,
       PRODUCT_TIER, TIER_LABEL, MIN_ANNUAL_PREMIUM, DEFAULT_TERM_YEARS,
       DISTRIBUTION_CHANNEL
FROM DIM_PRODUCT
QUALIFY ROW_NUMBER() OVER (PARTITION BY CLASSIFICATION, PRODUCT_TIER
                           ORDER BY PRODUCT_ID) = 1;

SELECT COUNT(*) AS brochures_to_generate FROM DOC_PRODUCT_PICK;

/* ---- generate the brochure body ------------------------------------- */
CREATE OR REPLACE TABLE PRODUCT_BROCHURE_TEXT AS
SELECT
    p.PRODUCT_ID,
    p.PRODUCT_CODE,
    p.PRODUCT_NAME,
    p.CLASSIFICATION,
    p.PRODUCT_TYPE,
    p.TIER_LABEL,
    p.MIN_ANNUAL_PREMIUM,
    p.DEFAULT_TERM_YEARS,
    -- AI_COMPLETE returns VARIANT. Without ::STRING the value stays a JSON
    -- string, so downstream readers get literal \n and wrapping quotes
    -- instead of real newlines (which breaks Markdown -> PDF rendering).
    AI_COMPLETE(
      'claude-4-sonnet',
      'You are a product marketing writer for a FICTIONAL Indonesian life insurance '
      || 'company called "Meridian Life". Write a complete product brochure in ENGLISH '
      || 'using Markdown. All amounts must be in Indonesian Rupiah written as "Rp 12.500.000". '
      || 'This is entirely fictional content for a software demo - do not reference any real '
      || 'insurer, real regulation article numbers, or real policy wording.\n\n'
      || 'PRODUCT FACTS (use these exactly, do not contradict them):\n'
      || '- Product name: ' || p.PRODUCT_NAME || '\n'
      || '- Product code: ' || p.PRODUCT_CODE || '\n'
      || '- Category: ' || p.CLASSIFICATION || '\n'
      || '- Contract type: ' || p.PRODUCT_TYPE || '\n'
      || '- Tier: ' || p.TIER_LABEL || '\n'
      || '- Minimum annual premium: Rp ' || TO_VARCHAR(p.MIN_ANNUAL_PREMIUM, '999,999,999') || '\n'
      || '- Standard policy term: ' || p.DEFAULT_TERM_YEARS || ' years\n'
      || '- Distribution: ' || p.DISTRIBUTION_CHANNEL || '\n\n'
      || 'Write these sections as level-2 Markdown headings, in this order:\n'
      || '1. Product Overview (2 paragraphs, who it is for)\n'
      || '2. Key Benefits (5-7 bullets, each with a concrete Rupiah figure or percentage)\n'
      || '3. Coverage Details (a Markdown table of benefit vs sum assured vs waiting period)\n'
      || '4. Premium Illustration (a Markdown table: age band 25-30, 31-40, 41-50, 51-60 '
      || 'against annual premium in Rupiah, starting from the minimum premium above)\n'
      || '5. Eligibility Requirements (entry age, medical underwriting, occupation classes)\n'
      || '6. Exclusions (6-8 bullets - suicide within 2 years, self-inflicted injury, '
      || 'war and terrorism, undisclosed pre-existing conditions, hazardous sports, illegal acts)\n'
      || '7. Waiting Periods and Grace Period (state a 30-day grace period and that the policy '
      || 'lapses if premium is unpaid after the grace period, with a 2-year reinstatement window)\n'
      || '8. Optional Riders (3-4 riders with indicative rider premium as a percentage of base premium)\n'
      || '9. Claim Process (numbered steps and required documents)\n'
      || '10. Important Notes (disclaimer that this is an illustration and not a contract)\n\n'
      || 'Target 900-1200 words. Do not add any preamble before the first heading.'
    )::STRING AS BROCHURE_MD
FROM DOC_PRODUCT_PICK p;

/* ---- Verification --------------------------------------------------- */
SELECT COUNT(*)                                      AS brochures,
       ROUND(AVG(LENGTH(BROCHURE_MD)))               AS avg_chars,
       MIN(LENGTH(BROCHURE_MD))                      AS min_chars,
       MAX(LENGTH(BROCHURE_MD))                      AS max_chars,
       COUNT_IF(BROCHURE_MD IS NULL)                 AS failed
FROM PRODUCT_BROCHURE_TEXT;

SELECT PRODUCT_ID, PRODUCT_NAME, CLASSIFICATION, TIER_LABEL,
       LENGTH(BROCHURE_MD) AS chars,
       LEFT(BROCHURE_MD, 160) AS preview
FROM PRODUCT_BROCHURE_TEXT ORDER BY PRODUCT_ID LIMIT 5;
