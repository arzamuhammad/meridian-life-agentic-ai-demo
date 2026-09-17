# Data Dictionary — Meridian Life Insurance Demo

All data is 100% synthetic. No real PII. Currency: Indonesian Rupiah (IDR).
Date range: 2023-01-01 to 2025-12-31. Forecasts cover 2026.

## Dimension Tables

### DIM_BRANCH (23 rows)
| Column | Type | Description |
|--------|------|-------------|
| BRANCH_ID | VARCHAR(10) | PK. B01-B23 |
| BRANCH_CODE | VARCHAR(10) | 3-letter code (JKS, SBY, MDN...) |
| BRANCH_NAME | VARCHAR(80) | Full name e.g. "Jakarta Selatan Flagship" |
| CITY | VARCHAR(60) | City |
| PROVINCE | VARCHAR(60) | Province (East Java, DKI Jakarta, West Java...) |
| REGION | VARCHAR(60) | Sales region (Jabodetabek, West Java, East Java, Sumatra...) |
| BRANCH_TYPE | VARCHAR(30) | Flagship, Main, or Satellite |
| OPEN_DATE | DATE | Branch opening date |
| BRANCH_MANAGER | VARCHAR(80) | Fictional manager name |
| ADDRESS_LINE | VARCHAR(180) | Fictional address |

### DIM_AGENT (1,500 rows)
| Column | Type | Description |
|--------|------|-------------|
| AGENT_ID | VARCHAR(10) | PK. A00001-A01500 |
| AGENT_NAME | VARCHAR(80) | Fictional Indonesian name |
| GENDER | VARCHAR(1) | M or F |
| BRANCH_ID | VARCHAR(10) | FK -> DIM_BRANCH |
| AGENT_STATUS | VARCHAR(20) | **INFORCE** (active), APPLICANT, TERMINATED |
| AGENT_LEVEL | VARCHAR(20) | Agent, Senior Agent, Unit Manager, Agency Manager, Agency Director |
| JOIN_DATE | DATE | Date joined |
| TERMINATION_DATE | DATE | NULL if still active |
| LICENSE_NUMBER | VARCHAR(20) | Fictional license |
| CERTIFICATION | VARCHAR(20) | AAJI or AAJI + AASI |
| GEN_PRODUCTIVITY | FLOAT | Generation control (Pareto skewed) — not a business metric |
| GEN_ACTIVITY_RATE | FLOAT | Generation control — not a business metric |
| LEADER_ID | VARCHAR(10) | FK -> DIM_AGENT (self-ref to a manager in the same branch) |

### DIM_CUSTOMER (4,400 rows)
| Column | Type | Description |
|--------|------|-------------|
| CUSTOMER_ID | VARCHAR(10) | PK. C000001-C004400 |
| CUSTOMER_NAME | VARCHAR(120) | Fictional name |
| GENDER | VARCHAR(1) | M or F |
| BIRTH_DATE | DATE | |
| AGE | INT | Age in years |
| AGE_BAND | VARCHAR(10) | 20-29, 30-39, 40-49, 50-59, 60+ |
| CITY, PROVINCE, REGION | VARCHAR | Geography (aligned with first-policy branch) |
| OCCUPATION | VARCHAR(30) | Private Employee, Entrepreneur, Civil Servant... |
| INCOME_BAND | VARCHAR(30) | Below Rp 10M/month ... Above Rp 100M/month |
| MARITAL_STATUS | VARCHAR(20) | Married, Single, Divorced / Widowed |
| EDUCATION | VARCHAR(20) | High School, Diploma, Bachelor, Master or above |
| ACQUISITION_DATE | DATE | |
| EMAIL | VARCHAR | Dummy @example.invalid |
| PHONE_MASKED | VARCHAR | Masked phone |
| CONSENT_MARKETING | BOOLEAN | |

### DIM_PRODUCT (70 rows)
| Column | Type | Description |
|--------|------|-------------|
| PRODUCT_ID | VARCHAR(10) | PK. P001-P070 |
| PRODUCT_CODE | VARCHAR(20) | MRD-Xxxx-nnn |
| PRODUCT_NAME | VARCHAR(80) | e.g. "Meridian Sehat Gold" |
| CLASSIFICATION | VARCHAR(40) | **Health, Life, Unit Link, Savings, Critical Illness, Accident, Education, Retirement** |
| PRODUCT_TYPE | VARCHAR(20) | Traditional, Unit Linked, or Syariah |
| PRODUCT_TIER | INT | 1 (Entry), 2 (Core), 3 (Premium) |
| TIER_LABEL | VARCHAR(10) | Entry, Core, Premium |
| MIN_ANNUAL_PREMIUM | NUMBER(18,2) | Minimum annual premium IDR |
| PREMIUM_FACTOR | FLOAT | Relative pricing multiplier |
| LAUNCH_DATE | DATE | |
| IS_ACTIVE | BOOLEAN | |
| DISTRIBUTION_CHANNEL | VARCHAR(30) | Agency, Agency + Bancassurance, Agency + Digital |
| DEFAULT_TERM_YEARS | INT | Standard contract term |

## Fact Tables

### FACT_POLICY (7,400 rows)
Core table. One row per policy sold.
| Column | Type | Key values |
|--------|------|------------|
| POLICY_ID | VARCHAR(20) | PK. POL000001-POL007400 |
| POLICY_STATUS | VARCHAR(20) | **Inforce**, **Lapsed**, **Terminated** |
| ANNUAL_PREMIUM | NUMBER(18,2) | Right-skewed (median Rp 5.3M, p99 Rp 32.6M) |
| FYAP | NUMBER(18,2) | First-year annualised premium |
| PAYMENT_MODE | VARCHAR(10) | Regular or Single |
| PAYMENT_FREQUENCY | VARCHAR(15) | Monthly, Quarterly, Semi-Annual, Yearly, Single |
| LAPSE_DATE | DATE | NULL if not lapsed |
| POLICY_MONTH_AT_LAPSE | INT | Month 13 = danger zone |
| ISSUE_DATE, ISSUE_MONTH, ISSUE_YEAR | DATE/INT | |

### FACT_POLICY_PAYMENT (~44,500 rows)
| Column | Key values |
|--------|------------|
| FEE_STATUS | **Payment Confirmed** (collected), Pending, Failed |
| COLLECTION_PAYMENT_DATE | NULL if not confirmed |
| DAYS_LATE | Days between due date and actual collection |
| IS_LATE | TRUE if > 5 days late |

### FACT_CLAIMS (~2,200 rows)
| Column | Key values |
|--------|------------|
| CLAIM_DECISION | **Approved**, **Rejected** |
| APPROVED_AMOUNT | Amount actually paid (use this, not CLAIM_AMOUNT) |
| CLAIM_TYPE | Inpatient, Outpatient, Surgery, Critical Illness, Accident, Death, Disability, Maternity |

### FACT_BRANCH_TARGET (66 rows)
Branch-level ONLY. No per-agent target exists.
| Column | Description |
|--------|-------------|
| TARGET_FYAP | Annual FYAP plan IDR |
| TARGET_YEAR | 2023, 2024, or 2025 |

### Other Facts
| Table | Rows | Grain |
|-------|------|-------|
| FACT_POLICY_RIDER | ~11,000 | One row per rider attached to a policy |
| FACT_AGENT_PRODUCTION | ~12,400 | Monthly per agent (reconciles exactly with FACT_POLICY) |
| FACT_AGENT_ACTIVITY | 100,000 | Individual sales activities |
| FACT_AGENT_APPS_BEHAVIOR | 100,000 | Mobile app telemetry events |
| FACT_TRAINING | ~3,500 | Agent training records |
| FACT_CRM_TICKETS | ~2,450 | Service tickets (55% retention-related) |

## ML Output Tables

| Table | Model | Key columns |
|-------|-------|-------------|
| LAPSE_RISK_SCORES | M1 XGBoost (90-day PIT) | LAPSE_PROBABILITY, RISK_SEGMENT (LOW/MEDIUM/HIGH/CRITICAL), IS_DANGER_ZONE |
| REVENUE_FORECAST_RESULTS | M2 ML.FORECAST | FORECAST_FYAP, LOWER_BOUND_95, UPPER_BOUND_95 |
| AGENT_PERFORMANCE_SCORES | M3 Composite | COMPOSITE_SCORE (0-100), PERFORMANCE_CATEGORY |
| AI_RECOMMENDATIONS | M4 Rule engine | URGENCY_SCORE (0-100), RECOMMENDATION_TYPE, STATUS |
| CUSTOMER_CLV_SCORES | M5 Actuarial DCF | CLV, CLV_SEGMENT (PLATINUM/GOLD/SILVER/BRONZE), RETENTION_RATE |
| PRODUCTION_ANOMALIES | M6 ML.ANOMALY_DETECTION | IS_ANOMALY, ANOMALY_TYPE (SPIKE/DROP/NORMAL), PCT_DEVIATION |
| CROSS_SELL_RECOMMENDATIONS | M7 Association rules | RECOMMENDED_CLASS, BEST_LIFT, IS_PRIORITY_TARGET |

## Closed Loop Tables

| Table | Description |
|-------|-------------|
| RECOMMENDATION_FEEDBACK | Human decision on a recommendation (ACCEPTED/REJECTED/DEFERRED) |
| RECOMMENDATION_OUTCOME | Business outcome (RETAINED/LAPSED_ANYWAY/SOLD/DECLINED/NO_CONTACT/IN_PROGRESS) |

## Key Views

| View | Purpose |
|------|---------|
| V_BRANCH_ACHIEVEMENT | **THE** source of achievement %. Anti-fan-out. |
| V_MONTHLY_REVENUE_BY_BRANCH | M2 input (series + timestamp + target only) |
| V_DASHBOARD_KPIS | Headline KPIs per fiscal year |
| V_BRANCH_VARIANCE | Monthly variance + MoM/YoY |
| V_WEEKLY_PLAN_VS_ACTUAL | Weekly plan vs actual |
| V_BRANCH_PRODUCTION_YEARLY | Annual production per branch |
| V_FORECAST_VS_PLAN | Forecast vs monthly plan |
| V_PRODUCTION_ANOMALY_ALERTS | Anomalies only, with branch context |
| V_RECOMMENDATION_LOOP | Full loop: recommendation + feedback + outcome |
| V_MODEL_EFFECTIVENESS | Win rate and value realisation by action type |
| BRANCH_NBA_CONTEXT | 2025 achievement + latest anomaly (agent reads this) |
