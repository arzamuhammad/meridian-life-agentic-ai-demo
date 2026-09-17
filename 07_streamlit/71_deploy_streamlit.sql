/* =====================================================================
   MERIDIAN LIFE — 71_deploy_streamlit.sql
   Deploy the Command Center dashboard to Snowflake.
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

-- Upload all app files to stage.
-- Paths are relative to the REPO ROOT, so run this from the repo root:
--     snow sql -c <connection> -f 07_streamlit/71_deploy_streamlit.sql
-- If your client resolves file:// differently, replace ./ with an absolute path.
PUT file://./07_streamlit/streamlit_app/app.py @STAGE_STREAMLIT_APP/app/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://./07_streamlit/streamlit_app/environment.yml @STAGE_STREAMLIT_APP/app/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://./07_streamlit/streamlit_app/.streamlit/config.toml @STAGE_STREAMLIT_APP/app/.streamlit/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- Create the Streamlit object
CREATE OR REPLACE STREAMLIT INSURANCE_DEMO.CORE.MERIDIAN_COMMAND_CENTER_DASHBOARD
  ROOT_LOCATION  = '@INSURANCE_DEMO.CORE.STAGE_STREAMLIT_APP/app'
  MAIN_FILE      = 'app.py'
  QUERY_WAREHOUSE = GEN2_SMALL
  COMMENT        = 'Meridian Life Sales Command Center — 7 pages, all synthetic data, IDR currency.'
  TITLE          = 'Meridian Life Command Center';

SHOW STREAMLITS LIKE 'MERIDIAN_COMMAND_CENTER_DASHBOARD' IN SCHEMA INSURANCE_DEMO.CORE;
