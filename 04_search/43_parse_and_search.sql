/* =====================================================================
   MERIDIAN LIFE — 43_parse_and_search.sql
   Step 3c: AI_PARSE_DOCUMENT -> DOCS_PARSED -> DOCS_CHUNKS
            -> CORTEX SEARCH SERVICE MERIDIAN_PRODUCT_SEARCH

   Citation design: the search service exposes PRODUCT_NAME as an attribute
   so the agent can cite "Meridian Sehat Gold" rather than a file name.
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

ALTER STAGE STAGE_DOC REFRESH;

SELECT COUNT(*) AS pdf_files_on_stage FROM DIRECTORY(@STAGE_DOC);

/* ---- 1. Parse the PDFs (LAYOUT mode preserves tables and headings) --- */
CREATE OR REPLACE TABLE DOCS_PARSED AS
SELECT
    d.RELATIVE_PATH,
    d.SIZE                                             AS FILE_SIZE_BYTES,
    d.LAST_MODIFIED,
    -- filenames end with _P0nn.pdf, which links back to DIM_PRODUCT
    REGEXP_SUBSTR(d.RELATIVE_PATH, 'P[0-9]{3}')        AS PRODUCT_ID,
    AI_PARSE_DOCUMENT(
        TO_FILE('@STAGE_DOC', d.RELATIVE_PATH),
        {'mode': 'LAYOUT'}
    )                                                  AS PARSED_RAW
FROM DIRECTORY(@STAGE_DOC) d
WHERE LOWER(d.RELATIVE_PATH) LIKE '%.pdf';

-- Flatten the parser output and attach product metadata
CREATE OR REPLACE TABLE DOCS_PARSED_TEXT AS
SELECT
    p.RELATIVE_PATH,
    p.PRODUCT_ID,
    p.FILE_SIZE_BYTES,
    d.PRODUCT_NAME,
    d.PRODUCT_CODE,
    d.CLASSIFICATION,
    d.PRODUCT_TYPE,
    d.TIER_LABEL,
    d.MIN_ANNUAL_PREMIUM,
    p.PARSED_RAW:content::STRING                       AS PARSED_TEXT,
    LENGTH(p.PARSED_RAW:content::STRING)               AS PARSED_CHARS
FROM DOCS_PARSED p
LEFT JOIN DIM_PRODUCT d ON d.PRODUCT_ID = p.PRODUCT_ID;

/* ---- 2. Chunk for retrieval ----------------------------------------- */
CREATE OR REPLACE TABLE DOCS_CHUNKS AS
SELECT
    t.RELATIVE_PATH,
    t.PRODUCT_ID,
    t.PRODUCT_NAME,
    t.PRODUCT_CODE,
    t.CLASSIFICATION,
    t.PRODUCT_TYPE,
    t.TIER_LABEL,
    t.MIN_ANNUAL_PREMIUM,
    c.INDEX                                            AS CHUNK_INDEX,
    -- prefix each chunk with the product name so a retrieved fragment is
    -- self-describing even when the heading fell into a neighbouring chunk
    'Product: ' || t.PRODUCT_NAME || ' (' || t.PRODUCT_CODE || ', '
                || t.CLASSIFICATION || ')' || CHAR(10) || CHAR(10)
                || c.VALUE::STRING                     AS CHUNK_TEXT,
    LENGTH(c.VALUE::STRING)                            AS CHUNK_CHARS
FROM DOCS_PARSED_TEXT t,
     LATERAL FLATTEN(
        input => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
                    t.PARSED_TEXT, 'markdown', 1500, 200)
     ) c
WHERE t.PARSED_TEXT IS NOT NULL;

/* ---- 3. Cortex Search service --------------------------------------- */
CREATE OR REPLACE CORTEX SEARCH SERVICE MERIDIAN_PRODUCT_SEARCH
    ON CHUNK_TEXT
    ATTRIBUTES PRODUCT_NAME, PRODUCT_CODE, CLASSIFICATION, PRODUCT_TYPE,
               TIER_LABEL, RELATIVE_PATH
    WAREHOUSE = GEN2_SMALL
    TARGET_LAG = '1 hour'
    EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0'
    COMMENT = 'RAG over the 24 fictional Meridian Life product brochures.'
    AS
    SELECT CHUNK_TEXT, PRODUCT_NAME, PRODUCT_CODE, CLASSIFICATION,
           PRODUCT_TYPE, TIER_LABEL, RELATIVE_PATH, PRODUCT_ID, CHUNK_INDEX
    FROM DOCS_CHUNKS;

/* ---- Verification --------------------------------------------------- */
SELECT COUNT(*) AS parsed_docs,
       COUNT_IF(PARSED_TEXT IS NULL) AS parse_failures,
       COUNT_IF(PRODUCT_NAME IS NULL) AS unmatched_products,
       ROUND(AVG(PARSED_CHARS)) AS avg_parsed_chars
FROM DOCS_PARSED_TEXT;

SELECT COUNT(*) AS chunks,
       COUNT(DISTINCT PRODUCT_ID) AS products,
       ROUND(AVG(CHUNK_CHARS)) AS avg_chunk_chars,
       MIN(CHUNK_CHARS) AS min_chunk, MAX(CHUNK_CHARS) AS max_chunk,
       ROUND(COUNT(*) * 1.0 / COUNT(DISTINCT PRODUCT_ID), 1) AS chunks_per_doc
FROM DOCS_CHUNKS;

SHOW CORTEX SEARCH SERVICES LIKE 'MERIDIAN_PRODUCT_SEARCH';
