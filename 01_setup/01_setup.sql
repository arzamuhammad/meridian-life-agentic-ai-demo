/* =====================================================================
   MERIDIAN LIFE — Insurance Sales Agentic AI Demo
   01_setup.sql — Database, schema, stages, session context
   ---------------------------------------------------------------------
   Target  : INSURANCE_DEMO.CORE
   WH      : GEN2_SMALL (created below if it does not exist)
   NOTE    : 100% synthetic data. No real PII.

   Runs on ANY Snowflake account with Cortex AI enabled. If you prefer a
   different warehouse name, find-and-replace GEN2_SMALL across the repo.
   ===================================================================== */

USE ROLE ACCOUNTADMIN;

-- Warehouse -----------------------------------------------------------------
-- Created here so the whole build works on a fresh account. X-Small is enough
-- for every step; auto-suspend keeps the cost near zero when idle.
CREATE WAREHOUSE IF NOT EXISTS GEN2_SMALL
    WAREHOUSE_SIZE      = 'XSMALL'
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = FALSE
    COMMENT = 'Meridian Life demo build and query warehouse.';

USE WAREHOUSE GEN2_SMALL;

CREATE DATABASE IF NOT EXISTS INSURANCE_DEMO
    COMMENT = 'Meridian Life (fictional) — Insurance Sales Agentic AI demo. All data synthetic.';

CREATE SCHEMA IF NOT EXISTS INSURANCE_DEMO.CORE
    COMMENT = 'Core star schema, ML outputs, semantic view, agent artefacts.';

USE SCHEMA INSURANCE_DEMO.CORE;

-- Stages ---------------------------------------------------------------
CREATE STAGE IF NOT EXISTS STAGE_DOC
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    COMMENT = 'Fictional Meridian Life product brochures (PDF) for Cortex Search.';

CREATE STAGE IF NOT EXISTS STAGE_STREAMLIT_APP
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    COMMENT = 'Streamlit-in-Snowflake Command Center source files.';

CREATE STAGE IF NOT EXISTS STAGE_EXPORT
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    COMMENT = 'Generated PPTX / export artefacts served via presigned URL.';

-- Sanity checks --------------------------------------------------------
SELECT CURRENT_ORGANIZATION_NAME() AS org,
       CURRENT_ACCOUNT_NAME()      AS account,
       CURRENT_DATABASE()          AS db,
       CURRENT_SCHEMA()            AS sch,
       CURRENT_WAREHOUSE()         AS wh,
       CURRENT_REGION()            AS region;

SHOW STAGES IN SCHEMA INSURANCE_DEMO.CORE;
