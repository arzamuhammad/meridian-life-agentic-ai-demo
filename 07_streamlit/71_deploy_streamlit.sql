/* =====================================================================
   MERIDIAN LIFE — 71_deploy_streamlit.sql
   Deploy the Command Center dashboard to Snowflake.
   ---------------------------------------------------------------------
   Run this file statement by statement from a Snowsight Workspace
   (put the cursor in a statement, press Cmd/Ctrl+Enter).

   No local tooling required: the app files already live inside Snowflake
   because Module 0 cloned this repo into your Workspace. COPY FILES moves
   them from the Workspace into a stage, which is what CREATE STREAMLIT
   reads from.
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

/* ---------------------------------------------------------------------
   STEP 1 — Confirm Snowflake can see your Workspace, and check its name.

   Look for the row whose NAME matches the repository you cloned:
       meridian-life-agentic-ai-demo

   If yours differs (for example you renamed it while creating it), use
   YOUR exact name in step 2. The name is CASE-SENSITIVE and must stay
   inside double quotes.
   --------------------------------------------------------------------- */
SHOW TERSE WORKSPACES IN SCHEMA USER$.PUBLIC;

/* ---------------------------------------------------------------------
   STEP 2 — Copy the app files from your Workspace into the stage.

   Anatomy of the source path:
     USER$                              your personal database; Snowflake
                                        resolves it, so you never type your
                                        username
     "meridian-life-agentic-ai-demo"    the Workspace name. Double quotes are
                                        REQUIRED because it contains lower-case
                                        letters and hyphens; without them
                                        Snowflake upper-cases it and the name
                                        will not match
     /versions/live/...                 the files as they are right now
   --------------------------------------------------------------------- */
REMOVE @STAGE_STREAMLIT_APP;

COPY FILES
    INTO @STAGE_STREAMLIT_APP/app/
    FROM 'snow://workspace/USER$.PUBLIC."meridian-life-agentic-ai-demo"/versions/live/07_streamlit/streamlit_app/'
    FILES = ('app.py', 'environment.yml');

-- The Streamlit theme lives in a sub-folder, so it needs its own statement.
COPY FILES
    INTO @STAGE_STREAMLIT_APP/app/.streamlit/
    FROM 'snow://workspace/USER$.PUBLIC."meridian-life-agentic-ai-demo"/versions/live/07_streamlit/streamlit_app/.streamlit/'
    FILES = ('config.toml');

/* ---------------------------------------------------------------------
   STEP 3 — Verify. You should see exactly 3 files:
       app/app.py
       app/environment.yml
       app/.streamlit/config.toml
   --------------------------------------------------------------------- */
ALTER STAGE STAGE_STREAMLIT_APP REFRESH;

SELECT RELATIVE_PATH, SIZE
FROM DIRECTORY(@STAGE_STREAMLIT_APP)
ORDER BY RELATIVE_PATH;

/* ---------------------------------------------------------------------
   STEP 4 — Create the Streamlit object.
   --------------------------------------------------------------------- */
CREATE OR REPLACE STREAMLIT INSURANCE_DEMO.CORE.MERIDIAN_COMMAND_CENTER_DASHBOARD
  ROOT_LOCATION  = '@INSURANCE_DEMO.CORE.STAGE_STREAMLIT_APP/app'
  MAIN_FILE      = 'app.py'
  QUERY_WAREHOUSE = GEN2_SMALL
  COMMENT        = 'Meridian Life Sales Command Center — 7 pages, all synthetic data, IDR currency.'
  TITLE          = 'Meridian Life Command Center';

SHOW STREAMLITS LIKE 'MERIDIAN_COMMAND_CENTER_DASHBOARD' IN SCHEMA INSURANCE_DEMO.CORE;

/* ---------------------------------------------------------------------
   Open it from the left menu: Projects -> Streamlit.

   ALTERNATIVE, if you prefer local tooling and have the Snowflake CLI:
   replace steps 1-3 with three PUT commands run from the repo root, e.g.
     PUT file://./07_streamlit/streamlit_app/app.py @STAGE_STREAMLIT_APP/app/
         AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
   Quote the whole file:// argument if your path contains spaces.
   --------------------------------------------------------------------- */
