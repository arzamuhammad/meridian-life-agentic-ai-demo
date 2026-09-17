# Meridian Life — Sales Agentic AI Demo on Snowflake

A complete, reproducible demo of **agentic AI for life-insurance sales**, built entirely inside
Snowflake. You run a sequence of scripts and end up with synthetic data, seven machine-learning
models, a Cortex Agent that answers business questions in natural language, and a seven-page
Streamlit dashboard.

**Meridian Life is a fictional company. All data is 100% synthetic. There is no real PII.**
Currency is Indonesian Rupiah (IDR); all labels are in English.

> **New to Snowflake or to insurance?** This README assumes neither. Every step tells you what
> to run, what you should see, and how to check that it worked. If a step fails, the
> [Troubleshooting](#troubleshooting) section covers the failures we actually hit while
> building it.
>
> **Prefer Indonesian?** See [README-IND.md](./README-IND.md).

---

## Table of Contents

1. [What You Get](#1-what-you-get)
2. [What This Demo Answers](#2-what-this-demo-answers)
3. [Prerequisites](#3-prerequisites)
4. [Step 0 — Connect to Snowflake](#step-0--connect-to-snowflake)
5. [Step 1 — Setup and Synthetic Data](#step-1--setup-and-synthetic-data)
6. [Step 2 — Machine Learning Models](#step-2--machine-learning-models)
7. [Step 3 — Product Documents and Cortex Search](#step-3--product-documents-and-cortex-search)
8. [Step 4 — Semantic View](#step-4--semantic-view)
9. [Step 5 — Cortex Agent](#step-5--cortex-agent)
10. [Step 6 — Streamlit Dashboard](#step-6--streamlit-dashboard)
11. [Step 7 — Closed Loop](#step-7--closed-loop)
12. [Using the Demo](#using-the-demo)
13. [Architecture and Design Decisions](#architecture-and-design-decisions)
14. [Troubleshooting](#troubleshooting)
15. [Cost and Teardown](#cost-and-teardown)
16. [Repository Structure](#repository-structure)

---

## 1. What You Get

After roughly **30 minutes of runtime** (mostly waiting), your Snowflake account contains:

| Component | Detail |
|-----------|--------|
| **Synthetic data** | 14 tables, ~300k rows: 23 branches, 1,500 agents, 4,400 customers, 70 products, 7,400 policies |
| **7 ML models** | Lapse prediction (XGBoost), revenue forecast, agent scoring, next-best-action, customer lifetime value, anomaly detection, cross-sell rules |
| **24 product brochures** | AI-generated text → branded PDFs → parsed → chunked → searchable |
| **Cortex Search** | `MERIDIAN_PRODUCT_SEARCH`, 164 chunks over 24 products |
| **Semantic View** | `MERIDIAN_SALES_INTELLIGENCE`: 22 tables, 40 metrics, 12 verified queries |
| **Cortex Agent** | `MERIDIAN_COMMAND_CENTER_AGENT`, 15 tools including web search and PPTX generation |
| **Streamlit app** | `MERIDIAN_COMMAND_CENTER_DASHBOARD`, 7 pages |
| **Closed loop** | Recommendation feedback and outcome tables, so model effectiveness is measurable |

Headline numbers from the generated book: **Rp 49.5 billion** first-year annualised premium,
**17 of 23 branches below plan** in 2025, worst branch Jember at **44.0%** of target,
**6,002 policies scored** for lapse risk.

---

## 2. What This Demo Answers

If you are not from insurance, here is the business problem in plain terms.

A life insurer sells policies through **agents** who work out of **branches**. Head office sets a
revenue **target** per branch. Every month, leadership asks four questions:

1. **Are we on plan?** Which branches are behind target, and by how much?
2. **Why are we behind?** Is it too few agents, the wrong product mix, or customers leaving?
3. **Who is about to leave?** A policy that stops being paid is called a **lapse**. Predicting
   lapses lets you call the customer before it happens.
4. **What do we do today?** Not a report — a list of named actions for named people.

A traditional dashboard answers question 1 only. This demo answers all four, and closes the
loop by recording whether the recommended action actually worked.

**Insurance terms used in this repo:**

| Term | Meaning |
|------|---------|
| **FYAP / FYP** | First-Year Annualised Premium. The industry's headline sales number |
| **Lapse** | Customer stops paying; the policy dies. The main revenue leak |
| **Persistency** | Percentage of policies still being paid after N months |
| **Grace period** | Days after a missed payment before the policy lapses |
| **Rider** | Optional add-on cover attached to a base policy |
| **NBA** | Next Best Action — the single most valuable thing an agent should do next |
| **CLV** | Customer Lifetime Value — expected total value of a customer |
| **Cross-sell** | Selling an additional product to an existing customer |
| **Activation rate** | Percentage of agents who actually sold something in a period |

---

## 3. Prerequisites

### 3.1 Snowflake account

- Any Snowflake account on **Enterprise edition or higher** with **Cortex AI enabled**
- The **ACCOUNTADMIN** role (the scripts create databases, warehouses and agents)
- Roughly **2 GB** of storage and a few credits of compute

### 3.2 Cross-region inference — REQUIRED

**This is the single most common reason the build fails.** Snowflake Cortex does not host every
model in every region. This demo uses `claude-4-sonnet`, the `arctic-embed-l-v2.0` embedding
model, and `AI_PARSE_DOCUMENT`. In many regions — including **AWS Asia Pacific (Jakarta),
`ap-southeast-3`** — some of these are not available locally, and every AI call fails with an
error like:

```
unknown model "claude-4-sonnet"
```

Enable cross-region inference **before you start**:

```sql
USE ROLE ACCOUNTADMIN;

ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';

-- Verify: VALUE must read ANY_REGION, not DISABLED
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;
```

Then confirm the model actually answers:

```sql
SELECT SNOWFLAKE.CORTEX.COMPLETE('claude-4-sonnet', 'Reply with the single word OK');
```

If that returns `OK`, you are ready. If it errors, do not continue — every AI step will fail.

> **What this setting does, and why you should tell your security team.** With
> `ANY_REGION`, a Cortex request that cannot be served in your region is processed in another
> region. The inference is stateless and Snowflake does not retain your prompt for training,
> but the request does leave your region. Some organisations restrict this to a specific region
> instead of `ANY_REGION` — for example `'AWS_US'`. Check what your data-residency policy
> allows before enabling it in a production account. For a demo account, `ANY_REGION` is fine.

### 3.3 Local tooling

| Tool | Why | Install |
|------|-----|---------|
| **Snowflake CLI** (`snow`) | Runs every `.sql` script | `pip install snowflake-cli` |
| **Python 3.11** | Two steps need Python (XGBoost training, PDF rendering) | conda or pyenv |

Python packages:

```bash
# A dedicated environment is strongly recommended
conda create -n meridian python=3.11 -y
conda activate meridian

pip install "snowflake-connector-python[pandas]" \
            xgboost==1.7.3 scikit-learn pandas numpy reportlab
```

Verify:

```bash
snow --version
python -c "import xgboost, sklearn, pandas, reportlab, snowflake.connector; print('deps ok')"
```

### 3.4 Optional: web search for the agent

One of the agent's 15 tools is web search, used to compare the synthetic book against public
industry benchmarks. If your account does not have it enabled, the other 14 tools still work.

Enable it in Snowsight: **AI & ML → Agents → Settings → Web access**.

---

## Step 0 — Connect to Snowflake

Create a named connection so you never type credentials into a script. The CLI stores this in
`~/.snowflake/connections.toml`, which is **outside this repository** — nothing secret ever
enters the repo.

```bash
snow connection add
```

Answer the prompts. A minimal working entry looks like this:

```toml
[meridian]
account   = "MYORG-MYACCOUNT"
user      = "MY_USER"
role      = "ACCOUNTADMIN"
warehouse = "GEN2_SMALL"
database  = "INSURANCE_DEMO"
schema    = "CORE"
authenticator = "externalbrowser"   # SSO. Or use a key pair / PAT.
```

Test it:

```bash
snow connection test -c meridian
```

From here on, replace `meridian` with your own connection name. Two Python scripts read the
connection from an environment variable:

```bash
export SNOWFLAKE_CONNECTION_NAME=meridian
```

> **Never** commit `connections.toml`, a private key, or a personal access token. The included
> `.gitignore` blocks the usual suspects, but the safest habit is to keep credentials in the
> CLI config only.

**Run every command below from the repository root**, because the Streamlit deploy step uses
paths relative to it.

---

## Step 1 — Setup and Synthetic Data

Creates the warehouse, database, schema, stages, and all 14 data tables.

```bash
snow sql -c meridian -f 01_setup/01_setup.sql
snow sql -c meridian -f 02_generate_data/20_gen_helpers.sql
snow sql -c meridian -f 02_generate_data/21_dimensions.sql
snow sql -c meridian -f 02_generate_data/22_fact_policy.sql
snow sql -c meridian -f 02_generate_data/23_fact_policy_children.sql
snow sql -c meridian -f 02_generate_data/24_fact_agent.sql
snow sql -c meridian -f 02_generate_data/25_fact_target_crm.sql
snow sql -c meridian -f 02_generate_data/26_helper_views.sql
```

**Runtime**: about 4 minutes total.

### Why the data is deterministic

The generator never calls `RANDOM()`. It uses hash-based user-defined functions —
`RND(key, salt)`, `RNDI(...)`, `RNDN(...)` — keyed on each row's business key. Run it ten times
and you get byte-identical data. This matters because the ML models, the semantic view's
verified queries, and the demo script all reference specific numbers.

### Checkpoint 1 — verify before continuing

```bash
snow sql -c meridian -f 02_generate_data/27_verify_stop1.sql
```

Expected row counts:

| Table | Rows |
|-------|------|
| DIM_BRANCH | 23 |
| DIM_AGENT | 1,500 |
| DIM_CUSTOMER | 4,400 |
| DIM_PRODUCT | 70 |
| FACT_POLICY | 7,400 |
| FACT_POLICY_PAYMENT | 44,522 |
| FACT_POLICY_RIDER | 11,046 |
| FACT_CLAIMS | 2,176 |
| FACT_AGENT_PRODUCTION | 12,420 |
| FACT_AGENT_ACTIVITY | 100,000 |
| FACT_AGENT_APPS_BEHAVIOR | 100,000 |
| FACT_TRAINING | 3,454 |
| FACT_BRANCH_TARGET | 66 |
| FACT_CRM_TICKETS | 2,453 |

All foreign-key integrity checks must return **0 orphans**. If any count is far off or a check
returns rows, stop and re-run from `21_dimensions.sql` — the later steps depend on this data
being exact.

### Patterns deliberately planted in the data

These are what the models later "discover". Knowing them helps you verify the models are
genuinely working rather than guessing.

| Pattern | What it looks like |
|---------|--------------------|
| Month-13 lapse spike | Hazard 9.59% at month 13 = **12.6× baseline**; month 25 = 3.69% = 4.9× |
| Payment frequency drives lapse | Yearly 4.87% < Semi-annual 8.64% < Quarterly 12.23% < Monthly 15.05% |
| Branch achievement spread | Jember 44.0% (worst) to Surabaya 131.0% (best) |
| Cross-sell affinity | Savings → Retirement lift 2.98; UnitLink → Education 1.58 |
| Production shocks | 3 spikes and 3 drops planted across specific branch-months |
| Service correlates with risk | 55.4% of CRM tickets sit on lapse-risk policies |

> **Important on lapse counts.** Raw lapse *counts* understate the month-25 spike because of
> right-censoring — policies simply have not reached month 25 yet. Always use the **hazard**
> (lapses ÷ policies at risk), which is what the panel in Step 2 computes.

---

## Step 2 — Machine Learning Models

Seven models. Only the first one needs Python; the rest are SQL, using Snowflake's built-in ML
functions.

```bash
# M1 — lapse prediction (point-in-time panel, then XGBoost)
snow sql -c meridian -f 03_ml/31_m1_lapse_panel.sql
python 03_ml/32_m1_train_xgboost.py

# M2, M6 — Snowflake built-in forecasting and anomaly detection
snow sql -c meridian -f 03_ml/33_m2_revenue_forecast.sql
snow sql -c meridian -f 03_ml/34_m6_anomaly_detection.sql

# M3, M5, M7, M4 — must run in this order
snow sql -c meridian -f 03_ml/35_m3_agent_scoring.sql
snow sql -c meridian -f 03_ml/36_m5_customer_clv.sql
snow sql -c meridian -f 03_ml/37_m7_cross_sell.sql
snow sql -c meridian -f 03_ml/38_m4_nba_recommendations.sql
```

**Runtime**: about 12 minutes, of which the XGBoost step is 3.

### Dependency order matters

```
20 → 21 → 22 → 23 → 24 → 25 → 26          (data foundation)
                         │
        ┌────────────────┼────────────────┐
        ▼                ▼                ▼
   31 → 32 (M1)      33 (M2)          34 (M6)      ← independent of each other
        │
        ▼
   36 (M5 CLV — needs M1)
        │
        ▼
   37 (M7 cross-sell — needs M5)
        │
        ▼
   38 (M4 NBA — needs M1 + M3 + M5 + M7)
```

**If you ever regenerate the data, you must re-run the whole chain.** We once regenerated
`FACT_POLICY` after training M1 and 5,547 of 5,986 lapse scores silently pointed at the wrong
agent. There is no error message for this — the numbers are simply wrong.

### What each model does

| Model | Technique | Output table | Rows |
|-------|-----------|--------------|------|
| **M1 Lapse** | XGBoost on a point-in-time panel | `LAPSE_RISK_SCORES` | 6,002 |
| **M2 Revenue forecast** | `SNOWFLAKE.ML.FORECAST` | `REVENUE_FORECAST_RESULTS` | 138 |
| **M3 Agent scoring** | Behaviour-based rules | `AGENT_PERFORMANCE_SCORES` | 1,071 |
| **M4 Next best action** | Rule engine over M1+M3+M5+M7 | `AI_RECOMMENDATIONS` | 5,148 |
| **M5 Customer CLV** | Actuarial projection | `CUSTOMER_CLV_SCORES` | 4,362 |
| **M6 Anomaly detection** | `SNOWFLAKE.ML.ANOMALY_DETECTION` | `PRODUCTION_ANOMALIES` | 138 |
| **M7 Cross-sell** | Association rules (lift) | `CROSS_SELL_RECOMMENDATIONS` | 7,607 |

### Checkpoint 2 — the honest M1 metrics

```sql
SELECT * FROM INSURANCE_DEMO.CORE.ML_MODEL_METRICS;
```

You should see **TEST ROC-AUC ≈ 0.828**, PR-AUC ≈ 0.314, recall@top-10% ≈ 0.590,
Brier 0.0281 versus a 0.0334 baseline.

**If you see 0.97, something is wrong.** Our first run hit 0.9725 — not from temporal leakage,
but because the generator made the pre-lapse late-payment ramp an almost perfect function of
the label (60.5% of soon-to-lapse policies were >20 days late versus 0.1% of others). We fixed
the *generator*, not the model: only 55% of lapses now show deterioration, 14% of healthy
policies have a late episode and recover, and the ramp was widened to eight months. A demo
model that scores 0.97 on a business problem like this is not impressive, it is broken.

Ablation, to prove the features earn their place: tenure only 0.711 → plus billing 0.811 →
full feature set 0.828.

### A documented limitation of M6

Branch-month premium has a coefficient of variation around 0.70 — only 3 to 10 policies per
branch per month — so monthly anomaly detection is underpowered. We switched to a **3-month
rolling** series (CV 0.48). Result: 21 flags out of 138, catching 8 of 14 planted event-months
and **all 6 branches** that had planted events, with 13 false positives. Say this out loud when
you demo it. A detector that finds every branch but over-flags is a useful detector; a detector
you claim is perfect is a liability.

---

## Step 3 — Product Documents and Cortex Search

This step shows unstructured data working alongside the star schema: AI writes brochures,
renders them as branded PDFs, then Snowflake parses, chunks and indexes them.

```bash
snow sql -c meridian -f 04_search/41_generate_brochures.sql
python 04_search/42_render_pdfs.py
snow sql -c meridian -f 04_search/43_parse_and_search.sql
```

**Runtime**: about 9 minutes. Step `41` is the slow one — 24 sequential `AI_COMPLETE` calls.

What happens:

1. `41` — `AI_COMPLETE` with `claude-4-sonnet` writes 24 fictional brochures (3 per product
   classification, one per tier), averaging 7,434 characters
2. `42` — a small Markdown-to-PDF renderer produces 3-page branded PDFs (teal `#0E5C63`,
   gold `#D4A03C`) and uploads them to `@STAGE_DOC`
3. `43` — `AI_PARSE_DOCUMENT` in LAYOUT mode extracts the text,
   `SPLIT_TEXT_RECURSIVE_CHARACTER` chunks it (markdown, 1500/200), and
   `CREATE CORTEX SEARCH SERVICE` indexes 164 chunks with `arctic-embed-l-v2.0`

Every chunk is prefixed with `Product: <name> (<code>, <class>)` so a retrieved fragment
describes itself even out of context.

### Checkpoint 3

```sql
SELECT COUNT(*) AS chunks FROM INSURANCE_DEMO.CORE.DOCS_CHUNKS;             -- 164
SHOW CORTEX SEARCH SERVICES LIKE 'MERIDIAN_PRODUCT_SEARCH';                 -- ACTIVE

SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
  'INSURANCE_DEMO.CORE.MERIDIAN_PRODUCT_SEARCH',
  '{"query": "critical illness waiting period", "limit": 3}');
```

---

## Step 4 — Semantic View

The semantic view is what lets Cortex Analyst turn a plain-English question into correct SQL.
It declares tables, how they join, which columns are facts and dimensions, which expressions
are metrics, and a set of verified example queries.

```bash
snow sql -c meridian -f 05_semantic_view/51_semantic_view.sql
```

Result: `MERIDIAN_SALES_INTELLIGENCE` — 22 tables, 21 relationships, 44 facts, 94 dimensions,
40 metrics, 12 verified queries.

### Checkpoint 4 — ask it a real question

```sql
-- Achievement by branch. Must match V_BRANCH_ACHIEVEMENT.
SELECT * FROM SEMANTIC_VIEW(
  INSURANCE_DEMO.CORE.MERIDIAN_SALES_INTELLIGENCE
  DIMENSIONS branches.branch_name
  METRICS    branch_achievement.achievement_rate_pct
) ORDER BY 2 LIMIT 5;
```

The lowest-achieving branch in East Java must come out as **Jember at about 44%**. We verified
the semantic view against the underlying view: maximum difference **0.0048 percentage points**.

### Three semantic-view rules you must not break

These cost us hours. If you edit `51_semantic_view.sql`, keep them in mind.

1. **Clause order is mandatory**: `TABLES`, `RELATIONSHIPS`, `FACTS`, `DIMENSIONS`, `METRICS`,
   `COMMENT`, `MAX_STALENESS`, `AI_SQL_GENERATION`, `AI_QUESTION_CATEGORIZATION`,
   `AI_VERIFIED_QUERIES`. Also, `AI_SQL_GENERATION 'text'` takes **no equals sign**, and
   verified queries use keywords not assignment: `name AS ( QUESTION '...' SQL '...' )`.
2. **A metric may never share its name with a physical column** that another expression in the
   same table references, or you get *"Cyclic reference of expressions"*. Self-reference
   (`city AS CITY`) is fine.
3. **Most important: semantic expression names must equal their physical column names.**
   Otherwise verified-query rewriting silently produces broken SQL — Analyst builds an internal
   CTE containing only the columns whose semantic name matches the physical name, and every
   other column in the query becomes `invalid identifier`. Synonyms and aliases also share one
   global namespace and must all be unique.

---

## Step 5 — Cortex Agent

```bash
snow sql -c meridian -f 06_agent/61_agent_procedures.sql
snow sql -c meridian -f 06_agent/62_pptx_procedure.sql
snow sql -c meridian -f 06_agent/63_agent.sql
```

Creates 10 stored procedures, a PowerPoint generator, and
`MERIDIAN_COMMAND_CENTER_AGENT` with 15 tools:

| Tool type | Tools |
|-----------|-------|
| Cortex Analyst | `query_sales_intelligence` |
| Cortex Search | `search_product_docs` |
| Procedures | `predict_lapse_risk`, `get_revenue_forecast`, `score_agent_performance`, `get_customer_clv`, `detect_production_anomalies`, `get_cross_sell_suggestions`, `get_branch_scorecard`, `save_agent_recommendation`, `save_branch_recommendation`, `assign_retention_calls`, `generate_pptx_report` |
| Built-in | `create_chart`, `web_search` |

### The procedure contract — read this before writing your own tool

- Procedures must be `RETURNS VARCHAR` and emit a **single JSON cell**:
  `COALESCE(TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT(*))), '[]')`.
  `RETURNS TABLE` is **not readable** by generic agent tools.
- In `LANGUAGE SQL` bodies, reference parameters with a colon: `:P_BRANCH_ID`. Without it,
  Snowflake treats the name as a column and raises *invalid identifier*.
- `LIMIT` cannot take a bind variable. Use
  `QUALIFY ROW_NUMBER() OVER (...) <= :P_LIMIT` instead.
- `input_schema` property names must match the procedure parameters, lowercased. The agent
  passes `''` for "not supplied", so treat empty string as NULL.
- `tool_resources` is a **separate top-level map** in the YAML spec, keyed by tool name — not
  nested inside `tools`.

### Checkpoint 5 — run the five tests

Reference outputs are in `06_agent/tests/`. Ask the agent in Snowsight
(**AI & ML → Agents**) or via the REST API:

| Test | Question | What proves it worked |
|------|----------|-----------------------|
| t1 | *Which branches are below target in 2025?* | 17 of 23 below plan; 5 critically below, worst Jember 43.99% |
| t2 | *Apa saja manfaat dan pengecualian ...* (Indonesian) | Answers from the brochures and cites the **product name**, not a filename |
| t3 | *Why is Malang declining and what should we do?* | Findings / root cause / recommendations, using 4 tools together |
| t4 | *How does our persistency compare to the market?* | Uses web search, attributes external figures separately |
| t5 | *Save a recovery recommendation for Jember and generate a deck* | Writes a row with `CREATED_BY='CORTEX_AGENT'`, returns a working PPTX link |

On t3 we verified all nine quoted numbers against ground truth — 81.98% achievement, gap
Rp 214.57M, 50 agents of which 31 weak and 1 top performer, 25 high-risk policies,
Rp 159M at risk, and a November-2025 anomaly of −81.33%. Zero hallucination. Re-check this if
you change the tools; it is the strongest evidence the design works.

---

## Step 6 — Streamlit Dashboard

```bash
# Run from the repository root — the PUT paths are relative
snow sql -c meridian -f 07_streamlit/71_deploy_streamlit.sql
```

Creates `MERIDIAN_COMMAND_CENTER_DASHBOARD`, 7 pages, Plotly charts, Meridian branding.
Open it in Snowsight under **Projects → Streamlit**.

> **If the PUT fails**, your client may not resolve `file://./`. Replace `./` in the three PUT
> statements with the absolute path to your clone. Note that paths containing spaces must be
> quoted: `PUT 'file:///path with spaces/app.py' @STAGE/ ...`.

`environment.yml` deliberately pins no Python version — let Snowflake choose, or deployment
can fail on an unsupported combination.

---

## Step 7 — Closed Loop

```bash
snow sql -c meridian -f 08_closed_loop/81_closed_loop.sql
```

This is what turns the demo from "AI suggests things" into "AI suggests things and we know
whether they worked". It creates `RECOMMENDATION_FEEDBACK` (1,785 seeded rows) and
`RECOMMENDATION_OUTCOME` (1,113), plus two views: `V_RECOMMENDATION_LOOP` and
`V_MODEL_EFFECTIVENESS` (win rate, realisation).

Recommendation states after seeding: OPEN 3,834 · DONE 732 · IN_PROGRESS 381 · DISMISSED 202.

---

## Using the Demo

### Questions the agent answers well

```
Which branches are below target in 2025?
Why is Jember declining and what should we do about it?
What are the benefits and exclusions of Meridian Sehat Gold?
Show me the 20 policies most likely to lapse and who should call them
Which high value customers only hold one product?
What is our 2026 revenue outlook by branch?
```

### A demo flow that works

1. **Dashboard** — open the Command Center. Plan versus actual, 17 branches behind.
2. **Ask why** — switch to the agent: *"Why is Jember declining?"* One tool call
   (`get_branch_scorecard`) returns achievement, the latest anomaly, the agent mix and lapse
   exposure together.
3. **Get named actions** — *"Show me the 20 policies most likely to lapse in Jember and assign
   retention calls."* The agent writes rows back.
4. **Close the loop** — show `V_MODEL_EFFECTIVENESS`: of past recommendations, which were acted
   on and which produced a result.

The point to land: the loop is the product. A forecast nobody acts on is a report.

---

## Architecture and Design Decisions

```
SOURCES              FOUNDATION            AI / ML              AGENT              CONSUMPTION
14 tables       →   Semantic View      →  Cortex Search     →  Cortex Agent    →  Streamlit
Stage PDFs          Helper views          M1–M7 outputs        (15 tools)         Dashboard
                    Governance            CLV/Lapse/NBA        + web search       (7 pages)
                                                                    │
                                                                    └→ AI_RECOMMENDATIONS ─┐
                                                                                           │
                                    RECOMMENDATION_FEEDBACK / OUTCOME ←────────────────────┘
```

Six decisions worth understanding before you modify anything:

1. **Anti-fan-out achievement.** `V_BRANCH_ACHIEVEMENT` pre-aggregates target and actual
   *separately* and only then joins. **Never join `FACT_BRANCH_TARGET` directly to
   `FACT_AGENT_PRODUCTION`** — one target row multiplied by many production rows inflates the
   target and every achievement percentage silently becomes wrong.
2. **No per-agent target.** Targets exist at branch level only, which is how most insurers
   actually operate. Agent performance (M3) is therefore behaviour-based, not target-based.
3. **M1 is anti-leakage by construction.** A point-in-time panel with trailing-window features
   only, split temporally: train 2023-04→2024-08, validate 2024-09→2024-12, test
   2025-01→2025-10.
4. **Procedures return VARCHAR JSON** — see the contract in Step 5.
5. **One-shot diagnosis.** `GET_BRANCH_SCORECARD` deliberately bundles achievement, anomaly,
   agent mix, lapse exposure and open pipeline into a single call, so the agent does not fan out
   into four tool calls for one obvious question. Likewise `ASSIGN_RETENTION_CALLS` is batch, to
   stop the agent looping once per agent.
6. **Never use `scale_pos_weight` on M1.** M5 consumes M1's probabilities, so they must stay
   calibrated. Set `base_score=y_train.mean()` and use `logloss` instead.

---

## Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| `unknown model "claude-4-sonnet"` | Cross-region inference not enabled. See [3.2](#32-cross-region-inference--required) |
| `Unsupported subquery type` | A correlated `EXISTS` with a range predicate. Rewrite as a semi-join |
| Only some branches got agents | You reintroduced `RANDOM(seed)`. It is re-evaluated per row of an intermediate join, so weighted picks collapse. Use the hash-based `RND()` UDFs |
| M1 test AUC ≈ 0.97 | Generator artifact, not a good model. See [Checkpoint 2](#checkpoint-2--the-honest-m1-metrics) |
| M1 probabilities cluster near 0.5, Brier worse than baseline | Over-regularised and mis-centred. Set `base_score=y_train.mean()`, `eval_metric='logloss'`, moderate regularisation |
| Lapse scores point at the wrong agent | Stale ML output after regenerating data. Re-run 22→23→24→25→26, then 31→32, then 36→37→38 |
| Verified queries return `invalid identifier` | A semantic expression name differs from its physical column name. See [Step 4 rule 3](#three-semantic-view-rules-you-must-not-break) |
| `Cyclic reference of expressions` | A metric shares a name with a physical column referenced elsewhere in the same table |
| Brochure PDFs render as one unbroken blob | `AI_COMPLETE` returns VARIANT. Cast it: `AI_COMPLETE(...)::STRING`. Without the cast you get a JSON string with literal `\n` and wrapping quotes |
| Agent tool returns nothing usable | The procedure uses `RETURNS TABLE`. Change it to `RETURNS VARCHAR` with a single JSON cell |
| `invalid identifier 'P_BRANCH_ID'` | Missing colon prefix inside a `LANGUAGE SQL` body. Use `:P_BRANCH_ID` |
| PUT fails with "unexpected" | Unquoted path containing spaces. Quote the whole `file://` argument |
| Streamlit deploy fails on packages | Remove any `python=` pin from `environment.yml` |
| Agent missing in Snowsight | Grant `USAGE ON AGENT`, and check the user has a default warehouse set |
| M6 flags too many branch-months | Known and documented. Use the 3-month rolling series; `IS_CONFIRMED_ANOMALY` cuts false positives but loses recall |

---

## Cost and Teardown

Nothing in this demo bills continuously — there is no compute pool and no container service.
The warehouse auto-suspends after 60 seconds.

Rough build cost: **a few credits**, dominated by the 24 `AI_COMPLETE` brochure calls and the
`AI_PARSE_DOCUMENT` step. Idle cost after the build is effectively zero.

To remove everything:

```sql
USE ROLE ACCOUNTADMIN;
DROP DATABASE IF EXISTS INSURANCE_DEMO;
DROP WAREHOUSE IF EXISTS GEN2_SMALL;   -- only if you created it for this demo
```

### Sharing with other users

```sql
CREATE ROLE IF NOT EXISTS DEMO_COWORK;
GRANT USAGE ON DATABASE INSURANCE_DEMO TO ROLE DEMO_COWORK;
GRANT USAGE ON SCHEMA INSURANCE_DEMO.CORE TO ROLE DEMO_COWORK;
GRANT SELECT ON ALL TABLES IN SCHEMA INSURANCE_DEMO.CORE TO ROLE DEMO_COWORK;
GRANT SELECT ON ALL VIEWS IN SCHEMA INSURANCE_DEMO.CORE TO ROLE DEMO_COWORK;
GRANT SELECT ON SEMANTIC VIEW INSURANCE_DEMO.CORE.MERIDIAN_SALES_INTELLIGENCE TO ROLE DEMO_COWORK;
GRANT READ ON STAGE INSURANCE_DEMO.CORE.STAGE_DOC   TO ROLE DEMO_COWORK;
GRANT READ ON STAGE INSURANCE_DEMO.CORE.STAGE_EXPORT TO ROLE DEMO_COWORK;
GRANT USAGE ON WAREHOUSE GEN2_SMALL TO ROLE DEMO_COWORK;
GRANT USAGE ON AGENT INSURANCE_DEMO.CORE.MERIDIAN_COMMAND_CENTER_AGENT TO ROLE DEMO_COWORK;
```

`SELECT ON SEMANTIC VIEW` and `READ ON STAGE` are the two grants people forget most often.

Cortex Agents use the **calling user's default warehouse and role**, not the session's. Every
demo user needs one set:

```sql
ALTER USER <username> SET DEFAULT_WAREHOUSE = 'GEN2_SMALL', DEFAULT_ROLE = 'DEMO_COWORK';
```

---

## Repository Structure

```
meridian-life-demo/
├── README.md                      ← this file
├── README-IND.md                  ← Indonesian version
├── 01_setup/
│   └── 01_setup.sql               warehouse, database, schema, 3 stages
├── 02_generate_data/
│   ├── 20_gen_helpers.sql         deterministic RND/RNDI/RNDN UDFs
│   ├── 21_dimensions.sql          branches, agents, customers, products
│   ├── 22_fact_policy.sql         7,400 policies with planted patterns
│   ├── 23_fact_policy_children.sql payments, riders, claims
│   ├── 24_fact_agent.sql          production, activity, app behaviour, training
│   ├── 25_fact_target_crm.sql     branch targets, CRM tickets
│   ├── 26_helper_views.sql        6 views incl. V_BRANCH_ACHIEVEMENT
│   └── 27_verify_stop1.sql        checkpoint 1
├── 03_ml/                         M1–M7 (31–38)
├── 04_search/                     brochures → PDFs → Cortex Search (41–43)
├── 05_semantic_view/
│   ├── 51_semantic_view.sql
│   └── dedupe_synonyms.py         run after editing synonyms
├── 06_agent/
│   ├── 61_agent_procedures.sql    10 procedures
│   ├── 62_pptx_procedure.sql      PPTX + presigned URL
│   ├── 63_agent.sql               agent spec (YAML)
│   └── tests/                     t1–t5 reference outputs
├── 07_streamlit/
│   ├── streamlit_app/             app.py, environment.yml, .streamlit/
│   └── 71_deploy_streamlit.sql
├── 08_closed_loop/
│   └── 81_closed_loop.sql
└── docs/
    ├── demo-guideline.md          scene-by-scene demo script
    └── data-dictionary.md         every table and column
```

---

## Notes and Limitations

- **Meridian Life is fictional.** Every branch, agent, customer, product and brochure is
  synthetic. Do not present any figure here as an industry benchmark.
- **No real PII.** Names come from a generated pool.
- **This is a demo, not a production system.** There is no CI, no schema migration, and no
  monitoring.
- **M6 is underpowered at monthly grain** and documented as such. Do not claim precision it
  does not have.
- **The agent's web search tool** reaches the public internet. If your account forbids that,
  drop the tool from the spec; the other 14 still work.

---

*Built on Snowflake with Cortex Analyst, Cortex Search, Cortex Agents, Snowflake ML, and
Streamlit in Snowflake.*

---

## License

Apache License 2.0 — see [LICENSE](./LICENSE).

This is a personal demonstration project. It is not an official Snowflake product and is not
supported by Snowflake Inc. All company names, branches, agents, customers, products and
brochures are fictional.
