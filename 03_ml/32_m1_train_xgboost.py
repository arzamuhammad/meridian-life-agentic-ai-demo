#!/usr/bin/env python
"""
MERIDIAN LIFE — M1 Lapse Prediction (XGBoost, point-in-time, 90-day horizon)

Reads ML_LAPSE_PANEL, trains on a TEMPORAL split, reports honest metrics
(ROC-AUC, PR-AUC, recall@top-decile, Brier) and writes LAPSE_RISK_SCORES.

Leakage discipline
  * Split is TEMPORAL, never random: train T <= 2024-12-01, test 2025.
  * Only trailing-window features (built in 31_m1_lapse_panel.sql).
  * An explicit deny-list guarantees no label-bearing column can slip in.
  * An ablation run quantifies how much of the signal comes from the
    billing features vs. plain tenure, so a high AUC can be explained
    rather than just celebrated.

Usage:  python 32_m1_train_xgboost.py
"""
import os
import sys
import tomllib
import numpy as np
import pandas as pd
import snowflake.connector
from snowflake.connector.pandas_tools import write_pandas
from sklearn.metrics import (roc_auc_score, average_precision_score,
                             brier_score_loss, precision_score)
import xgboost as xgb

CONN_NAME = os.environ.get("SNOWFLAKE_CONNECTION_NAME", "default")
DATABASE, SCHEMA = "INSURANCE_DEMO", "CORE"
SCORE_ASOF = "2025-12-01"          # the demo's "today"
RANDOM_STATE = 42

# Columns that must never become features (identifiers, label, or label-bearing)
DENY = {
    "ASOF_DATE", "POLICY_ID", "CUSTOMER_ID", "AGENT_ID", "BRANCH_ID", "PRODUCT_ID",
    "LAPSE_IN_90D", "LABEL_OBSERVABLE", "SPLIT_TAG",
}
CATEGORICAL = [
    "PAYMENT_FREQUENCY", "CLASSIFICATION", "PRODUCT_TYPE", "SUBMISSION_CHANNEL",
    "UNDERWRITING_DECISION", "MARITAL_STATUS", "OCCUPATION", "AGENT_LEVEL",
]
# Billing-behaviour block, used only for the ablation run
BILLING = [
    "PAID_CNT_90D", "PAID_CNT_365D", "LATE_CNT_90D", "LATE_CNT_365D",
    "UNPAID_CNT_90D", "UNPAID_CNT_365D", "AVG_DAYS_LATE_365D", "MAX_DAYS_LATE_365D",
    "DAYS_SINCE_LAST_PAYMENT", "DAYS_SINCE_LAST_DUE", "PAID_RATIO_365D",
]


def connect():
    """Connect using the named entry in ~/.snowflake/connections.toml."""
    path = os.path.expanduser("~/.snowflake/connections.toml")
    with open(path, "rb") as fh:
        cfg = tomllib.load(fh)[CONN_NAME]
    kwargs = dict(
        account=cfg["account"], user=cfg["user"],
        role=cfg.get("role", "ACCOUNTADMIN"),
        warehouse=cfg.get("warehouse", "GEN2_SMALL"),
        database=DATABASE, schema=SCHEMA,
    )
    if "token_file_path" in cfg:
        with open(os.path.expanduser(cfg["token_file_path"])) as fh:
            kwargs["password"] = fh.read().strip()
    else:
        kwargs["password"] = cfg["password"]
    return snowflake.connector.connect(**kwargs)


def recall_at_k(y_true, y_score, k=0.10):
    """Share of all positives captured in the top-k fraction by score."""
    n = max(1, int(len(y_score) * k))
    idx = np.argsort(-y_score)[:n]
    return y_true[idx].sum() / max(1, y_true.sum())


def prep(df):
    """Split into X / y, one-hot the categoricals, force float dtypes."""
    y = df["LAPSE_IN_90D"].astype(int).values
    X = df.drop(columns=[c for c in DENY if c in df.columns])
    cats = [c for c in CATEGORICAL if c in X.columns]
    X = pd.get_dummies(X, columns=cats, dummy_na=False)
    # XGBoost rejects Snowflake DecimalType -> cast everything to float64
    return X.astype("float64"), y


def evaluate(name, y, p):
    m = {
        "rows": len(y),
        "positives": int(y.sum()),
        "base_rate_%": round(100 * y.mean(), 3),
        "ROC_AUC": round(roc_auc_score(y, p), 4),
        "PR_AUC": round(average_precision_score(y, p), 4),
        "recall@top10%": round(recall_at_k(y, p, 0.10), 4),
        "recall@top20%": round(recall_at_k(y, p, 0.20), 4),
        "Brier": round(brier_score_loss(y, p), 5),
        "Brier_baseline": round(brier_score_loss(y, np.full_like(p, y.mean())), 5),
    }
    print(f"\n--- {name} ---")
    for k, v in m.items():
        print(f"  {k:<18} {v}")
    return m


def main():
    con = connect()
    print(f"Connected: {CONN_NAME} -> {DATABASE}.{SCHEMA}")

    panel = pd.read_sql(f"SELECT * FROM {DATABASE}.{SCHEMA}.ML_LAPSE_PANEL", con)
    print(f"Panel loaded: {panel.shape[0]:,} rows x {panel.shape[1]} cols")

    train = panel[(panel.SPLIT_TAG == "TRAIN")
                  & (panel.ASOF_DATE.astype(str) <= "2024-08-01")].copy()
    valid = panel[(panel.SPLIT_TAG == "TRAIN")
                  & (panel.ASOF_DATE.astype(str) > "2024-08-01")].copy()
    test = panel[panel.SPLIT_TAG == "TEST"].copy()
    score = panel[panel.ASOF_DATE.astype(str) == SCORE_ASOF].copy()
    print(f"TRAIN {len(train):,} | VALID {len(valid):,} | TEST {len(test):,} "
          f"| SCORE {len(score):,}")

    X_tr, y_tr = prep(train)
    X_va, y_va = prep(valid)
    X_te, y_te = prep(test)
    X_sc, _ = prep(score)
    # align one-hot columns across splits
    X_va = X_va.reindex(columns=X_tr.columns, fill_value=0.0)
    X_te = X_te.reindex(columns=X_tr.columns, fill_value=0.0)
    X_sc = X_sc.reindex(columns=X_tr.columns, fill_value=0.0)
    print(f"Features: {X_tr.shape[1]}")

    params = dict(
        n_estimators=800, max_depth=4, learning_rate=0.05,
        subsample=0.8, colsample_bytree=0.8,
        min_child_weight=20, reg_lambda=3.0,
        objective="binary:logistic",
        # log-loss (not aucpr) for early stopping: M5 consumes these as real
        # probabilities, so calibration matters more than pure ranking.
        eval_metric="logloss",
        # start from the observed base rate instead of XGBoost's 0.5 prior,
        # otherwise an early stop leaves every probability grossly inflated.
        base_score=float(y_tr.mean()),
        tree_method="hist", random_state=RANDOM_STATE, n_jobs=4,
        early_stopping_rounds=60,
        # NOTE: deliberately NO scale_pos_weight — we need calibrated
        # probabilities because M5 (CLV) uses retention = 1 - AVG(prob).
    )
    model = xgb.XGBClassifier(**params)
    # Early stopping uses the VALIDATION fold (the last 4 train snapshots),
    # never TEST — otherwise the out-of-time metric is contaminated.
    model.fit(X_tr, y_tr, eval_set=[(X_va, y_va)], verbose=False)
    print(f"Best iteration: {model.best_iteration} of {params['n_estimators']}")

    p_tr = model.predict_proba(X_tr)[:, 1]
    p_va = model.predict_proba(X_va)[:, 1]
    p_te = model.predict_proba(X_te)[:, 1]
    m_tr = evaluate("TRAIN (in-sample)", y_tr, p_tr)
    m_va = evaluate("VALID (early stopping fold)", y_va, p_va)
    m_te = evaluate("TEST (out-of-time 2025)", y_te, p_te)

    # ---- leakage diagnostics ------------------------------------------
    imp = (pd.Series(model.feature_importances_, index=X_tr.columns)
             .sort_values(ascending=False))
    print("\n--- Top 15 feature importances (gain-weighted) ---")
    for f, v in imp.head(15).items():
        print(f"  {f:<32} {v:.4f}")

    print("\n--- Ablation: how much comes from billing behaviour? ---")
    abl = {k: v for k, v in params.items() if k != "early_stopping_rounds"}
    abl["n_estimators"] = max(50, model.best_iteration + 1)
    for label, cols in [("tenure-only (drop billing)", [c for c in X_tr.columns if c not in BILLING]),
                        ("billing-only + tenure", [c for c in X_tr.columns
                                                   if c in BILLING or c.startswith("TENURE")])]:
        m = xgb.XGBClassifier(**abl)
        m.fit(X_tr[cols], y_tr, verbose=False)
        p = m.predict_proba(X_te[cols])[:, 1]
        print(f"  {label:<28} ROC_AUC={roc_auc_score(y_te, p):.4f} "
              f"PR_AUC={average_precision_score(y_te, p):.4f}")
    print(f"  {'full model':<28} ROC_AUC={m_te['ROC_AUC']:.4f} "
          f"PR_AUC={m_te['PR_AUC']:.4f}")

    # ---- calibration check (matters: M5 uses these as real probabilities) --
    print("\n--- Calibration on TEST (predicted vs observed by decile) ---")
    cal = pd.DataFrame({"p": p_te, "y": y_te})
    cal["decile"] = pd.qcut(cal.p, 10, labels=False, duplicates="drop")
    for d, g in cal.groupby("decile"):
        print(f"  decile {int(d) + 1:>2}  predicted {g.p.mean():.4f}  "
              f"observed {g.y.mean():.4f}  n={len(g):,}")

    if m_te["ROC_AUC"] >= 0.97:
        print("\n!! WARNING: test ROC-AUC >= 0.97 — investigate for leakage "
              "before trusting this model.")

    # ---- score the production book ------------------------------------
    p_sc = model.predict_proba(X_sc)[:, 1]
    out = pd.DataFrame({
        "POLICY_ID": score.POLICY_ID.values,
        "CUSTOMER_ID": score.CUSTOMER_ID.values,
        "AGENT_ID": score.AGENT_ID.values,
        "BRANCH_ID": score.BRANCH_ID.values,
        "PRODUCT_ID": score.PRODUCT_ID.values,
        "ASOF_DATE": pd.to_datetime(SCORE_ASOF).date(),
        "LAPSE_PROBABILITY": np.round(p_sc, 6),
        "TENURE_MONTHS": score.TENURE_MONTHS.astype(int).values,
        "ANNUAL_PREMIUM": score.ANNUAL_PREMIUM.astype(float).values,
        "PAYMENT_FREQUENCY": score.PAYMENT_FREQUENCY.values,
        "LATE_CNT_365D": score.LATE_CNT_365D.astype(float).values,
        "UNPAID_CNT_90D": score.UNPAID_CNT_90D.astype(float).values,
        "RETENTION_TICKET_365D": score.RETENTION_TICKET_365D.astype(float).values,
    })
    out["IS_DANGER_ZONE"] = out.TENURE_MONTHS.between(10, 14)
    out["RISK_SEGMENT"] = pd.cut(
        out.LAPSE_PROBABILITY,
        bins=[-0.001, 0.05, 0.15, 0.35, 1.0],
        labels=["LOW", "MEDIUM", "HIGH", "CRITICAL"],
    ).astype(str)
    out["MODEL_VERSION"] = "M1_xgb_pit90d_v1"

    print("\n--- Scored book distribution ---")
    print(out.RISK_SEGMENT.value_counts().to_string())
    print(f"  danger zone (tenure 10-14m): {int(out.IS_DANGER_ZONE.sum()):,}")
    print(f"  mean predicted probability : {out.LAPSE_PROBABILITY.mean():.4f}")

    cur = con.cursor()
    cur.execute(f"""
        CREATE OR REPLACE TABLE {DATABASE}.{SCHEMA}.LAPSE_RISK_SCORES (
            POLICY_ID VARCHAR(20), CUSTOMER_ID VARCHAR(20), AGENT_ID VARCHAR(20),
            BRANCH_ID VARCHAR(10), PRODUCT_ID VARCHAR(10), ASOF_DATE DATE,
            LAPSE_PROBABILITY FLOAT, TENURE_MONTHS NUMBER(6,0),
            ANNUAL_PREMIUM FLOAT, PAYMENT_FREQUENCY VARCHAR(20),
            LATE_CNT_365D FLOAT, UNPAID_CNT_90D FLOAT, RETENTION_TICKET_365D FLOAT,
            IS_DANGER_ZONE BOOLEAN, RISK_SEGMENT VARCHAR(12), MODEL_VERSION VARCHAR(40)
        ) COMMENT = 'M1 output: 90-day lapse probability, point-in-time as of {SCORE_ASOF}.'
    """)
    ok, nchunks, nrows, _ = write_pandas(
        con, out, "LAPSE_RISK_SCORES", database=DATABASE, schema=SCHEMA)
    print(f"\nLAPSE_RISK_SCORES written: ok={ok} rows={nrows:,}")

    # persist metrics for the audit trail
    cur.execute(f"""
        CREATE TABLE IF NOT EXISTS {DATABASE}.{SCHEMA}.ML_MODEL_METRICS (
            MODEL_NAME VARCHAR(40), MODEL_VERSION VARCHAR(40), SPLIT_NAME VARCHAR(20),
            METRIC_NAME VARCHAR(40), METRIC_VALUE FLOAT, TRAINED_AT TIMESTAMP_NTZ
        )
    """)
    cur.execute("DELETE FROM ML_MODEL_METRICS WHERE MODEL_NAME = 'M1_LAPSE'")
    rows = [("M1_LAPSE", "M1_xgb_pit90d_v1", split, k, float(v))
            for split, m in [("TRAIN", m_tr), ("VALID", m_va), ("TEST", m_te)]
            for k, v in m.items()]
    cur.executemany(
        "INSERT INTO ML_MODEL_METRICS "
        "(MODEL_NAME, MODEL_VERSION, SPLIT_NAME, METRIC_NAME, METRIC_VALUE, TRAINED_AT) "
        "VALUES (%s,%s,%s,%s,%s,CURRENT_TIMESTAMP())", rows)
    print("Metrics persisted to ML_MODEL_METRICS.")
    con.close()


if __name__ == "__main__":
    sys.exit(main())
