# Demo Guideline — Discovery-Driven Demo

**The cardinal rule: the PRESENTER does not state the problem. The AI discovers it.**

This demo is designed as a guided conversation, not a slide-walk. The presenter
asks open questions and lets the Cortex Agent surface the findings, name the
branches, quantify the impact, and propose the actions. The audience should feel
like they are watching a real analyst at work, not a rehearsed script.

## Demo Flow (30-45 minutes)

### Act 1: "How are we doing?" (5 min)

Open the **Streamlit Command Center** > Executive Overview page. Let the KPI tiles
speak for themselves: FYAP, achievement %, persistency, loss ratio.

Then switch to the **Cortex Agent** (CoWork / Snowflake Intelligence) and ask:

> "How is Meridian Life doing against plan in 2025?"

The agent will call `query_sales_intelligence` and report that 17 of 23 branches
are below plan. **You do not say "Jember is the worst" — the AI says it.**

### Act 2: "Who needs help the most?" (8 min)

Follow up with:

> "Which 5 branches are most behind and what should we prioritise?"

The agent ranks the critically-below branches (Jember 44%, Pekanbaru 49%...) and
may already surface the East Java pattern. Then ask the "why" question:

> "Why is Jember declining and what should we do?"

This triggers `get_branch_scorecard` + M1 + M6. The agent will produce a
**Findings / Root Cause / Recommendations / Save this?** diagnosis. The audience
sees the model outputs (lapse risk, anomaly, agent scores) woven into a coherent
story — not raw tables.

**Demo talking point:** "Notice we did not tell the AI that Jember was the worst.
We asked an open question and it found the answer by combining seven different
data models in real time."

### Act 3: "What does the product actually cover?" (5 min)

Switch to a product question to show the RAG pipeline:

> "What are the benefits and exclusions of Meridian Sehat Gold?"

The agent uses `search_product_docs`, answers from the brochure, and cites the
product name. Ask a follow-up that crosses the boundary:

> "How many policies of that product did we sell in 2025 and what was the claims
> ratio?"

Now both Cortex Search and Cortex Analyst fire. The audience sees tool routing in
action.

### Act 4: "What should our agents do tomorrow morning?" (8 min)

> "Show me the 20 policies most likely to lapse in Malang and who should call
> them."

The M1 tool returns a call list with lapse probability, premium at risk, CLV
segment, danger-zone flags, and the servicing agent's name. Then:

> "Assign the top 10 retention calls in Malang."

The batch tool fires — no per-agent loop. The audience sees write-back in real
time. Switch to the **Streamlit Action Queue** page and refresh: the assigned
actions appear.

### Act 5: "What's the external context?" (5 min)

> "How does our 83% persistency compare to the Indonesian life insurance
> industry? Search the web."

The agent searches the web, pulls IRDAI benchmarks as a proxy, and attributes
internal vs. external numbers clearly. The audience sees the agent combining
internal analytics with external intelligence.

### Act 6: "Give me the deck" (3 min)

> "Generate a PPTX report for the Jember recovery plan."

A branded 4-slide PowerPoint appears as a clickable download link in the chat.

### Act 7: Closed Loop (5 min)

Open **Streamlit KPI Tracking & Feedback** (page 7). Show the funnel:
recommendations -> feedback -> outcomes. Show the win rate by action type and
the value realisation percentage.

**Demo talking point:** "This is the closed loop. The AI recommends, the human
decides, the field agent executes, and the outcome flows back. The model learns
which recommendations convert and which don't."

## Tips

- **Never pre-answer.** If you know the answer, resist saying it. Ask the AI.
- **Pause after the AI responds.** Let the audience absorb the numbers.
- **"What would you do?"** After Act 2, ask the audience what they would do
  before showing the AI's recommendations. The comparison is powerful.
- **Handle failures gracefully.** If a tool returns an empty result, say "Good —
  that means there are no high-risk policies in this branch. Let's try Malang."
- **The dashboard is the confirmation, not the discovery.** Use Streamlit to
  confirm what the agent found, not to repeat the analysis.
