/* =====================================================================
   MERIDIAN LIFE — 51_semantic_view.sql
   MERIDIAN_SALES_INTELLIGENCE — Cortex Analyst text-to-SQL layer.

   JOIN TOPOLOGY (deliberately a TREE, not a graph)
     Every fact has exactly ONE path to every dimension. Branch is always
     reached through AGENTS (agents -> branches), never directly from
     policies, so there is no ambiguous policies->branches second path that
     would force USING() on every metric.

           branches
              ^
              |
           agents  <-- production, activity, apps_behavior, training, agent_scores
              ^
              |
           policies <-- payments, riders, claims, tickets, lapse_risk
            ^     ^
            |     |
     customers   products
       ^   ^
       |   |
      clv  cross_sell

     branch_target, achievement, anomalies, forecast, recommendations -> branches

   FAN-OUT RULE
     Achievement % is NEVER computed by joining FACT_BRANCH_TARGET to
     production (that fans out target across every production row and
     inflates it). It comes from V_BRANCH_ACHIEVEMENT, which pre-aggregates
     both sides before joining, and the metric is defined as a ratio of sums
     so it stays correct at any grouping level.

   Clause order is mandatory: TABLES, RELATIONSHIPS, FACTS, DIMENSIONS,
   METRICS, COMMENT, AI_SQL_GENERATION, AI_QUESTION_CATEGORIZATION,
   AI_VERIFIED_QUERIES.
   ===================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GEN2_SMALL;
USE SCHEMA INSURANCE_DEMO.CORE;

CREATE OR REPLACE SEMANTIC VIEW INSURANCE_DEMO.CORE.MERIDIAN_SALES_INTELLIGENCE

TABLES (
  -- ---------- dimensions ----------
  branches AS INSURANCE_DEMO.CORE.DIM_BRANCH
      PRIMARY KEY (BRANCH_ID)
      WITH SYNONYMS = ('branch','cabang','kantor cabang','office','sales office')
      COMMENT = 'Meridian Life sales branches. 23 branches across Indonesia.',
  agents AS INSURANCE_DEMO.CORE.DIM_AGENT
      PRIMARY KEY (AGENT_ID)
      WITH SYNONYMS = ('agent','agen','salesperson','advisor','financial advisor','tenaga pemasar')
      COMMENT = 'Insurance sales agents. AGENT_STATUS is INFORCE, APPLICANT or TERMINATED.',
  customers AS INSURANCE_DEMO.CORE.DIM_CUSTOMER
      PRIMARY KEY (CUSTOMER_ID)
      WITH SYNONYMS = ('customer','policyholder','nasabah','pemegang polis','client')
      COMMENT = 'Policyholders. All names are synthetic; no real PII.',
  products AS INSURANCE_DEMO.CORE.DIM_PRODUCT
      PRIMARY KEY (PRODUCT_ID)
      WITH SYNONYMS = ('product','produk','plan','insurance product')
      COMMENT = '70 products across 8 classifications: Health, Life, Unit Link, Savings, Critical Illness, Accident, Education, Retirement.',

  -- ---------- policy facts ----------
  policies AS INSURANCE_DEMO.CORE.FACT_POLICY
      PRIMARY KEY (POLICY_ID)
      WITH SYNONYMS = ('policy','polis','contract','new business','case')
      COMMENT = 'One row per policy sold. POLICY_STATUS is Inforce, Lapsed or Terminated. FYAP is first-year annualised premium.',
  payments AS INSURANCE_DEMO.CORE.FACT_POLICY_PAYMENT
      PRIMARY KEY (PAYMENT_ID)
      WITH SYNONYMS = ('payment','premium payment','pembayaran','instalment','billing')
      COMMENT = 'Premium instalments. FEE_STATUS is Payment Confirmed, Pending or Failed. Use Payment Confirmed for collected premium.',
  riders AS INSURANCE_DEMO.CORE.FACT_POLICY_RIDER
      PRIMARY KEY (RIDER_ID)
      WITH SYNONYMS = ('rider','add-on','manfaat tambahan','supplementary benefit')
      COMMENT = 'Optional riders attached to policies.',
  claims AS INSURANCE_DEMO.CORE.FACT_CLAIMS
      PRIMARY KEY (CLAIM_ID)
      WITH SYNONYMS = ('claim','klaim','benefit payout')
      COMMENT = 'Claims. CLAIM_DECISION is Approved or Rejected. APPROVED_AMOUNT is what was actually paid.',
  tickets AS INSURANCE_DEMO.CORE.FACT_CRM_TICKETS
      PRIMARY KEY (TICKET_ID)
      WITH SYNONYMS = ('ticket','crm ticket','complaint','keluhan','service request')
      COMMENT = 'CRM service tickets. IS_RETENTION_RELATED marks lapse/billing/surrender enquiries.',

  -- ---------- agent activity facts ----------
  production AS INSURANCE_DEMO.CORE.FACT_AGENT_PRODUCTION
      PRIMARY KEY (PRODUCTION_ID)
      WITH SYNONYMS = ('monthly production','produksi','sales production','FYAP production')
      COMMENT = 'Monthly production per agent. Reconciles exactly with FACT_POLICY. THE source for actual FYAP by month.',
  activity AS INSURANCE_DEMO.CORE.FACT_AGENT_ACTIVITY
      PRIMARY KEY (ACTIVITY_ID)
      WITH SYNONYMS = ('activities','aktivitas','sales activity','prospecting','calls')
      COMMENT = 'Logged agent sales activities and their outcomes.',
  apps_behavior AS INSURANCE_DEMO.CORE.FACT_AGENT_APPS_BEHAVIOR
      PRIMARY KEY (BEHAVIOR_ID)
      WITH SYNONYMS = ('app usage','app behaviour','mobile app','aplikasi','digital engagement','telemetry')
      COMMENT = 'Mobile app telemetry for agents. IS_RECOMMENDATION_ACTED closes the AI feedback loop.',
  training AS INSURANCE_DEMO.CORE.FACT_TRAINING
      PRIMARY KEY (TRAINING_ID)
      WITH SYNONYMS = ('courses','pelatihan','certification','learning')
      COMMENT = 'Agent training and certification records.',

  -- ---------- targets (BRANCH level only) ----------
  branch_target AS INSURANCE_DEMO.CORE.FACT_BRANCH_TARGET
      PRIMARY KEY (TARGET_ID)
      WITH SYNONYMS = ('target','quota','budget','rencana','goal','sales target')
      COMMENT = 'Annual FYAP plan per BRANCH. There is NO per-agent target in this model.',
  achievement AS INSURANCE_DEMO.CORE.V_BRANCH_ACHIEVEMENT
      PRIMARY KEY (BRANCH_ID, FISCAL_YEAR)
      WITH SYNONYMS = ('target vs actual','plan vs actual','performance vs plan','branch scorecard')
      COMMENT = 'THE ONLY sanctioned source of achievement %. Pre-aggregates target and actual separately so joins cannot fan out.',

  -- ---------- ML model outputs ----------
  lapse_risk AS INSURANCE_DEMO.CORE.LAPSE_RISK_SCORES
      PRIMARY KEY (POLICY_ID)
      WITH SYNONYMS = ('lapse risk','churn risk','risiko lapse','attrition risk','lapse prediction','M1')
      COMMENT = 'M1 output: 90-day lapse probability per in-force policy as of 2025-12-01. RISK_SEGMENT is LOW, MEDIUM, HIGH or CRITICAL. IS_DANGER_ZONE flags month 10-14 tenure.',
  clv AS INSURANCE_DEMO.CORE.CUSTOMER_CLV_SCORES
      PRIMARY KEY (CUSTOMER_ID)
      WITH SYNONYMS = ('lifetime value','customer value','nilai nasabah','customer worth','M5')
      COMMENT = 'M5 output: actuarial discounted lifetime value. CLV_SEGMENT quartiles are PLATINUM, GOLD, SILVER, BRONZE.',
  cross_sell AS INSURANCE_DEMO.CORE.CROSS_SELL_RECOMMENDATIONS
      PRIMARY KEY (CUSTOMER_ID, REC_RANK)
      WITH SYNONYMS = ('cross sell','upsell','next product','rekomendasi produk','product recommendation','M7')
      COMMENT = 'M7 output: association-rule cross-sell offers. Only classes the customer does not hold, and only rules with lift >= 1.',
  agent_scores AS INSURANCE_DEMO.CORE.AGENT_PERFORMANCE_SCORES
      PRIMARY KEY (AGENT_ID)
      WITH SYNONYMS = ('agent score','agent performance','skor agen','leaderboard','agent ranking','M3')
      COMMENT = 'M3 output: composite 0-100 behaviour score for INFORCE agents. Production 50%, Activity 20%, Training 15%, Retention 15%. This is NOT achievement versus a target.',
  anomalies AS INSURANCE_DEMO.CORE.PRODUCTION_ANOMALIES
      PRIMARY KEY (BRANCH_ID, PRODUCTION_MONTH)
      WITH SYNONYMS = ('anomaly','outlier','anomali','unusual production','spike','drop','M6')
      COMMENT = 'M6 output: production anomalies on a 3-month rolling series, H2 2025. ANOMALY_TYPE is SPIKE, DROP or NORMAL.',
  forecast AS INSURANCE_DEMO.CORE.REVENUE_FORECAST_RESULTS
      PRIMARY KEY (BRANCH_ID, FORECAST_MONTH)
      WITH SYNONYMS = ('projection','prediksi','proyeksi','outlook','predicted revenue','M2')
      COMMENT = 'M2 output: 6-month FYAP forecast per branch for 2026 with a 95% prediction interval.',
  recommendations AS INSURANCE_DEMO.CORE.AI_RECOMMENDATIONS
      PRIMARY KEY (RECOMMENDATION_ID)
      WITH SYNONYMS = ('recommendation','next best action','nba','rekomendasi','action queue','tindakan','M4')
      COMMENT = 'M4 output: Next-Best-Action queue ranked by URGENCY_SCORE 0-100. Types include RETENTION_CALL, RENEWAL_FOLLOW_UP, CROSS_SELL, COACHING_ACTIVITY, REACTIVATION, BRANCH_BELOW_TARGET.'
)

RELATIONSHIPS (
  agents_to_branch        AS agents        (BRANCH_ID)               REFERENCES branches (BRANCH_ID),
  policies_to_agent       AS policies      (AGENT_ID)                REFERENCES agents   (AGENT_ID),
  policies_to_customer    AS policies      (CUSTOMER_ID)             REFERENCES customers(CUSTOMER_ID),
  policies_to_product     AS policies      (PRODUCT_ID)              REFERENCES products (PRODUCT_ID),
  payments_to_policy      AS payments      (POLICY_ID)               REFERENCES policies (POLICY_ID),
  riders_to_policy        AS riders        (POLICY_ID)               REFERENCES policies (POLICY_ID),
  claims_to_policy        AS claims        (POLICY_ID)               REFERENCES policies (POLICY_ID),
  tickets_to_policy       AS tickets       (POLICY_ID)               REFERENCES policies (POLICY_ID),
  lapse_to_policy         AS lapse_risk    (POLICY_ID)               REFERENCES policies (POLICY_ID),
  production_to_agent     AS production    (AGENT_ID)                REFERENCES agents   (AGENT_ID),
  activity_to_agent       AS activity      (AGENT_ID)                REFERENCES agents   (AGENT_ID),
  apps_to_agent           AS apps_behavior (AGENT_ID)                REFERENCES agents   (AGENT_ID),
  training_to_agent       AS training      (AGENT_ID)                REFERENCES agents   (AGENT_ID),
  agentscore_to_agent     AS agent_scores  (AGENT_ID)                REFERENCES agents   (AGENT_ID),
  clv_to_customer         AS clv           (CUSTOMER_ID)             REFERENCES customers(CUSTOMER_ID),
  crosssell_to_customer   AS cross_sell    (CUSTOMER_ID)             REFERENCES customers(CUSTOMER_ID),
  target_to_branch        AS branch_target (BRANCH_ID)               REFERENCES branches (BRANCH_ID),
  achievement_to_branch   AS achievement   (BRANCH_ID)               REFERENCES branches (BRANCH_ID),
  anomalies_to_branch     AS anomalies     (BRANCH_ID)               REFERENCES branches (BRANCH_ID),
  forecast_to_branch      AS forecast      (BRANCH_ID)               REFERENCES branches (BRANCH_ID),
  recommendations_to_branch AS recommendations (BRANCH_ID)           REFERENCES branches (BRANCH_ID)
)

FACTS (
  policies.annual_premium        AS ANNUAL_PREMIUM        COMMENT = 'Annual premium in IDR',
  policies.fyap           AS FYAP                  COMMENT = 'First-year annualised premium in IDR',
  policies.sum_assured    AS SUM_ASSURED           COMMENT = 'Sum assured in IDR',
  policies.policy_row            AS 1                     COMMENT = 'Row counter for policy counts',

  payments.premium_paid_amount          AS PREMIUM_PAID_AMOUNT   COMMENT = 'Premium actually collected in IDR',
  payments.premium_due_amount           AS PREMIUM_DUE_AMOUNT    COMMENT = 'Premium billed in IDR',
  payments.days_late             AS DAYS_LATE             COMMENT = 'Days between due date and collection',

  riders.rider_premium    AS RIDER_PREMIUM         COMMENT = 'Rider premium in IDR',

  claims.claim_amount      AS CLAIM_AMOUNT          COMMENT = 'Amount claimed in IDR',
  claims.approved_amount   AS APPROVED_AMOUNT       COMMENT = 'Amount approved and paid in IDR',

  tickets.resolution_days AS RESOLUTION_DAYS       COMMENT = 'Days to resolve the ticket',

  production.fyap     AS FYAP                  COMMENT = 'Monthly FYAP produced in IDR',
  production.new_policies AS NEW_POLICIES          COMMENT = 'New policies written in the month',
  production.commission_amount AS COMMISSION_AMOUNT   COMMENT = 'First-year commission in IDR',

  activity.duration_minutes      AS DURATION_MINUTES      COMMENT = 'Activity duration in minutes',
  apps_behavior.session_minutes   AS SESSION_MINUTES       COMMENT = 'App session length in minutes',
  training.score        AS SCORE                 COMMENT = 'Training assessment score 0-100',
  training.duration_hours        AS DURATION_HOURS        COMMENT = 'Course duration in hours',

  branch_target.target_fyap    AS TARGET_FYAP           COMMENT = 'Annual branch FYAP plan in IDR',
  branch_target.target_policies AS TARGET_POLICIES    COMMENT = 'Annual branch policy plan',

  achievement.target_fyap    AS TARGET_FYAP           COMMENT = 'Branch plan FYAP in IDR',
  achievement.actual_fyap    AS ACTUAL_FYAP           COMMENT = 'Branch actual FYAP in IDR',
  achievement.fyap_variance       AS FYAP_VARIANCE         COMMENT = 'Actual minus plan in IDR',

  lapse_risk.lapse_probability AS LAPSE_PROBABILITY     COMMENT = '90-day lapse probability 0-1',
  lapse_risk.annual_premium   AS ANNUAL_PREMIUM         COMMENT = 'Annual premium of the scored policy in IDR',
  lapse_risk.tenure_months     AS TENURE_MONTHS          COMMENT = 'Policy age in months at scoring date',

  clv.clv                 AS CLV                   COMMENT = 'Customer lifetime value in IDR',
  clv.inforce_annual_premium        AS INFORCE_ANNUAL_PREMIUM COMMENT = 'In-force annual premium in IDR',
  clv.retention_rate              AS RETENTION_RATE        COMMENT = 'Annual retention probability',

  cross_sell.best_lift             AS BEST_LIFT             COMMENT = 'Association-rule lift, above 1 means better than base rate',
  cross_sell.best_confidence       AS BEST_CONFIDENCE       COMMENT = 'Association-rule confidence 0-1',
  cross_sell.expected_annual_premium AS EXPECTED_ANNUAL_PREMIUM COMMENT = 'Expected annual premium of the offer in IDR',

  agent_scores.composite_score         AS COMPOSITE_SCORE       COMMENT = 'Composite agent score 0-100',
  agent_scores.production_score  AS PRODUCTION_SCORE      COMMENT = 'Production pillar 0-100',
  agent_scores.activity_score    AS ACTIVITY_SCORE        COMMENT = 'Activity pillar 0-100',
  agent_scores.training_score    AS TRAINING_SCORE        COMMENT = 'Training pillar 0-100',
  agent_scores.retention_score   AS RETENTION_SCORE       COMMENT = 'Retention pillar 0-100',
  agent_scores.fyap_12m          AS FYAP_12M              COMMENT = 'Agent FYAP in the last 12 months in IDR',
  agent_scores.persistency_pct AS PERSISTENCY_PCT       COMMENT = 'Share of the agent book not lapsed',

  anomalies.actual_rolling3_fyap       AS ACTUAL_ROLLING3_FYAP  COMMENT = 'Actual 3-month rolling FYAP in IDR',
  anomalies.expected_fyap     AS EXPECTED_FYAP         COMMENT = 'Model-expected 3-month rolling FYAP in IDR',
  anomalies.pct_deviation    AS PCT_DEVIATION         COMMENT = 'Percent deviation from expected',

  forecast.forecast_fyap       AS FORECAST_FYAP         COMMENT = 'Forecast monthly FYAP in IDR',
  forecast.lower_bound_95        AS LOWER_BOUND_95        COMMENT = 'Lower bound of the 95% interval',
  forecast.upper_bound_95        AS UPPER_BOUND_95        COMMENT = 'Upper bound of the 95% interval',

  recommendations.urgency_score        AS URGENCY_SCORE         COMMENT = 'Action urgency 0-100',
  recommendations.expected_value   AS EXPECTED_VALUE        COMMENT = 'Estimated IDR value of the action'
)

DIMENSIONS (
  -- branches
  branches.branch_id        AS BRANCH_ID      WITH SYNONYMS = ('branch code','kode cabang') COMMENT = 'Branch identifier',
  branches.branch_name      AS BRANCH_NAME    WITH SYNONYMS = ('nama cabang','office name') COMMENT = 'Branch name',
  branches.city             AS CITY           WITH SYNONYMS = ('kota','town') COMMENT = 'Branch city',
  branches.province         AS PROVINCE       WITH SYNONYMS = ('provinsi','state','region name') COMMENT = 'Province, e.g. East Java, DKI Jakarta, West Java',
  branches.region           AS REGION         WITH SYNONYMS = ('wilayah','area','zone') COMMENT = 'Sales region grouping several provinces',
  branches.branch_type      AS BRANCH_TYPE    WITH SYNONYMS = ('tipe cabang','office type') COMMENT = 'Flagship, Main or Satellite',
  branches.open_date AS OPEN_DATE      WITH SYNONYMS = ('opening date','tanggal buka') COMMENT = 'Date the branch opened',

  -- agents
  agents.agent_id           AS AGENT_ID       WITH SYNONYMS = ('agent code','kode agen') COMMENT = 'Agent identifier',
  agents.agent_name         AS AGENT_NAME     WITH SYNONYMS = ('nama agen','advisor name') COMMENT = 'Agent full name',
  agents.agent_status       AS AGENT_STATUS   WITH SYNONYMS = ('status agen','active status') COMMENT = 'INFORCE (active), APPLICANT or TERMINATED',
  agents.agent_level        AS AGENT_LEVEL    WITH SYNONYMS = ('jenjang','rank','position') COMMENT = 'Agent, Senior Agent, Unit Manager, Agency Manager, Agency Director',
  agents.gender       AS GENDER         WITH SYNONYMS = ('jenis kelamin') COMMENT = 'M or F',
  agents.join_date    AS JOIN_DATE      WITH SYNONYMS = ('tanggal join','recruitment date','hire date') COMMENT = 'Date the agent joined',
  agents.leader_id    AS LEADER_ID      WITH SYNONYMS = ('leader','manager','atasan','supervisor') COMMENT = 'Agent identifier of the leader',

  -- customers
  customers.customer_id     AS CUSTOMER_ID    WITH SYNONYMS = ('customer code','nomor nasabah') COMMENT = 'Customer identifier',
  customers.customer_name   AS CUSTOMER_NAME  WITH SYNONYMS = ('nama nasabah','policyholder name') COMMENT = 'Customer full name (synthetic)',
  customers.age    AS AGE            WITH SYNONYMS = ('umur','usia') COMMENT = 'Customer age in years',
  customers.age_band        AS AGE_BAND       WITH SYNONYMS = ('kelompok umur','age group','age bracket') COMMENT = '20-29, 30-39, 40-49, 50-59, 60+',
  customers.gender AS GENDER          COMMENT = 'M or F',
  customers.occupation      AS OCCUPATION     WITH SYNONYMS = ('pekerjaan','job','profession') COMMENT = 'Customer occupation',
  customers.income_band     AS INCOME_BAND    WITH SYNONYMS = ('penghasilan','income group','salary band') COMMENT = 'Monthly income band in IDR',
  customers.marital_status  AS MARITAL_STATUS WITH SYNONYMS = ('status pernikahan') COMMENT = 'Married, Single or Divorced / Widowed',
  customers.province AS PROVINCE     WITH SYNONYMS = ('provinsi nasabah') COMMENT = 'Customer province',
  customers.acquisition_date AS ACQUISITION_DATE WITH SYNONYMS = ('tanggal akuisisi','join date','first contact') COMMENT = 'Date the customer was acquired',

  -- products
  products.product_id       AS PRODUCT_ID     WITH SYNONYMS = ('product code','kode produk') COMMENT = 'Product identifier',
  products.product_name     AS PRODUCT_NAME   WITH SYNONYMS = ('nama produk','plan name') COMMENT = 'Product name, e.g. Meridian Sehat Gold',
  products.classification   AS CLASSIFICATION WITH SYNONYMS = ('product class','kelas produk','jenis produk','product category','product type group') COMMENT = 'Health, Life, Unit Link, Savings, Critical Illness, Accident, Education, Retirement',
  products.product_type     AS PRODUCT_TYPE   WITH SYNONYMS = ('contract type','tipe kontrak') COMMENT = 'Traditional, Unit Linked or Syariah',
  products.tier_label       AS TIER_LABEL     WITH SYNONYMS = ('tier','level produk','grade') COMMENT = 'Entry, Core or Premium',

  -- policies
  policies.policy_id        AS POLICY_ID      WITH SYNONYMS = ('policy number','nomor polis') COMMENT = 'Policy identifier',
  policies.policy_status    AS POLICY_STATUS  WITH SYNONYMS = ('status polis','contract status') COMMENT = 'Inforce, Lapsed or Terminated',
  policies.payment_frequency AS PAYMENT_FREQUENCY WITH SYNONYMS = ('frekuensi bayar','billing frequency','payment mode','cara bayar') COMMENT = 'Monthly, Quarterly, Semi-Annual, Yearly or Single',
  policies.payment_mode     AS PAYMENT_MODE   WITH SYNONYMS = ('premium mode') COMMENT = 'Regular or Single premium',
  policies.issue_date       AS ISSUE_DATE     WITH SYNONYMS = ('tanggal terbit','sale date','inception date','policy date') COMMENT = 'Date the policy was issued. Primary time dimension for new business.',
  policies.issue_month      AS ISSUE_MONTH    WITH SYNONYMS = ('bulan terbit','sales month','production month') COMMENT = 'Month the policy was issued',
  policies.issue_year       AS ISSUE_YEAR     WITH SYNONYMS = ('tahun terbit','sales year','fiscal year') COMMENT = 'Year the policy was issued (2023-2025)',
  policies.lapse_date       AS LAPSE_DATE     WITH SYNONYMS = ('tanggal lapse') COMMENT = 'Date the policy lapsed, NULL if still in force',
  policies.policy_month_at_lapse AS POLICY_MONTH_AT_LAPSE WITH SYNONYMS = ('lapse month','bulan lapse','tenure at lapse') COMMENT = 'Policy age in months when it lapsed. Month 13 is the danger zone.',
  policies.next_renewal_date AS NEXT_RENEWAL_DATE WITH SYNONYMS = ('renewal date','tanggal perpanjangan','anniversary') COMMENT = 'Next policy anniversary for in-force policies',
  policies.submission_channel AS SUBMISSION_CHANNEL WITH SYNONYMS = ('channel','kanal','application channel') COMMENT = 'e-Application, Paper Application or Digital Self-Service',
  policies.underwriting_decision AS UNDERWRITING_DECISION WITH SYNONYMS = ('underwriting','keputusan underwriting') COMMENT = 'Standard, Substandard - Loading or Standard - Exclusion Applied',

  -- payments
  payments.fee_status       AS FEE_STATUS     WITH SYNONYMS = ('payment status','status pembayaran') COMMENT = 'Payment Confirmed, Pending or Failed. Payment Confirmed means collected.',
  payments.due_date         AS DUE_DATE       WITH SYNONYMS = ('tanggal jatuh tempo','billing date') COMMENT = 'Premium due date',
  payments.due_year         AS DUE_YEAR       WITH SYNONYMS = ('tahun tagihan') COMMENT = 'Year the premium was due',
  payments.payment_channel  AS PAYMENT_CHANNEL WITH SYNONYMS = ('metode bayar','payment method') COMMENT = 'Auto Debit, Credit Card, Bank Transfer, Virtual Account or e-Wallet',
  payments.is_late     AS IS_LATE        WITH SYNONYMS = ('terlambat','late payment') COMMENT = 'TRUE if paid more than 5 days after the due date',

  -- riders
  riders.rider_type         AS RIDER_TYPE     WITH SYNONYMS = ('jenis rider') COMMENT = 'Rider type',
  riders.rider_status       AS RIDER_STATUS   WITH SYNONYMS = ('status rider') COMMENT = 'Inforce, Lapsed, Terminated or Cancelled',

  -- claims
  claims.claim_type         AS CLAIM_TYPE     WITH SYNONYMS = ('jenis klaim') COMMENT = 'Inpatient, Outpatient, Surgery, Critical Illness, Accident, Death, Disability or Maternity',
  claims.claim_decision     AS CLAIM_DECISION WITH SYNONYMS = ('keputusan klaim','claim outcome') COMMENT = 'Approved or Rejected',
  claims.claim_status       AS CLAIM_STATUS   WITH SYNONYMS = ('status klaim') COMMENT = 'Settled, In Review or Pending Document',
  claims.claim_date         AS CLAIM_DATE     WITH SYNONYMS = ('tanggal klaim') COMMENT = 'Date the claim was filed',
  claims.claim_year         AS CLAIM_YEAR     WITH SYNONYMS = ('tahun klaim') COMMENT = 'Year the claim was filed',

  -- tickets
  tickets.subject    AS SUBJECT        WITH SYNONYMS = ('subjek','ticket topic') COMMENT = 'Ticket subject, e.g. Lapse / Reinstatement, Premium due reminder',
  tickets.category   AS CATEGORY       WITH SYNONYMS = ('kategori tiket') COMMENT = 'Ticket category',
  tickets.sentiment  AS SENTIMENT      WITH SYNONYMS = ('sentimen') COMMENT = 'Positive, Neutral or Negative',
  tickets.ticket_date       AS TICKET_DATE    WITH SYNONYMS = ('tanggal tiket') COMMENT = 'Date the ticket was raised',
  tickets.is_retention_related AS IS_RETENTION_RELATED WITH SYNONYMS = ('retention ticket','tiket retensi') COMMENT = 'TRUE for lapse, billing or surrender enquiries',

  -- production
  production.production_month     AS PRODUCTION_MONTH WITH SYNONYMS = ('bulan produksi','month','production period') COMMENT = 'Production month. Primary time dimension for monthly FYAP.',
  production.production_year      AS PRODUCTION_YEAR  WITH SYNONYMS = ('tahun produksi','year') COMMENT = 'Production year (2023-2025)',

  -- activity / apps / training
  activity.activity_type    AS ACTIVITY_TYPE  WITH SYNONYMS = ('jenis aktivitas') COMMENT = 'Prospecting Call, Follow Up, Client Meeting, Product Presentation, Policy Review, Referral Request or Claim Assistance',
  activity.activity_outcome AS ACTIVITY_OUTCOME WITH SYNONYMS = ('hasil aktivitas','result') COMMENT = 'Closed Won, Proposal Submitted, Interested, Follow Up Scheduled, Not Interested or No Response',
  activity.activity_date    AS ACTIVITY_DATE  WITH SYNONYMS = ('tanggal aktivitas') COMMENT = 'Date of the activity',
  activity.activity_year    AS ACTIVITY_YEAR  WITH SYNONYMS = ('tahun aktivitas') COMMENT = 'Year of the activity',
  activity.is_qualified_lead     AS IS_QUALIFIED_LEAD WITH SYNONYMS = ('qualified lead','lead berkualitas') COMMENT = 'TRUE if the activity produced a qualified lead',
  apps_behavior.event_type  AS EVENT_TYPE     WITH SYNONYMS = ('jenis event','app action') COMMENT = 'Login, View Lead List, Open Recommendation, Run Illustration, Submit e-Application and similar',
  apps_behavior.event_date  AS EVENT_DATE     WITH SYNONYMS = ('tanggal event') COMMENT = 'Date of the app event',
  apps_behavior.device      AS DEVICE         WITH SYNONYMS = ('perangkat') COMMENT = 'Android, iOS or Web',
  apps_behavior.is_recommendation_acted AS IS_RECOMMENDATION_ACTED WITH SYNONYMS = ('acted on recommendation','tindak lanjut rekomendasi') COMMENT = 'TRUE when the agent acted on an AI recommendation',
  training.course_name      AS COURSE_NAME    WITH SYNONYMS = ('nama kursus','course') COMMENT = 'Training course name',
  training.category AS CATEGORY      WITH SYNONYMS = ('kategori pelatihan') COMMENT = 'Product Knowledge, Compliance, Sales Skills, Retention, Digital Enablement or Leadership',
  training.completion_status AS COMPLETION_STATUS WITH SYNONYMS = ('status pelatihan') COMMENT = 'Completed, In Progress or Not Started',
  training.training_date    AS TRAINING_DATE  WITH SYNONYMS = ('tanggal pelatihan') COMMENT = 'Date of the training',

  -- targets and achievement
  branch_target.target_year AS TARGET_YEAR    WITH SYNONYMS = ('tahun target','plan year') COMMENT = 'Fiscal year of the plan',
  achievement.fiscal_year   AS FISCAL_YEAR    WITH SYNONYMS = ('tahun','tahun fiskal') COMMENT = 'Fiscal year 2023, 2024 or 2025',
  achievement.achievement_pct AS ACHIEVEMENT_PCT WITH SYNONYMS = ('achievement percent','persentase pencapaian','pencapaian') COMMENT = 'Achievement % for this branch-year row. Correct as-is at branch-year grain; to aggregate across branches use the achievement_rate_pct metric.',
  achievement.achievement_band      AS ACHIEVEMENT_BAND WITH SYNONYMS = ('achievement category','kategori pencapaian','performance band') COMMENT = 'Exceeding, On Target, Slightly Below, Below Target or Critically Below',
  achievement.branch_name AS BRANCH_NAME   COMMENT = 'Branch name on the achievement view',
  achievement.province  AS PROVINCE        COMMENT = 'Province on the achievement view',

  -- ML outputs
  lapse_risk.risk_segment   AS RISK_SEGMENT   WITH SYNONYMS = ('risk level','segmen risiko','risk band','risk category') COMMENT = 'LOW, MEDIUM, HIGH or CRITICAL',
  lapse_risk.is_danger_zone AS IS_DANGER_ZONE WITH SYNONYMS = ('danger zone','zona bahaya','month 13') COMMENT = 'TRUE when policy tenure is 10-14 months, the month-13 danger zone',
  lapse_risk.asof_date     AS ASOF_DATE      WITH SYNONYMS = ('scoring date','tanggal skor') COMMENT = 'Scoring as-of date',
  clv.clv_segment           AS CLV_SEGMENT    WITH SYNONYMS = ('value segment','segmen nilai','customer tier') COMMENT = 'PLATINUM, GOLD, SILVER or BRONZE quartile',
  clv.policy_count      AS POLICY_COUNT   WITH SYNONYMS = ('jumlah polis','number of policies') COMMENT = 'Number of policies the customer holds',
  cross_sell.recommended_class AS RECOMMENDED_CLASS WITH SYNONYMS = ('recommended product','produk rekomendasi','offer class') COMMENT = 'Product classification being recommended',
  cross_sell.based_on_class AS BASED_ON_CLASS WITH SYNONYMS = ('antecedent','dasar rekomendasi') COMMENT = 'Class already held that drives the recommendation',
  cross_sell.rec_rank     AS REC_RANK       WITH SYNONYMS = ('ranking rekomendasi') COMMENT = 'Recommendation rank 1-3, 1 is best',
  cross_sell.is_priority_target    AS IS_PRIORITY_TARGET WITH SYNONYMS = ('priority target','target prioritas') COMMENT = 'TRUE for single-product PLATINUM or GOLD customers',
  agent_scores.performance_category AS PERFORMANCE_CATEGORY WITH SYNONYMS = ('agent category','kategori agen') COMMENT = 'TOP_PERFORMER (>=75), SOLID (>=50), NEEDS_COACHING (>=25) or AT_RISK (<25)',
  agent_scores.rank_overall AS RANK_OVERALL   WITH SYNONYMS = ('peringkat','overall rank') COMMENT = 'Rank across all scored agents',
  agent_scores.agent_name AS AGENT_NAME  COMMENT = 'Agent name on the score table',
  anomalies.production_month   AS PRODUCTION_MONTH WITH SYNONYMS = ('bulan anomali') COMMENT = 'Month evaluated for anomalies',
  anomalies.anomaly_type    AS ANOMALY_TYPE   WITH SYNONYMS = ('jenis anomali') COMMENT = 'SPIKE, DROP or NORMAL',
  anomalies.is_anomaly AS IS_ANOMALY     WITH SYNONYMS = ('flagged') COMMENT = 'TRUE if the month is outside the 99% interval',
  anomalies.is_confirmed_anomaly    AS IS_CONFIRMED_ANOMALY WITH SYNONYMS = ('confirmed anomaly') COMMENT = 'TRUE when 2 or more consecutive months are flagged in the same direction',
  forecast.forecast_month   AS FORECAST_MONTH WITH SYNONYMS = ('bulan proyeksi','projected month') COMMENT = 'Forecast month in 2026',
  recommendations.recommendation_type  AS RECOMMENDATION_TYPE WITH SYNONYMS = ('action type','jenis rekomendasi','action category') COMMENT = 'RETENTION_CALL, RENEWAL_FOLLOW_UP, CROSS_SELL, COACHING_ACTIVITY, REACTIVATION or BRANCH_BELOW_TARGET',
  recommendations.priority AS PRIORITY    WITH SYNONYMS = ('prioritas') COMMENT = 'HIGH, MEDIUM or LOW',
  recommendations.status AS STATUS        WITH SYNONYMS = ('status rekomendasi') COMMENT = 'OPEN, ACCEPTED, DONE or DISMISSED',
  recommendations.title AS TITLE          WITH SYNONYMS = ('judul') COMMENT = 'Short action title',
  recommendations.agent_name AS AGENT_NAME  COMMENT = 'Agent the action is assigned to, NULL for branch-level actions',
  recommendations.created_by AS CREATED_BY WITH SYNONYMS = ('dibuat oleh','source') COMMENT = 'M4_RULE_ENGINE or CORTEX_AGENT'
)

METRICS (
  -- new business
  policies.total_fyap            AS SUM(policies.fyap)          WITH SYNONYMS = ('total fyap','new business premium','premi bisnis baru','sales') COMMENT = 'Total first-year annualised premium in IDR',
  policies.total_annual_premium  AS SUM(policies.annual_premium)       WITH SYNONYMS = ('total premium','total premi','annual premium') COMMENT = 'Total annual premium in IDR',
  policies.policy_count          AS COUNT(policies.POLICY_ID)          WITH SYNONYMS = ('case count','cases','new business count') COMMENT = 'Number of policies',
  policies.avg_premium           AS AVG(policies.annual_premium)       WITH SYNONYMS = ('average premium','rata-rata premi','average case size') COMMENT = 'Average annual premium in IDR',
  policies.total_sum_assured     AS SUM(policies.sum_assured)   WITH SYNONYMS = ('total sum assured','total uang pertanggungan') COMMENT = 'Total sum assured in IDR',
  policies.lapsed_policy_count    AS SUM(CASE WHEN policies.POLICY_STATUS = 'Lapsed' THEN 1 ELSE 0 END) WITH SYNONYMS = ('lapsed policies','jumlah lapse','number of lapses') COMMENT = 'Number of lapsed policies',
  policies.inforce_policy_count   AS SUM(CASE WHEN policies.POLICY_STATUS = 'Inforce' THEN 1 ELSE 0 END) WITH SYNONYMS = ('inforce policies','polis aktif','active policies') COMMENT = 'Number of in-force policies',
  policies.lapse_rate_pct         AS 100.0 * SUM(CASE WHEN policies.POLICY_STATUS = 'Lapsed' THEN 1 ELSE 0 END) / NULLIF(COUNT(policies.POLICY_ID), 0) WITH SYNONYMS = ('lapse rate','tingkat lapse','churn rate','lapse percentage') COMMENT = 'Lapsed policies as a percent of all policies',
  policies.persistency_pct        AS 100.0 * SUM(CASE WHEN policies.POLICY_STATUS <> 'Lapsed' THEN 1 ELSE 0 END) / NULLIF(COUNT(policies.POLICY_ID), 0) WITH SYNONYMS = ('persistency','persistensi','retention rate') COMMENT = 'Non-lapsed policies as a percent of all policies',

  -- premium and claims
  payments.premium_collected     AS SUM(CASE WHEN payments.FEE_STATUS = 'Payment Confirmed' THEN payments.premium_paid_amount ELSE 0 END) WITH SYNONYMS = ('collected premium','premi terkumpul','cash collected') COMMENT = 'Premium actually collected in IDR (Payment Confirmed only)',
  payments.late_payment_count    AS SUM(CASE WHEN payments.IS_LATE THEN 1 ELSE 0 END) WITH SYNONYMS = ('late payments','pembayaran terlambat') COMMENT = 'Number of late payments',
  payments.avg_days_late         AS AVG(payments.days_late)            WITH SYNONYMS = ('average days late','rata-rata keterlambatan') COMMENT = 'Average days late',
  claims.claim_count             AS COUNT(claims.CLAIM_ID)             WITH SYNONYMS = ('number of claims','jumlah klaim') COMMENT = 'Number of claims',
  claims.total_claims_paid        AS SUM(claims.approved_amount)  WITH SYNONYMS = ('claims paid','klaim dibayar','payout') COMMENT = 'Total approved and paid claims in IDR',
  claims.claim_approval_rate_pct  AS 100.0 * SUM(CASE WHEN claims.CLAIM_DECISION = 'Approved' THEN 1 ELSE 0 END) / NULLIF(COUNT(claims.CLAIM_ID), 0) WITH SYNONYMS = ('approval rate','tingkat persetujuan klaim') COMMENT = 'Approved claims as a percent of all claims',

  -- production (monthly, the source for actual FYAP by month)
  production.total_production_fyap AS SUM(production.fyap)  WITH SYNONYMS = ('monthly fyap','produksi bulanan','actual fyap','actual production') COMMENT = 'Actual FYAP from monthly production in IDR',
  production.total_new_policies   AS SUM(production.new_policies) WITH SYNONYMS = ('new policies','polis baru','cases written') COMMENT = 'New policies written',
  production.total_commission     AS SUM(production.commission_amount) WITH SYNONYMS = ('commission','komisi') COMMENT = 'First-year commission in IDR',
  production.active_agent_count   AS COUNT(DISTINCT CASE WHEN production.new_policies > 0 THEN production.AGENT_ID END) WITH SYNONYMS = ('active agents','agen aktif','producing agents') COMMENT = 'Agents who wrote at least one policy',

  -- targets and achievement (fan-out safe)
  branch_target.total_target_fyap AS SUM(branch_target.target_fyap)  WITH SYNONYMS = ('target fyap','target premi') COMMENT = 'Total branch FYAP plan in IDR',
  achievement.plan_fyap           AS SUM(achievement.target_fyap)   WITH SYNONYMS = ('plan fyap','rencana premi') COMMENT = 'Branch plan FYAP in IDR',
  achievement.total_actual_fyap   AS SUM(achievement.actual_fyap)  WITH SYNONYMS = ('actual','realisasi','realization') COMMENT = 'Branch actual FYAP in IDR',
  achievement.achievement_rate_pct AS 100.0 * SUM(achievement.actual_fyap) / NULLIF(SUM(achievement.target_fyap), 0) WITH SYNONYMS = ('attainment','percent of target','vs target','achievement rate','overall achievement') COMMENT = 'Achievement % as a ratio of sums. Use this when aggregating across MULTIPLE branches or years so percentages are never averaged.',
  achievement.fyap_gap            AS SUM(achievement.fyap_variance)     WITH SYNONYMS = ('gap','variance','selisih','shortfall') COMMENT = 'Actual minus plan in IDR, negative means behind plan',

  -- ML metrics
  lapse_risk.avg_lapse_probability AS AVG(lapse_risk.lapse_probability) WITH SYNONYMS = ('average lapse risk','rata-rata risiko lapse','mean lapse probability') COMMENT = 'Average 90-day lapse probability',
  lapse_risk.at_risk_policy_count  AS SUM(CASE WHEN lapse_risk.RISK_SEGMENT IN ('HIGH','CRITICAL') THEN 1 ELSE 0 END) WITH SYNONYMS = ('high risk policies','polis berisiko tinggi','at risk count') COMMENT = 'Policies in the HIGH or CRITICAL lapse-risk segment',
  lapse_risk.premium_at_risk       AS SUM(CASE WHEN lapse_risk.RISK_SEGMENT IN ('HIGH','CRITICAL') THEN lapse_risk.annual_premium ELSE 0 END) WITH SYNONYMS = ('premium at risk','premi berisiko','revenue at risk') COMMENT = 'Annual premium exposed to HIGH or CRITICAL lapse risk in IDR',
  clv.total_clv                    AS SUM(clv.clv)              WITH SYNONYMS = ('total lifetime value','total nilai nasabah') COMMENT = 'Total customer lifetime value in IDR',
  clv.avg_clv                      AS AVG(clv.clv)              WITH SYNONYMS = ('average clv','rata-rata clv') COMMENT = 'Average customer lifetime value in IDR',
  clv.customer_count               AS COUNT(clv.CUSTOMER_ID)           WITH SYNONYMS = ('number of customers','jumlah nasabah') COMMENT = 'Number of scored customers',
  cross_sell.avg_lift              AS AVG(cross_sell.best_lift)          WITH SYNONYMS = ('average lift','rata-rata lift') COMMENT = 'Average association-rule lift',
  cross_sell.cross_sell_pipeline   AS SUM(cross_sell.expected_annual_premium) WITH SYNONYMS = ('cross sell pipeline','potensi cross sell','opportunity value') COMMENT = 'Expected annual premium from cross-sell offers in IDR',
  agent_scores.avg_composite_score AS AVG(agent_scores.composite_score)      WITH SYNONYMS = ('average agent score','rata-rata skor agen') COMMENT = 'Average composite agent score',
  agent_scores.agent_count         AS COUNT(agent_scores.AGENT_ID)     WITH SYNONYMS = ('number of agents','jumlah agen','scored agents') COMMENT = 'Number of scored INFORCE agents',
  agent_scores.top_performer_count AS SUM(CASE WHEN agent_scores.PERFORMANCE_CATEGORY = 'TOP_PERFORMER' THEN 1 ELSE 0 END) WITH SYNONYMS = ('top performers','agen terbaik') COMMENT = 'Agents scoring 75 or above',
  anomalies.anomaly_count          AS SUM(CASE WHEN anomalies.IS_ANOMALY THEN 1 ELSE 0 END) WITH SYNONYMS = ('number of anomalies','jumlah anomali') COMMENT = 'Number of flagged anomalous months',
  forecast.total_forecast_fyap     AS SUM(forecast.forecast_fyap)    WITH SYNONYMS = ('forecast fyap','proyeksi premi','predicted fyap') COMMENT = 'Forecast FYAP in IDR',
  recommendations.recommendation_count AS COUNT(recommendations.RECOMMENDATION_ID) WITH SYNONYMS = ('number of recommendations','jumlah rekomendasi','actions') COMMENT = 'Number of recommendations',
  recommendations.avg_urgency      AS AVG(recommendations.urgency_score)     WITH SYNONYMS = ('average urgency','rata-rata urgensi') COMMENT = 'Average urgency score',
  recommendations.total_pipeline_value AS SUM(recommendations.expected_value) WITH SYNONYMS = ('pipeline value','nilai pipeline') COMMENT = 'Total expected value of the action queue in IDR'
)

COMMENT = 'Meridian Life (fictional) sales intelligence. 14 foundation tables plus 7 ML model outputs. All data synthetic. Currency is Indonesian Rupiah (IDR). Fiscal years 2023-2025; forecasts cover 2026.'

AI_SQL_GENERATION
'CRITICAL RULES FOR THIS MODEL:
1. ACHIEVEMENT: always use the achievement logical table (V_BRANCH_ACHIEVEMENT). For a single branch-year row use the achievement_pct dimension; when aggregating across several branches or years use the achievement_rate_pct metric so percentages are never averaged. NEVER join branch_target to production or policies to compute achievement - that fans out the target across production rows and inflates the result. Targets exist ONLY at branch level.
2. NO PER-AGENT TARGET: this model has no agent-level target or quota. If asked for an agent achievement percentage, explain that targets are set at branch level only and offer the M3 composite agent score (agent_scores) instead, which is behaviour-based.
3. COLLECTED PREMIUM: premium actually collected means payments where FEE_STATUS = ''Payment Confirmed''. Pending and Failed are NOT collected.
4. CLAIM VALUE: use APPROVED_AMOUNT for money actually paid out. CLAIM_AMOUNT is only the amount filed. CLAIM_DECISION values are ''Approved'' and ''Rejected''.
5. ACTIVE AGENTS: an active agent is DIM_AGENT.AGENT_STATUS = ''INFORCE''. Do not count APPLICANT or TERMINATED agents as active.
6. ACTUAL FYAP BY MONTH: use the production table (FACT_AGENT_PRODUCTION), which reconciles exactly with FACT_POLICY. Use policies.issue_date when the question is about individual policies or new business detail.
7. CURRENT PERIOD: the data ends 2025-12-31. Treat 2025 as the current/latest fiscal year and 2026 as the forecast period. When a question says ''this year'' assume 2025.
8. CURRENCY: all monetary values are Indonesian Rupiah. Never label them as US dollars.
9. LAPSE DANGER ZONE: the month-13 policy anniversary is the known lapse spike. POLICY_MONTH_AT_LAPSE = 13 identifies it historically; lapse_risk.IS_DANGER_ZONE identifies policies approaching it now.
10. RANKING QUESTIONS: for lowest or highest questions always ORDER BY the metric and apply LIMIT, and include the branch or agent NAME in the output, not just the ID.'

AI_QUESTION_CATEGORIZATION
'Classify questions into: (a) PERFORMANCE - target versus actual, achievement, production, ranking of branches or agents; (b) RISK - lapse, persistency, churn, danger zone, premium at risk; (c) CUSTOMER - CLV, segments, cross-sell, demographics; (d) CLAIMS - claim counts, ratios, approval rates; (e) FORECAST - future revenue, projections, anomalies; (f) ACTION - the recommendation and Next-Best-Action queue. Questions about product wording, benefits, exclusions, waiting periods or premium illustrations are NOT answerable from this semantic view and should be routed to the product document search tool instead.'

AI_VERIFIED_QUERIES (

  lowest_achievement_in_province AS (
    QUESTION 'Which branch has the lowest achievement in East Java in 2025?'
    ONBOARDING_QUESTION TRUE
    SQL 'SELECT BRANCH_NAME, PROVINCE, TARGET_FYAP, ACTUAL_FYAP, ACHIEVEMENT_PCT, ACHIEVEMENT_BAND
         FROM INSURANCE_DEMO.CORE.V_BRANCH_ACHIEVEMENT
         WHERE FISCAL_YEAR = 2025 AND PROVINCE = ''East Java''
         ORDER BY ACHIEVEMENT_PCT ASC
         LIMIT 1'
  ),

  branches_below_target AS (
    QUESTION 'Which branches are below target in 2025?'
    ONBOARDING_QUESTION TRUE
    SQL 'SELECT BRANCH_NAME, PROVINCE, TARGET_FYAP, ACTUAL_FYAP, FYAP_VARIANCE, ACHIEVEMENT_PCT, ACHIEVEMENT_BAND
         FROM INSURANCE_DEMO.CORE.V_BRANCH_ACHIEVEMENT
         WHERE FISCAL_YEAR = 2025 AND ACHIEVEMENT_PCT < 100
         ORDER BY ACHIEVEMENT_PCT ASC'
  ),

  company_achievement_by_year AS (
    QUESTION 'What is the company wide achievement against plan for each year?'
    SQL 'SELECT FISCAL_YEAR,
                SUM(TARGET_FYAP) AS TARGET_FYAP,
                SUM(ACTUAL_FYAP) AS ACTUAL_FYAP,
                ROUND(100.0 * SUM(ACTUAL_FYAP) / NULLIF(SUM(TARGET_FYAP), 0), 2) AS ACHIEVEMENT_PCT
         FROM INSURANCE_DEMO.CORE.V_BRANCH_ACHIEVEMENT
         GROUP BY FISCAL_YEAR
         ORDER BY FISCAL_YEAR'
  ),

  high_risk_policies AS (
    QUESTION 'Show the top 20 policies with the highest lapse risk and who services them'
    ONBOARDING_QUESTION TRUE
    SQL 'SELECT l.POLICY_ID, c.CUSTOMER_NAME, a.AGENT_NAME, b.BRANCH_NAME,
                l.LAPSE_PROBABILITY, l.RISK_SEGMENT, l.TENURE_MONTHS, l.IS_DANGER_ZONE,
                l.ANNUAL_PREMIUM, v.CLV_SEGMENT
         FROM INSURANCE_DEMO.CORE.LAPSE_RISK_SCORES l
         JOIN INSURANCE_DEMO.CORE.DIM_CUSTOMER c ON c.CUSTOMER_ID = l.CUSTOMER_ID
         JOIN INSURANCE_DEMO.CORE.DIM_AGENT    a ON a.AGENT_ID    = l.AGENT_ID
         JOIN INSURANCE_DEMO.CORE.DIM_BRANCH   b ON b.BRANCH_ID   = l.BRANCH_ID
         LEFT JOIN INSURANCE_DEMO.CORE.CUSTOMER_CLV_SCORES v ON v.CUSTOMER_ID = l.CUSTOMER_ID
         ORDER BY l.LAPSE_PROBABILITY DESC
         LIMIT 20'
  ),

  single_product_high_value_customers AS (
    QUESTION 'Which high value customers only hold one product and what should we offer them?'
    SQL 'SELECT x.CUSTOMER_ID, x.CUSTOMER_NAME, x.PROVINCE, x.CLV_SEGMENT, x.CLV,
                x.RECOMMENDED_CLASS, x.BASED_ON_CLASS, x.BEST_LIFT, x.EXPECTED_ANNUAL_PREMIUM
         FROM INSURANCE_DEMO.CORE.CROSS_SELL_RECOMMENDATIONS x
         WHERE x.REC_RANK = 1
           AND x.CURRENT_POLICY_COUNT = 1
           AND x.CLV_SEGMENT IN (''PLATINUM'',''GOLD'')
         ORDER BY x.CLV DESC
         LIMIT 50'
  ),

  claims_ratio_by_product_class AS (
    QUESTION 'What is the claims ratio by product classification?'
    SQL 'WITH prem AS (
             SELECT d.CLASSIFICATION, SUM(y.PREMIUM_PAID_AMOUNT) AS PREMIUM_COLLECTED
             FROM INSURANCE_DEMO.CORE.FACT_POLICY_PAYMENT y
             JOIN INSURANCE_DEMO.CORE.FACT_POLICY p ON p.POLICY_ID = y.POLICY_ID
             JOIN INSURANCE_DEMO.CORE.DIM_PRODUCT d ON d.PRODUCT_ID = p.PRODUCT_ID
             WHERE y.FEE_STATUS = ''Payment Confirmed''
             GROUP BY d.CLASSIFICATION
         ), clm AS (
             SELECT d.CLASSIFICATION, SUM(c.APPROVED_AMOUNT) AS CLAIMS_PAID, COUNT(*) AS CLAIM_COUNT
             FROM INSURANCE_DEMO.CORE.FACT_CLAIMS c
             JOIN INSURANCE_DEMO.CORE.FACT_POLICY p ON p.POLICY_ID = c.POLICY_ID
             JOIN INSURANCE_DEMO.CORE.DIM_PRODUCT d ON d.PRODUCT_ID = p.PRODUCT_ID
             GROUP BY d.CLASSIFICATION
         )
         SELECT pr.CLASSIFICATION, pr.PREMIUM_COLLECTED,
                COALESCE(cl.CLAIMS_PAID, 0) AS CLAIMS_PAID,
                COALESCE(cl.CLAIM_COUNT, 0) AS CLAIM_COUNT,
                ROUND(100.0 * COALESCE(cl.CLAIMS_PAID, 0) / NULLIF(pr.PREMIUM_COLLECTED, 0), 2) AS CLAIMS_RATIO_PCT
         FROM prem pr LEFT JOIN clm cl ON cl.CLASSIFICATION = pr.CLASSIFICATION
         ORDER BY CLAIMS_RATIO_PCT DESC'
  ),

  forecast_vs_plan AS (
    QUESTION 'Which branches are forecast to miss plan in 2026?'
    SQL 'SELECT BRANCH_NAME, PROVINCE, FORECAST_MONTH, FORECAST_FYAP,
                LOWER_BOUND_95, UPPER_BOUND_95, MONTHLY_PLAN_FYAP, FORECAST_ACHIEVEMENT_PCT
         FROM INSURANCE_DEMO.CORE.V_FORECAST_VS_PLAN
         WHERE AT_RISK_VS_PLAN
         ORDER BY FORECAST_ACHIEVEMENT_PCT ASC, FORECAST_MONTH'
  ),

  lapse_by_payment_frequency AS (
    QUESTION 'Does lapse rate differ by payment frequency?'
    SQL 'SELECT PAYMENT_FREQUENCY,
                COUNT(*) AS POLICIES,
                SUM(CASE WHEN POLICY_STATUS = ''Lapsed'' THEN 1 ELSE 0 END) AS LAPSED,
                ROUND(100.0 * SUM(CASE WHEN POLICY_STATUS = ''Lapsed'' THEN 1 ELSE 0 END) / COUNT(*), 2) AS LAPSE_RATE_PCT
         FROM INSURANCE_DEMO.CORE.FACT_POLICY
         GROUP BY PAYMENT_FREQUENCY
         ORDER BY LAPSE_RATE_PCT DESC'
  ),

  month_13_danger_zone AS (
    QUESTION 'When do policies lapse relative to their issue date?'
    SQL 'SELECT POLICY_MONTH_AT_LAPSE AS POLICY_MONTH,
                COUNT(*) AS LAPSES
         FROM INSURANCE_DEMO.CORE.FACT_POLICY
         WHERE POLICY_STATUS = ''Lapsed''
         GROUP BY POLICY_MONTH_AT_LAPSE
         ORDER BY LAPSES DESC
         LIMIT 10'
  ),

  agent_leaderboard AS (
    QUESTION 'Who are the top 10 agents by composite performance score?'
    ONBOARDING_QUESTION TRUE
    SQL 'SELECT AGENT_NAME, BRANCH_NAME, AGENT_LEVEL, COMPOSITE_SCORE,
                PRODUCTION_SCORE, ACTIVITY_SCORE, TRAINING_SCORE, RETENTION_SCORE,
                PERFORMANCE_CATEGORY, FYAP_12M
         FROM INSURANCE_DEMO.CORE.AGENT_PERFORMANCE_SCORES
         ORDER BY COMPOSITE_SCORE DESC
         LIMIT 10'
  ),

  action_queue_top AS (
    QUESTION 'What are the most urgent actions in the queue right now?'
    SQL 'SELECT RECOMMENDATION_TYPE, PRIORITY, URGENCY_SCORE, AGENT_NAME, BRANCH_NAME,
                CUSTOMER_NAME, POLICY_ID, TITLE, EXPECTED_VALUE
         FROM INSURANCE_DEMO.CORE.AI_RECOMMENDATIONS
         WHERE STATUS = ''OPEN''
         ORDER BY URGENCY_SCORE DESC
         LIMIT 25'
  ),

  production_anomalies AS (
    QUESTION 'Which branches had unusual production in the second half of 2025?'
    SQL 'SELECT BRANCH_NAME, PROVINCE, PRODUCTION_MONTH, ANOMALY_TYPE,
                ACTUAL_ROLLING3_FYAP, EXPECTED_FYAP, PCT_DEVIATION
         FROM INSURANCE_DEMO.CORE.V_PRODUCTION_ANOMALY_ALERTS
         ORDER BY ABS(PCT_DEVIATION) DESC'
  )
);

SHOW SEMANTIC VIEWS LIKE 'MERIDIAN_SALES_INTELLIGENCE' IN SCHEMA INSURANCE_DEMO.CORE;
