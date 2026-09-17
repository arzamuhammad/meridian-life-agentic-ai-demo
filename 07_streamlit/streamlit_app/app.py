"""
MERIDIAN LIFE — Sales Command Center Dashboard
7-page Streamlit-in-Snowflake application (warehouse mode).

Pages:
  1. Executive Overview
  2. Plan vs Real Drilldown
  3. Action Queue
  4. Forecast Explorer
  5. Agent Leaderboard
  6. Branch Achievement
  7. KPI Tracking & Feedback (closed loop)
"""
import streamlit as st
from snowflake.snowpark.context import get_active_session
import plotly.express as px
import plotly.graph_objects as go
import pandas as pd

st.set_page_config(page_title="Meridian Life Command Center", layout="wide", page_icon="🏢")

TEAL  = "#0E5C63"
GOLD  = "#D4A03C"
LTEAL = "#F2F6F7"

@st.cache_resource
def get_session():
    return get_active_session()

@st.cache_data(ttl=300)
def q(sql):
    return get_session().sql(sql).to_pandas()

def rp(v):
    if v is None or pd.isna(v): return "—"
    v = float(v)
    if abs(v) >= 1e9: return f"Rp {v/1e9:,.2f} B"
    if abs(v) >= 1e6: return f"Rp {v/1e6:,.1f} M"
    return f"Rp {v:,.0f}"

def kpi_tile(label, value, delta=None, delta_color="normal"):
    st.metric(label=label, value=value, delta=delta, delta_color=delta_color)

# ---------- SIDEBAR ----------
with st.sidebar:
    st.image("https://img.icons8.com/fluency/96/shield.png", width=48)
    st.title("Meridian Life")
    st.caption("Sales Command Center")
    page = st.radio("Navigation", [
        "🏠 Executive Overview",
        "🔍 Plan vs Real Drilldown",
        "📋 Action Queue",
        "📈 Forecast Explorer",
        "🎯 Agent Leaderboard",
        "🏢 Branch Achievement",
        "📊 KPI Tracking & Feedback",
    ], label_visibility="collapsed")
    st.divider()
    fiscal_year = st.selectbox("Fiscal Year", [2025, 2024, 2023], index=0)
    st.caption("Fictional data — Meridian Life does not exist.")


# =====================================================================
# PAGE 1: Executive Overview
# =====================================================================
if page == "🏠 Executive Overview":
    st.title("🏠 Executive Overview")
    kpis = q(f"SELECT * FROM V_DASHBOARD_KPIS WHERE FISCAL_YEAR = {fiscal_year}")
    if kpis.empty:
        st.warning("No KPI data for this year.")
        st.stop()
    k = kpis.iloc[0]
    c1, c2, c3, c4, c5, c6 = st.columns(6)
    with c1: kpi_tile("FYAP", rp(k.get("TOTAL_FYAP")))
    with c2: kpi_tile("Plan", rp(k.get("TARGET_FYAP")))
    with c3: kpi_tile("Achievement", f"{k.get('ACHIEVEMENT_PCT', 0):.1f}%",
                       delta=f"{k.get('ACHIEVEMENT_PCT',0)-100:.1f}pp vs plan",
                       delta_color="normal" if k.get('ACHIEVEMENT_PCT',0)>=100 else "inverse")
    with c4: kpi_tile("New Policies", f"{int(k.get('NEW_POLICIES',0)):,}")
    with c5: kpi_tile("Persistency 13M", f"{k.get('PERSISTENCY_13M_PCT', 0):.1f}%" if k.get('PERSISTENCY_13M_PCT') else "—")
    with c6: kpi_tile("Loss Ratio", f"{k.get('LOSS_RATIO_PCT', 0):.1f}%" if k.get('LOSS_RATIO_PCT') else "—")

    st.divider()
    left, right = st.columns([3, 2])
    with left:
        st.subheader("FYAP vs Plan by Branch")
        ach = q(f"""SELECT BRANCH_NAME, ACTUAL_FYAP, TARGET_FYAP, ACHIEVEMENT_PCT, ACHIEVEMENT_BAND
                    FROM V_BRANCH_ACHIEVEMENT WHERE FISCAL_YEAR = {fiscal_year} ORDER BY ACHIEVEMENT_PCT""")
        fig = go.Figure()
        fig.add_trace(go.Bar(x=ach["BRANCH_NAME"], y=ach["ACTUAL_FYAP"], name="Actual", marker_color=TEAL))
        fig.add_trace(go.Bar(x=ach["BRANCH_NAME"], y=ach["TARGET_FYAP"], name="Plan", marker_color=GOLD, opacity=0.5))
        fig.update_layout(barmode="overlay", height=420, margin=dict(t=10, b=40),
                          yaxis_title="FYAP (IDR)", legend=dict(orientation="h", y=1.02))
        st.plotly_chart(fig, use_container_width=True)
    with right:
        st.subheader("AI Insights")
        risk = q("SELECT COUNT_IF(RISK_SEGMENT IN ('HIGH','CRITICAL')) N, SUM(IFF(RISK_SEGMENT IN ('HIGH','CRITICAL'),ANNUAL_PREMIUM,0)) V FROM LAPSE_RISK_SCORES")
        pipe = q("SELECT COUNT(*) N, SUM(EXPECTED_VALUE) V FROM AI_RECOMMENDATIONS WHERE STATUS='OPEN'")
        st.info(f"**{int(risk.iloc[0]['N']):,}** high-risk policies with **{rp(risk.iloc[0]['V'])}** premium at risk")
        st.info(f"**{int(pipe.iloc[0]['N']):,}** open actions worth **{rp(pipe.iloc[0]['V'])}** in the queue")
        eff = q("SELECT RECOMMENDATION_TYPE, WIN_RATE_PCT, ACCEPTANCE_RATE_PCT FROM V_MODEL_EFFECTIVENESS ORDER BY WIN_RATE_PCT DESC NULLS LAST")
        if not eff.empty:
            st.subheader("Model Win Rates")
            st.dataframe(eff, use_container_width=True, hide_index=True)


# =====================================================================
# PAGE 2: Plan vs Real Drilldown
# =====================================================================
elif page == "🔍 Plan vs Real Drilldown":
    st.title("🔍 Plan vs Real Drilldown")
    ach = q(f"""SELECT BRANCH_ID, BRANCH_NAME, PROVINCE, REGION, TARGET_FYAP, ACTUAL_FYAP,
                       FYAP_VARIANCE, ACHIEVEMENT_PCT, ACHIEVEMENT_BAND, ACTIVE_AGENTS
                FROM V_BRANCH_ACHIEVEMENT WHERE FISCAL_YEAR = {fiscal_year} ORDER BY ACHIEVEMENT_PCT""")
    sel = st.selectbox("Select Branch", ["All Branches"] + ach["BRANCH_NAME"].tolist())

    if sel == "All Branches":
        fig = px.bar(ach, x="BRANCH_NAME", y="ACHIEVEMENT_PCT", color="ACHIEVEMENT_BAND",
                     color_discrete_map={"Exceeding": "#2F855A", "On Target": "#38A169",
                                         "Slightly Below": "#D69E2E", "Below Target": "#DD6B20",
                                         "Critically Below": "#E53E3E"},
                     title="Achievement % by Branch", height=440)
        fig.add_hline(y=100, line_dash="dash", line_color="red", annotation_text="100% Plan")
        st.plotly_chart(fig, use_container_width=True)
        st.dataframe(ach[["BRANCH_NAME","PROVINCE","TARGET_FYAP","ACTUAL_FYAP","FYAP_VARIANCE","ACHIEVEMENT_PCT","ACHIEVEMENT_BAND"]],
                     use_container_width=True, hide_index=True)
    else:
        br = ach[ach["BRANCH_NAME"] == sel].iloc[0]
        bid = br["BRANCH_ID"]
        c1, c2, c3 = st.columns(3)
        with c1: kpi_tile("Achievement", f"{br['ACHIEVEMENT_PCT']:.1f}%")
        with c2: kpi_tile("Gap", rp(br["FYAP_VARIANCE"]))
        with c3: kpi_tile("Band", br["ACHIEVEMENT_BAND"])

        st.subheader("Monthly Variance")
        mv = q(f"""SELECT PRODUCTION_MONTH, ACTUAL_FYAP, MONTHLY_PLAN_FYAP, VARIANCE_FYAP, MOM_CHANGE_PCT
                   FROM V_BRANCH_VARIANCE WHERE BRANCH_ID='{bid}' AND PRODUCTION_YEAR={fiscal_year} ORDER BY PRODUCTION_MONTH""")
        if not mv.empty:
            fig = go.Figure()
            fig.add_trace(go.Bar(x=mv["PRODUCTION_MONTH"], y=mv["ACTUAL_FYAP"], name="Actual", marker_color=TEAL))
            fig.add_trace(go.Scatter(x=mv["PRODUCTION_MONTH"], y=mv["MONTHLY_PLAN_FYAP"], name="Plan", line=dict(color=GOLD, dash="dash")))
            fig.update_layout(height=360, margin=dict(t=10))
            st.plotly_chart(fig, use_container_width=True)

        st.subheader("High-Risk Lapse Policies")
        lr = q(f"""SELECT l.POLICY_ID, c.CUSTOMER_NAME, ROUND(l.LAPSE_PROBABILITY,4) PROB, l.RISK_SEGMENT,
                          l.IS_DANGER_ZONE, l.TENURE_MONTHS, l.ANNUAL_PREMIUM, COALESCE(v.CLV_SEGMENT,'?') CLV
                   FROM LAPSE_RISK_SCORES l JOIN DIM_CUSTOMER c ON c.CUSTOMER_ID=l.CUSTOMER_ID
                   LEFT JOIN CUSTOMER_CLV_SCORES v ON v.CUSTOMER_ID=l.CUSTOMER_ID
                   WHERE l.BRANCH_ID='{bid}' AND l.RISK_SEGMENT IN ('HIGH','CRITICAL')
                   ORDER BY l.LAPSE_PROBABILITY DESC LIMIT 20""")
        if lr.empty:
            st.success("No HIGH or CRITICAL lapse-risk policies in this branch.")
        else:
            st.dataframe(lr, use_container_width=True, hide_index=True)


# =====================================================================
# PAGE 3: Action Queue
# =====================================================================
elif page == "📋 Action Queue":
    st.title("📋 AI Action Queue")
    # KPI tiles
    stats = q("""SELECT COUNT(*) TOTAL, COUNT_IF(PRIORITY='HIGH') HIGH_CNT,
                        MAX(URGENCY_SCORE) TOP_URG, SUM(EXPECTED_VALUE) PIPELINE
                 FROM AI_RECOMMENDATIONS WHERE STATUS='OPEN'""").iloc[0]
    c1, c2, c3, c4 = st.columns(4)
    with c1: kpi_tile("Total Open", f"{int(stats['TOTAL']):,}")
    with c2: kpi_tile("HIGH Priority", f"{int(stats['HIGH_CNT']):,}")
    with c3: kpi_tile("Top Urgency", f"{stats['TOP_URG']:.0f}")
    with c4: kpi_tile("Pipeline Value", rp(stats["PIPELINE"]))

    # Filters
    f1, f2, f3, f4 = st.columns(4)
    with f1: f_pri = st.multiselect("Priority", ["HIGH","MEDIUM","LOW"], default=["HIGH","MEDIUM"])
    with f2:
        types = q("SELECT DISTINCT RECOMMENDATION_TYPE FROM AI_RECOMMENDATIONS ORDER BY 1")["RECOMMENDATION_TYPE"].tolist()
        f_type = st.multiselect("Type", types, default=types)
    with f3: f_status = st.multiselect("Status", ["OPEN","ASSIGNED","IN_PROGRESS","DONE","DISMISSED"], default=["OPEN"])
    with f4: f_min_urg = st.slider("Min Urgency", 0, 100, 30)

    pri_str = ",".join(f"'{p}'" for p in f_pri) if f_pri else "'HIGH','MEDIUM','LOW'"
    typ_str = ",".join(f"'{t}'" for t in f_type) if f_type else "'X'"
    sts_str = ",".join(f"'{s}'" for s in f_status) if f_status else "'OPEN'"
    df = q(f"""SELECT RECOMMENDATION_TYPE, PRIORITY, URGENCY_SCORE, AGENT_NAME, BRANCH_NAME,
                      CUSTOMER_NAME, CUSTOMER_ID, POLICY_ID, TITLE, EXPECTED_VALUE, STATUS
               FROM AI_RECOMMENDATIONS
               WHERE PRIORITY IN ({pri_str}) AND RECOMMENDATION_TYPE IN ({typ_str})
                 AND STATUS IN ({sts_str}) AND URGENCY_SCORE >= {f_min_urg}
               ORDER BY URGENCY_SCORE DESC LIMIT 200""")
    st.dataframe(df, use_container_width=True, hide_index=True, height=520)


# =====================================================================
# PAGE 4: Forecast Explorer
# =====================================================================
elif page == "📈 Forecast Explorer":
    st.title("📈 Revenue Forecast (2026)")
    branches = q("SELECT DISTINCT BRANCH_ID, BRANCH_NAME FROM REVENUE_FORECAST_RESULTS r JOIN DIM_BRANCH b USING (BRANCH_ID) ORDER BY BRANCH_NAME")
    sel = st.selectbox("Branch", branches["BRANCH_NAME"].tolist())
    bid = branches[branches["BRANCH_NAME"]==sel].iloc[0]["BRANCH_ID"]

    hist = q(f"""SELECT PRODUCTION_MONTH::DATE AS MONTH, SUM(FYAP) FYAP
                 FROM FACT_AGENT_PRODUCTION WHERE BRANCH_ID='{bid}' AND PRODUCTION_MONTH >= '2025-01-01'
                 GROUP BY 1 ORDER BY 1""")
    fcast = q(f"""SELECT FORECAST_MONTH::DATE AS MONTH, FORECAST_FYAP FYAP, LOWER_BOUND_95, UPPER_BOUND_95
                  FROM REVENUE_FORECAST_RESULTS WHERE BRANCH_ID='{bid}' ORDER BY 1""")
    plan = q(f"SELECT SUM(TARGET_FYAP)/12.0 MP FROM FACT_BRANCH_TARGET WHERE BRANCH_ID='{bid}' AND TARGET_YEAR=2025")
    mp = float(plan.iloc[0]["MP"]) if not plan.empty else 0

    fig = go.Figure()
    fig.add_trace(go.Scatter(x=hist["MONTH"], y=hist["FYAP"], name="Actual 2025", line=dict(color=TEAL, width=2)))
    fig.add_trace(go.Scatter(x=fcast["MONTH"], y=fcast["FYAP"], name="Forecast 2026", line=dict(color=GOLD, width=2, dash="dot")))
    fig.add_trace(go.Scatter(x=fcast["MONTH"], y=fcast["UPPER_BOUND_95"], name="Upper 95%", line=dict(width=0), showlegend=False))
    fig.add_trace(go.Scatter(x=fcast["MONTH"], y=fcast["LOWER_BOUND_95"], name="95% Interval", fill="tonexty",
                             fillcolor="rgba(212,160,60,0.15)", line=dict(width=0)))
    if mp > 0:
        fig.add_hline(y=mp, line_dash="dash", line_color="red", annotation_text="Monthly Plan (2025)")
    fig.update_layout(height=480, margin=dict(t=10), yaxis_title="FYAP (IDR)")
    st.plotly_chart(fig, use_container_width=True)
    st.dataframe(fcast, use_container_width=True, hide_index=True)


# =====================================================================
# PAGE 5: Agent Leaderboard
# =====================================================================
elif page == "🎯 Agent Leaderboard":
    st.title("🎯 Agent Performance Leaderboard")
    c1, c2 = st.columns(2)
    with c1:
        cat_filter = st.multiselect("Category", ["TOP_PERFORMER","SOLID","NEEDS_COACHING","AT_RISK"],
                                    default=["TOP_PERFORMER","SOLID","NEEDS_COACHING","AT_RISK"])
    with c2:
        branch_filter = st.selectbox("Branch", ["All"] + q("SELECT DISTINCT BRANCH_NAME FROM AGENT_PERFORMANCE_SCORES ORDER BY 1")["BRANCH_NAME"].tolist())

    cat_str = ",".join(f"'{c}'" for c in cat_filter) if cat_filter else "'X'"
    br_cond = f"AND BRANCH_NAME = '{branch_filter}'" if branch_filter != "All" else ""
    agents = q(f"""SELECT AGENT_NAME, BRANCH_NAME, AGENT_LEVEL, COMPOSITE_SCORE, PERFORMANCE_CATEGORY,
                          PRODUCTION_SCORE, ACTIVITY_SCORE, TRAINING_SCORE, RETENTION_SCORE,
                          FYAP_12M, POLICIES_12M, PERSISTENCY_PCT
                   FROM AGENT_PERFORMANCE_SCORES
                   WHERE PERFORMANCE_CATEGORY IN ({cat_str}) {br_cond}
                   ORDER BY COMPOSITE_SCORE DESC LIMIT 100""")

    # Category distribution
    dist = q("SELECT PERFORMANCE_CATEGORY, COUNT(*) N FROM AGENT_PERFORMANCE_SCORES GROUP BY 1")
    fig = px.pie(dist, values="N", names="PERFORMANCE_CATEGORY", hole=0.45,
                 color="PERFORMANCE_CATEGORY",
                 color_discrete_map={"TOP_PERFORMER":"#2F855A","SOLID":"#38A169",
                                     "NEEDS_COACHING":"#D69E2E","AT_RISK":"#E53E3E"})
    fig.update_layout(height=300, margin=dict(t=10, b=10))
    lc, rc = st.columns([1, 2])
    with lc: st.plotly_chart(fig, use_container_width=True)
    with rc: st.dataframe(agents, use_container_width=True, hide_index=True, height=340)

    # Pillar comparison
    st.subheader("Score Pillars — Top 20")
    top20 = agents.head(20)
    if not top20.empty:
        fig2 = go.Figure()
        for col, name in [("PRODUCTION_SCORE","Production"),("ACTIVITY_SCORE","Activity"),
                          ("TRAINING_SCORE","Training"),("RETENTION_SCORE","Retention")]:
            fig2.add_trace(go.Bar(x=top20["AGENT_NAME"], y=top20[col], name=name))
        fig2.update_layout(barmode="group", height=380, margin=dict(t=10))
        st.plotly_chart(fig2, use_container_width=True)


# =====================================================================
# PAGE 6: Branch Achievement
# =====================================================================
elif page == "🏢 Branch Achievement":
    st.title("🏢 Branch Achievement")
    ach = q(f"""SELECT BRANCH_NAME, PROVINCE, REGION, BRANCH_TYPE, TARGET_FYAP, ACTUAL_FYAP,
                       FYAP_VARIANCE, ACHIEVEMENT_PCT, ACHIEVEMENT_BAND, ACTIVE_AGENTS
                FROM V_BRANCH_ACHIEVEMENT WHERE FISCAL_YEAR = {fiscal_year} ORDER BY ACHIEVEMENT_PCT DESC""")
    fig = px.bar(ach, x="BRANCH_NAME", y=["ACTUAL_FYAP","TARGET_FYAP"], barmode="group",
                 color_discrete_sequence=[TEAL, GOLD], height=440,
                 title=f"Target vs Actual FYAP — {fiscal_year}")
    st.plotly_chart(fig, use_container_width=True)

    st.subheader("Achievement Table")
    st.dataframe(ach, use_container_width=True, hide_index=True)

    # By region
    st.subheader("Achievement by Region")
    reg = q(f"""SELECT REGION, SUM(TARGET_FYAP) TARGET, SUM(ACTUAL_FYAP) ACTUAL,
                       ROUND(100.0*SUM(ACTUAL_FYAP)/NULLIF(SUM(TARGET_FYAP),0),2) ACH_PCT
                FROM V_BRANCH_ACHIEVEMENT WHERE FISCAL_YEAR={fiscal_year} GROUP BY 1 ORDER BY ACH_PCT DESC""")
    fig2 = px.bar(reg, x="REGION", y="ACH_PCT", text="ACH_PCT", color_discrete_sequence=[TEAL], height=350)
    fig2.add_hline(y=100, line_dash="dash", line_color="red")
    fig2.update_traces(texttemplate="%{text:.1f}%", textposition="outside")
    fig2.update_layout(margin=dict(t=10), yaxis_title="Achievement %")
    st.plotly_chart(fig2, use_container_width=True)


# =====================================================================
# PAGE 7: KPI Tracking & Feedback (closed loop)
# =====================================================================
elif page == "📊 KPI Tracking & Feedback":
    st.title("📊 KPI Tracking & Recommendation Feedback")

    # Loop funnel
    loop = q("""SELECT LOOP_STAGE, COUNT(*) N FROM V_RECOMMENDATION_LOOP GROUP BY 1""")
    c1, c2, c3, c4, c5 = st.columns(5)
    for col, stage in zip([c1,c2,c3,c4,c5], ["AWAITING_FEEDBACK","PENDING","WIN","LOSS","NOT_ACTIONED"]):
        row = loop[loop["LOOP_STAGE"]==stage]
        with col: kpi_tile(stage.replace("_"," ").title(), f"{int(row['N'].iloc[0]):,}" if not row.empty else "0")

    st.subheader("Model Effectiveness by Action Type")
    eff = q("""SELECT RECOMMENDATION_TYPE, TOTAL_RECOMMENDED, ACCEPTANCE_RATE_PCT,
                      AVG_USEFULNESS, WIN_RATE_PCT, VALUE_REALISATION_PCT,
                      EXPECTED_VALUE_TOTAL, REALISED_VALUE_TOTAL
               FROM V_MODEL_EFFECTIVENESS ORDER BY TOTAL_RECOMMENDED DESC""")
    st.dataframe(eff, use_container_width=True, hide_index=True)

    # Win rate chart
    if not eff.empty:
        fig = px.bar(eff, x="RECOMMENDATION_TYPE", y="WIN_RATE_PCT", text="WIN_RATE_PCT",
                     color_discrete_sequence=[TEAL], height=340)
        fig.update_traces(texttemplate="%{text:.1f}%", textposition="outside")
        fig.update_layout(margin=dict(t=10), yaxis_title="Win Rate %", xaxis_title="")
        st.plotly_chart(fig, use_container_width=True)

    st.subheader("Value Realisation")
    c1, c2, c3 = st.columns(3)
    total_exp = float(eff["EXPECTED_VALUE_TOTAL"].sum()) if not eff.empty else 0
    total_real = float(eff["REALISED_VALUE_TOTAL"].sum()) if not eff.empty else 0
    with c1: kpi_tile("Expected Pipeline", rp(total_exp))
    with c2: kpi_tile("Realised Value", rp(total_real))
    with c3: kpi_tile("Realisation %", f"{100*total_real/total_exp:.1f}%" if total_exp else "—")

    st.subheader("Recent Feedback")
    fb = q("""SELECT r.RECOMMENDATION_TYPE, r.TITLE, r.BRANCH_NAME, f.DECISION, f.USEFULNESS_RATING,
                     f.SUBMITTED_BY_ROLE, f.SUBMITTED_AT::VARCHAR AS SUBMITTED_AT,
                     o.OUTCOME_STATUS, o.REALISED_VALUE
              FROM AI_RECOMMENDATIONS r
              JOIN RECOMMENDATION_FEEDBACK f ON f.RECOMMENDATION_ID = r.RECOMMENDATION_ID
              LEFT JOIN RECOMMENDATION_OUTCOME o ON o.RECOMMENDATION_ID = r.RECOMMENDATION_ID
              ORDER BY f.SUBMITTED_AT DESC LIMIT 30""")
    st.dataframe(fb, use_container_width=True, hide_index=True, height=400)
