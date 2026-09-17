/* =====================================================================
   MERIDIAN LIFE — 20_gen_helpers.sql
   Deterministic pseudo-random helpers.
   Why not RANDOM(seed)? RANDOM(seed) is re-evaluated per row of an
   intermediate join, so a "draw" is not stable for a given logical key.
   HASH() is deterministic and stable, giving fully reproducible data.
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

-- Uniform [0,1) keyed on an arbitrary string key + integer salt (stream id)
CREATE OR REPLACE FUNCTION RND(K VARCHAR, SALT INT)
RETURNS FLOAT
IMMUTABLE
AS $$
  ((ABS(HASH(K, SALT)) % 1000000) / 1000000.0)::FLOAT
$$;

-- Integer uniform in [LO, HI]
CREATE OR REPLACE FUNCTION RNDI(K VARCHAR, SALT INT, LO INT, HI INT)
RETURNS INT
IMMUTABLE
AS $$
  (LO + (ABS(HASH(K, SALT)) % (HI - LO + 1)))::INT
$$;

-- Approx standard normal via Irwin-Hall(6): mean 3, sd sqrt(0.5)
CREATE OR REPLACE FUNCTION RNDN(K VARCHAR, SALT INT)
RETURNS FLOAT
IMMUTABLE
AS $$
  ( RND(K, SALT)   + RND(K, SALT+1) + RND(K, SALT+2)
  + RND(K, SALT+3) + RND(K, SALT+4) + RND(K, SALT+5) - 3.0 )::FLOAT / 0.70710678::FLOAT
$$;

-- Smoke test: uniformity + stability
SELECT ROUND(AVG(RND(rn::VARCHAR, 7)), 4)          AS mean_should_be_0_5,
       ROUND(STDDEV(RND(rn::VARCHAR, 7)), 4)       AS sd_should_be_0_289,
       ROUND(AVG(RNDN(rn::VARCHAR, 7)), 4)         AS n_mean_should_be_0,
       ROUND(STDDEV(RNDN(rn::VARCHAR, 7)), 4)      AS n_sd_should_be_1
FROM (SELECT SEQ4() rn FROM TABLE(GENERATOR(ROWCOUNT => 50000)));
