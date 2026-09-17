/* =====================================================================
   MERIDIAN LIFE — 21_dimensions.sql
   Generation-control tables (GEN_*) + the 4 dimension tables.
   All values 100% synthetic & fictional. Fully reproducible: every random
   draw is keyed on the row's business key via RND()/RNDI()/RNDN().
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

/* ---------------------------------------------------------------------
   GEN_NAME_POOL — fictional Indonesian-market name parts
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE GEN_NAME_POOL AS
SELECT
  ARRAY_CONSTRUCT('Ahmad','Budi','Chandra','Dedi','Eko','Fajar','Gunawan','Hendra','Irfan','Joko',
                  'Krisna','Lukman','Made','Nanda','Oki','Prasetyo','Rizki','Surya','Teguh','Umar',
                  'Wahyu','Yusuf','Bayu','Dimas','Galih')                                   AS FIRST_M,
  ARRAY_CONSTRUCT('Ayu','Bunga','Citra','Dewi','Endah','Fitri','Gita','Hana','Indah','Kartika',
                  'Lestari','Maya','Nadia','Oktavia','Putri','Ratna','Sari','Tari','Utami','Wulan',
                  'Yuni','Anisa','Dinda','Rania','Salsa')                                   AS FIRST_F,
  ARRAY_CONSTRUCT('Wijaya','Santoso','Kusuma','Pratama','Halim','Nugroho','Saputra','Hidayat','Permana','Susanto',
                  'Anggraini','Maulana','Firmansyah','Setiawan','Rahmawati','Purnomo','Wibowo','Siregar','Nasution','Simatupang',
                  'Tanjung','Lubis','Ginting','Sinaga','Panjaitan','Putra','Sihombing','Marpaung','Manurung','Damanik') AS LAST_N;

/* =====================================================================
   DIM_BRANCH (23)
   ===================================================================== */
CREATE OR REPLACE TABLE DIM_BRANCH (
    BRANCH_ID       VARCHAR(10),
    BRANCH_CODE     VARCHAR(10),
    BRANCH_NAME     VARCHAR(80),
    CITY            VARCHAR(60),
    PROVINCE        VARCHAR(60),
    REGION          VARCHAR(60),
    BRANCH_TYPE     VARCHAR(30),
    OPEN_DATE       DATE,
    BRANCH_MANAGER  VARCHAR(80),
    ADDRESS_LINE    VARCHAR(180)
) COMMENT = 'Meridian Life sales branch master (fictional).';

INSERT INTO DIM_BRANCH VALUES
 ('B01','JKS','Jakarta Selatan Flagship','Jakarta Selatan','DKI Jakarta','Jabodetabek','Flagship','2015-03-02','Rudi Wijaya','Jl. Jenderal Sudirman Kav. 21, Jakarta Selatan'),
 ('B02','JKP','Jakarta Pusat','Jakarta Pusat','DKI Jakarta','Jabodetabek','Main','2015-06-15','Sinta Kusuma','Jl. M.H. Thamrin No. 8, Jakarta Pusat'),
 ('B03','JKB','Jakarta Barat','Jakarta Barat','DKI Jakarta','Jabodetabek','Main','2016-04-04','Hendra Santoso','Jl. Puri Indah Raya Blok U1, Jakarta Barat'),
 ('B04','JKU','Jakarta Utara','Jakarta Utara','DKI Jakarta','Jabodetabek','Satellite','2017-09-11','Maya Pratama','Jl. Boulevard Kelapa Gading, Jakarta Utara'),
 ('B05','TGR','Tangerang','Tangerang','Banten','Jabodetabek','Main','2016-11-21','Fajar Halim','Jl. Gading Serpong Boulevard, Tangerang'),
 ('B06','BKS','Bekasi','Bekasi','West Java','Jabodetabek','Main','2017-02-13','Dewi Nugroho','Jl. Ahmad Yani No. 45, Bekasi'),
 ('B07','BDG','Bandung','Bandung','West Java','West Java','Flagship','2015-08-17','Teguh Saputra','Jl. Asia Afrika No. 112, Bandung'),
 ('B08','BGR','Bogor','Bogor','West Java','West Java','Main','2018-05-07','Ratna Hidayat','Jl. Pajajaran No. 88, Bogor'),
 ('B09','CBN','Cirebon','Cirebon','West Java','West Java','Satellite','2019-03-18','Lukman Permana','Jl. Siliwangi No. 27, Cirebon'),
 ('B10','SMG','Semarang','Semarang','Central Java','Central Java','Main','2016-01-25','Wulan Susanto','Jl. Pemuda No. 150, Semarang'),
 ('B11','SLO','Surakarta','Surakarta','Central Java','Central Java','Satellite','2018-10-08','Bayu Maulana','Jl. Slamet Riyadi No. 302, Surakarta'),
 ('B12','YOG','Yogyakarta','Yogyakarta','DI Yogyakarta','Central Java','Main','2017-07-03','Gita Setiawan','Jl. Malioboro No. 60, Yogyakarta'),
 ('B13','SBY','Surabaya Flagship','Surabaya','East Java','East Java','Flagship','2015-04-20','Dimas Wibowo','Jl. Basuki Rahmat No. 90, Surabaya'),
 ('B14','MLG','Malang','Malang','East Java','East Java','Main','2017-11-06','Fitri Purnomo','Jl. Letjen Sutoyo No. 44, Malang'),
 ('B15','SDA','Sidoarjo','Sidoarjo','East Java','East Java','Satellite','2019-08-12','Irfan Firmansyah','Jl. Pahlawan No. 17, Sidoarjo'),
 ('B16','JBR','Jember','Jember','East Java','East Java','Satellite','2024-02-01','Nadia Rahmawati','Jl. Gajah Mada No. 205, Jember'),
 ('B17','DPS','Denpasar','Denpasar','Bali','Bali & Nusa Tenggara','Main','2016-09-05','Made Kusuma','Jl. Sunset Road No. 71, Denpasar'),
 ('B18','MTR','Mataram','Mataram','West Nusa Tenggara','Bali & Nusa Tenggara','Satellite','2024-04-01','Putri Anggraini','Jl. Pejanggik No. 33, Mataram'),
 ('B19','MDN','Medan','Medan','North Sumatra','Sumatra','Flagship','2015-10-19','Surya Siregar','Jl. Diponegoro No. 18, Medan'),
 ('B20','PLM','Palembang','Palembang','South Sumatra','Sumatra','Main','2018-01-29','Indah Nasution','Jl. Jenderal Sudirman No. 210, Palembang'),
 ('B21','PKB','Pekanbaru','Pekanbaru','Riau','Sumatra','Satellite','2019-06-24','Umar Tanjung','Jl. Riau No. 132, Pekanbaru'),
 ('B22','MKS','Makassar','Makassar','South Sulawesi','Eastern Indonesia','Main','2017-05-15','Citra Lubis','Jl. A.P. Pettarani No. 76, Makassar'),
 ('B23','SMD','Samarinda','Samarinda','East Kalimantan','Eastern Indonesia','Satellite','2024-03-01','Galih Ginting','Jl. Juanda No. 55, Samarinda');

/* ---------------------------------------------------------------------
   GEN_BRANCH_FACTOR — relative volume + DESIGNED achievement ratio.
   TARGET_FYAP will be derived as ACTUAL / ACH, so pattern (c) is exact:
     under-performers  0.44 - 0.58   (B09, B16, B18, B21, B23)
     over-performers   1.12 - 1.31   (B01, B07, B13, B19)
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE GEN_BRANCH_FACTOR (
    BRANCH_ID   VARCHAR(10),
    PROD_FACTOR FLOAT,
    ACH_2023    FLOAT,
    ACH_2024    FLOAT,
    ACH_2025    FLOAT
);
INSERT INTO GEN_BRANCH_FACTOR VALUES
 ('B01',1.00,1.08,1.15,1.24),  ('B02',0.82,0.97,1.02,1.05),  ('B03',0.74,0.95,0.93,0.90),
 ('B04',0.61,0.99,0.96,0.88),  ('B05',0.79,1.01,1.04,1.02),  ('B06',0.72,0.94,0.91,0.86),
 ('B07',0.95,1.04,1.11,1.18),  ('B08',0.66,0.92,0.90,0.84),  ('B09',0.38,0.81,0.66,0.52),
 ('B10',0.80,1.00,0.98,0.93),  ('B11',0.55,0.93,0.89,0.85),  ('B12',0.64,0.98,0.99,0.96),
 ('B13',0.98,1.12,1.19,1.31),  ('B14',0.71,1.01,0.95,0.82),  ('B15',0.50,0.90,0.87,0.83),
 ('B16',0.34,NULL,0.61,0.44),  ('B17',0.69,1.02,1.00,0.98),  ('B18',0.33,NULL,0.68,0.58),
 ('B19',0.90,1.06,1.09,1.12),  ('B20',0.62,0.96,0.94,0.89),  ('B21',0.42,0.83,0.70,0.49),
 ('B22',0.67,0.99,0.97,0.92),  ('B23',0.36,NULL,0.72,0.55);

-- Weighted-pick ranges for branch assignment (stable, no fan-out surprises)
CREATE OR REPLACE VIEW GEN_BRANCH_PICK AS
SELECT d.BRANCH_ID, d.OPEN_DATE, d.CITY, d.PROVINCE, d.REGION,
       (SUM(f.PROD_FACTOR) OVER (ORDER BY d.BRANCH_ID ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
         - f.PROD_FACTOR) / SUM(f.PROD_FACTOR) OVER ()                                    AS LO,
        SUM(f.PROD_FACTOR) OVER (ORDER BY d.BRANCH_ID ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                / SUM(f.PROD_FACTOR) OVER ()                              AS HI
FROM DIM_BRANCH d JOIN GEN_BRANCH_FACTOR f USING (BRANCH_ID);

/* ---------------------------------------------------------------------
   GEN_BRANCH_MONTH_EVENT — pattern (e): 3 spikes + 3 drops in H2-2025.
   Each event spans 2-3 consecutive months. A one-month blip is both
   unrealistic (agent attrition and system outages last quarters) and
   statistically undetectable here: a branch writes only 3-10 policies a
   month, so month-on-month CV is ~0.7 and a single-month shock sits
   inside any sane prediction interval.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE GEN_BRANCH_MONTH_EVENT (
    BRANCH_ID    VARCHAR(10),
    EVENT_MONTH  DATE,
    FACTOR       FLOAT,
    EVENT_LABEL  VARCHAR(60)
);
INSERT INTO GEN_BRANCH_MONTH_EVENT VALUES
 -- SPIKES
 ('B13','2025-08-01',2.60,'SPIKE - agency recruitment campaign'),
 ('B13','2025-09-01',2.00,'SPIKE - agency recruitment campaign'),
 ('B01','2025-10-01',2.40,'SPIKE - corporate payroll deal'),
 ('B01','2025-11-01',1.90,'SPIKE - corporate payroll deal'),
 ('B19','2025-09-01',2.10,'SPIKE - bancassurance push'),
 ('B19','2025-10-01',1.70,'SPIKE - bancassurance push'),
 -- DROPS
 ('B14','2025-09-01',0.20,'DROP - top unit manager resigned'),
 ('B14','2025-10-01',0.25,'DROP - top unit manager resigned'),
 ('B14','2025-11-01',0.35,'DROP - top unit manager resigned'),
 ('B10','2025-11-01',0.24,'DROP - core system migration outage'),
 ('B10','2025-12-01',0.30,'DROP - core system migration outage'),
 ('B09','2025-07-01',0.18,'DROP - mass agent attrition'),
 ('B09','2025-08-01',0.22,'DROP - mass agent attrition'),
 ('B09','2025-09-01',0.30,'DROP - mass agent attrition');

/* ---------------------------------------------------------------------
   GEN_CLASS_TRANSITION — pattern (d): non-uniform cross-class co-occurrence
   (Life -> Health deliberately strong so M7 finds lift > 1)
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE GEN_CLASS_TRANSITION (
    FROM_CLASS VARCHAR(40),
    TO_CLASS   VARCHAR(40),
    WEIGHT     FLOAT
);
INSERT INTO GEN_CLASS_TRANSITION VALUES
 ('Life','Health',52),('Life','Critical Illness',18),('Life','Education',12),('Life','Unit Link',8),('Life','Accident',5),('Life','Savings',3),('Life','Retirement',2),
 ('Health','Critical Illness',44),('Health','Life',22),('Health','Accident',16),('Health','Savings',7),('Health','Unit Link',5),('Health','Education',4),('Health','Retirement',2),
 ('Unit Link','Education',40),('Unit Link','Health',24),('Unit Link','Retirement',16),('Unit Link','Life',10),('Unit Link','Critical Illness',6),('Unit Link','Savings',3),('Unit Link','Accident',1),
 ('Savings','Retirement',43),('Savings','Education',21),('Savings','Life',15),('Savings','Health',12),('Savings','Unit Link',6),('Savings','Critical Illness',2),('Savings','Accident',1),
 ('Critical Illness','Health',48),('Critical Illness','Life',20),('Critical Illness','Accident',14),('Critical Illness','Unit Link',8),('Critical Illness','Savings',5),('Critical Illness','Education',3),('Critical Illness','Retirement',2),
 ('Accident','Health',46),('Accident','Life',24),('Accident','Critical Illness',15),('Accident','Savings',6),('Accident','Education',5),('Accident','Unit Link',3),('Accident','Retirement',1),
 ('Education','Savings',35),('Education','Unit Link',24),('Education','Health',18),('Education','Life',13),('Education','Retirement',6),('Education','Critical Illness',3),('Education','Accident',1),
 ('Retirement','Savings',38),('Retirement','Unit Link',22),('Retirement','Health',17),('Retirement','Life',13),('Retirement','Education',6),('Retirement','Critical Illness',3),('Retirement','Accident',1);

-- First-policy class mix (base rates)
CREATE OR REPLACE TABLE GEN_CLASS_BASE (CLASSIFICATION VARCHAR(40), WEIGHT FLOAT);
INSERT INTO GEN_CLASS_BASE VALUES
 ('Life',26),('Health',22),('Unit Link',15),('Critical Illness',11),
 ('Savings',9),('Education',8),('Accident',6),('Retirement',3);

/* =====================================================================
   DIM_PRODUCT (70) — 8 classifications x fictional product families
   ===================================================================== */
CREATE OR REPLACE TABLE DIM_PRODUCT AS
WITH cls AS (
  SELECT * FROM VALUES
    ('Health',           'Sehat',            'Traditional', 1.00, 2400000),
    ('Life',             'Proteksi Jiwa',    'Traditional', 1.15, 3000000),
    ('Unit Link',        'Investa Link',     'Unit Linked', 1.85, 6000000),
    ('Savings',          'Tabungan Cerdas',  'Traditional', 1.35, 4800000),
    ('Critical Illness', 'Kritis Guard',     'Traditional', 1.25, 3600000),
    ('Accident',         'Aman Diri',        'Traditional', 0.55, 1200000),
    ('Education',        'Edukasi Cemerlang','Unit Linked', 1.45, 5400000),
    ('Retirement',       'Pensiun Sejahtera','Unit Linked', 1.60, 6600000)
    AS t(CLASSIFICATION, FAMILY, PRODUCT_TYPE, PREMIUM_MULT, MIN_ANNUAL_PREMIUM)
), sfx AS (
  SELECT * FROM VALUES
    (1,'Essential',1,0.80),(2,'Prima',1,1.00),(3,'Plus',2,1.15),(4,'Optima',2,1.30),
    (5,'Flexi',2,1.10),(6,'Gold',3,1.55),(7,'Platinum',3,1.95),(8,'Signature',3,2.30),
    (9,'Syariah',2,1.05)
    AS s(SFX_NO, SUFFIX, TIER, TIER_MULT)
), base AS (
  SELECT ROW_NUMBER() OVER (ORDER BY c.CLASSIFICATION, s.SFX_NO) AS rn, c.*, s.*
  FROM cls c CROSS JOIN sfx s
)
SELECT
  'P' || LPAD(rn::VARCHAR, 3, '0')                                                     AS PRODUCT_ID,
  'MRD-' || LEFT(REPLACE(CLASSIFICATION,' ',''),4) || '-' || LPAD(rn::VARCHAR,3,'0')   AS PRODUCT_CODE,
  'Meridian ' || FAMILY || ' ' || SUFFIX                                               AS PRODUCT_NAME,
  CLASSIFICATION,
  CASE WHEN SUFFIX = 'Syariah' THEN 'Syariah' ELSE PRODUCT_TYPE END                    AS PRODUCT_TYPE,
  TIER                                                                                 AS PRODUCT_TIER,
  CASE TIER WHEN 1 THEN 'Entry' WHEN 2 THEN 'Core' ELSE 'Premium' END                  AS TIER_LABEL,
  ROUND(MIN_ANNUAL_PREMIUM * TIER_MULT, -5)::NUMBER(18,2)                              AS MIN_ANNUAL_PREMIUM,
  ROUND(PREMIUM_MULT * TIER_MULT, 4)::FLOAT                                            AS PREMIUM_FACTOR,
  DATEADD(day, -1 * RNDI('P'||LPAD(rn::VARCHAR,3,'0'), 101, 400, 3200), '2023-01-01'::DATE) AS LAUNCH_DATE,
  IFF(RND('P'||LPAD(rn::VARCHAR,3,'0'), 102) < 0.90, TRUE, FALSE)                       AS IS_ACTIVE,
  CASE WHEN TIER = 3 THEN 'Agency + Bancassurance'
       WHEN TIER = 2 THEN 'Agency'
       ELSE 'Agency + Digital' END                                                     AS DISTRIBUTION_CHANNEL,
  CASE WHEN CLASSIFICATION IN ('Unit Link','Education','Retirement') THEN 20
       WHEN CLASSIFICATION IN ('Life','Savings') THEN 15
       WHEN CLASSIFICATION = 'Critical Illness' THEN 10
       ELSE 5 END                                                                      AS DEFAULT_TERM_YEARS
FROM base
WHERE rn <= 70;

/* =====================================================================
   DIM_AGENT (1500)
   ===================================================================== */
CREATE OR REPLACE TABLE DIM_AGENT AS
WITH ids AS (
  SELECT 'A' || LPAD((SEQ4()+1)::VARCHAR, 5, '0') AS AGENT_ID
  FROM TABLE(GENERATOR(ROWCOUNT => 1500))
), withbranch AS (
  SELECT i.AGENT_ID, b.BRANCH_ID, b.OPEN_DATE
  FROM ids i
  JOIN GEN_BRANCH_PICK b
    ON RND(i.AGENT_ID, 201) >= b.LO AND RND(i.AGENT_ID, 201) < b.HI
), attrs AS (
  SELECT w.*, np.FIRST_M, np.FIRST_F, np.LAST_N,
         IFF(RND(w.AGENT_ID, 202) < 0.48, 'F', 'M')                                     AS GENDER,
         RND(w.AGENT_ID, 210)                                                           AS u_status,
         RND(w.AGENT_ID, 220)                                                           AS u_level,
         GREATEST(w.OPEN_DATE,
                  DATEADD(day, -1 * RNDI(w.AGENT_ID, 230, 45, 1400), '2025-12-31'::DATE)) AS JOIN_DATE
  FROM withbranch w CROSS JOIN GEN_NAME_POOL np
)
SELECT
  AGENT_ID,
  IFF(GENDER = 'M', FIRST_M[RNDI(AGENT_ID,203,0,24)]::VARCHAR,
                    FIRST_F[RNDI(AGENT_ID,204,0,24)]::VARCHAR)
    || ' ' || LAST_N[RNDI(AGENT_ID,205,0,29)]::VARCHAR                                  AS AGENT_NAME,
  GENDER,
  BRANCH_ID,
  CASE WHEN u_status < 0.72 THEN 'INFORCE'
       WHEN u_status < 0.80 THEN 'APPLICANT'
       ELSE 'TERMINATED' END                                                            AS AGENT_STATUS,
  CASE WHEN u_level < 0.62 THEN 'Agent'
       WHEN u_level < 0.83 THEN 'Senior Agent'
       WHEN u_level < 0.94 THEN 'Unit Manager'
       WHEN u_level < 0.99 THEN 'Agency Manager'
       ELSE 'Agency Director' END                                                       AS AGENT_LEVEL,
  JOIN_DATE,
  IFF(u_status >= 0.80,
      LEAST('2025-12-31'::DATE, DATEADD(day, RNDI(AGENT_ID,231,120,900), JOIN_DATE)),
      NULL)                                                                             AS TERMINATION_DATE,
  'LIC-' || RIGHT(AGENT_ID, 5) || '-' || RNDI(AGENT_ID,240,10,99)::VARCHAR              AS LICENSE_NUMBER,
  IFF(u_level >= 0.94, 'AAJI + AASI', 'AAJI')                                           AS CERTIFICATION,
  -- generation-control columns (skewed productivity so a Pareto emerges)
  ROUND(POWER(RND(AGENT_ID, 250), 1.9), 4)::FLOAT                                       AS GEN_PRODUCTIVITY,
  ROUND(0.25 + 0.75 * RND(AGENT_ID, 260), 4)::FLOAT                                     AS GEN_ACTIVITY_RATE,
  CAST(NULL AS VARCHAR(10))                                                             AS LEADER_ID
FROM attrs;

-- Assign a leader within the same branch (managers lead, directors do not report up)
UPDATE DIM_AGENT a
SET LEADER_ID = m.AGENT_ID
FROM (
  SELECT BRANCH_ID, AGENT_ID,
         ROW_NUMBER() OVER (PARTITION BY BRANCH_ID ORDER BY AGENT_ID) AS mgr_no,
         COUNT(*)    OVER (PARTITION BY BRANCH_ID)                    AS mgr_cnt
  FROM DIM_AGENT
  WHERE AGENT_LEVEL IN ('Unit Manager','Agency Manager','Agency Director')
) m
WHERE a.BRANCH_ID = m.BRANCH_ID
  AND m.mgr_no = 1 + MOD(ABS(HASH(a.AGENT_ID)), m.mgr_cnt)
  AND a.AGENT_LEVEL <> 'Agency Director'
  AND a.AGENT_ID <> m.AGENT_ID;

/* =====================================================================
   DIM_CUSTOMER (4400)
   ===================================================================== */
CREATE OR REPLACE TABLE DIM_CUSTOMER AS
WITH ids AS (
  SELECT 'C' || LPAD((SEQ4()+1)::VARCHAR, 6, '0') AS CUSTOMER_ID
  FROM TABLE(GENERATOR(ROWCOUNT => 4400))
), withgeo AS (
  SELECT i.CUSTOMER_ID, b.CITY, b.PROVINCE, b.REGION
  FROM ids i
  JOIN GEN_BRANCH_PICK b
    ON RND(i.CUSTOMER_ID, 301) >= b.LO AND RND(i.CUSTOMER_ID, 301) < b.HI
), attrs AS (
  SELECT w.*, np.FIRST_M, np.FIRST_F, np.LAST_N,
         IFF(RND(w.CUSTOMER_ID, 302) < 0.46, 'F', 'M')          AS GENDER,
         RNDI(w.CUSTOMER_ID, 307, 22, 66)                       AS AGE,
         RND(w.CUSTOMER_ID, 309)                                AS u_occ,
         RND(w.CUSTOMER_ID, 310)                                AS u_inc,
         RND(w.CUSTOMER_ID, 311)                                AS u_mar,
         RND(w.CUSTOMER_ID, 312)                                AS u_edu
  FROM withgeo w CROSS JOIN GEN_NAME_POOL np
)
SELECT
  CUSTOMER_ID,
  IFF(GENDER = 'M', FIRST_M[RNDI(CUSTOMER_ID,303,0,24)]::VARCHAR,
                    FIRST_F[RNDI(CUSTOMER_ID,304,0,24)]::VARCHAR)
    || ' ' || LAST_N[RNDI(CUSTOMER_ID,305,0,29)]::VARCHAR
    || IFF(RND(CUSTOMER_ID,314) < 0.28, ' ' || LAST_N[RNDI(CUSTOMER_ID,306,0,29)]::VARCHAR, '') AS CUSTOMER_NAME,
  GENDER,
  DATEADD(day, -1 * RNDI(CUSTOMER_ID,308,0,364), DATEADD(year, -1 * AGE, '2025-12-31'::DATE))   AS BIRTH_DATE,
  AGE,
  CASE WHEN AGE < 30 THEN '20-29' WHEN AGE < 40 THEN '30-39'
       WHEN AGE < 50 THEN '40-49' WHEN AGE < 60 THEN '50-59' ELSE '60+' END              AS AGE_BAND,
  CITY, PROVINCE, REGION,
  CASE WHEN u_occ < 0.24 THEN 'Private Employee'
       WHEN u_occ < 0.40 THEN 'Entrepreneur'
       WHEN u_occ < 0.52 THEN 'Civil Servant'
       WHEN u_occ < 0.62 THEN 'Professional'
       WHEN u_occ < 0.72 THEN 'Teacher / Lecturer'
       WHEN u_occ < 0.80 THEN 'Healthcare Worker'
       WHEN u_occ < 0.88 THEN 'Trader / Retailer'
       WHEN u_occ < 0.94 THEN 'Homemaker'
       ELSE 'Other' END                                                                 AS OCCUPATION,
  CASE WHEN u_inc < 0.30 THEN 'Below Rp 10M/month'
       WHEN u_inc < 0.60 THEN 'Rp 10M - 25M/month'
       WHEN u_inc < 0.83 THEN 'Rp 25M - 50M/month'
       WHEN u_inc < 0.95 THEN 'Rp 50M - 100M/month'
       ELSE 'Above Rp 100M/month' END                                                   AS INCOME_BAND,
  CASE WHEN u_mar < 0.62 THEN 'Married' WHEN u_mar < 0.90 THEN 'Single'
       ELSE 'Divorced / Widowed' END                                                    AS MARITAL_STATUS,
  CASE WHEN u_edu < 0.18 THEN 'High School' WHEN u_edu < 0.34 THEN 'Diploma'
       WHEN u_edu < 0.82 THEN 'Bachelor' ELSE 'Master or above' END                      AS EDUCATION,
  DATEADD(day, RNDI(CUSTOMER_ID,313,0,1094), '2023-01-01'::DATE)                        AS ACQUISITION_DATE,
  'cust' || RIGHT(CUSTOMER_ID,6) || '@example.invalid'                                  AS EMAIL,
  '+62-8' || RNDI(CUSTOMER_ID,315,10,99)::VARCHAR || '-xxxx-'
          || LPAD(RNDI(CUSTOMER_ID,316,0,9999)::VARCHAR, 4, '0')                        AS PHONE_MASKED,
  IFF(RND(CUSTOMER_ID,317) < 0.66, TRUE, FALSE)                                         AS CONSENT_MARKETING
FROM attrs;

/* ---------------------------------------------------------------------
   Verification
   --------------------------------------------------------------------- */
SELECT 'DIM_BRANCH' t, COUNT(*) n, NULL::INT branches FROM DIM_BRANCH
UNION ALL SELECT 'DIM_PRODUCT',  COUNT(*), COUNT(DISTINCT CLASSIFICATION) FROM DIM_PRODUCT
UNION ALL SELECT 'DIM_AGENT',    COUNT(*), COUNT(DISTINCT BRANCH_ID)      FROM DIM_AGENT
UNION ALL SELECT 'DIM_CUSTOMER', COUNT(*), COUNT(DISTINCT PROVINCE)       FROM DIM_CUSTOMER
ORDER BY 1;
