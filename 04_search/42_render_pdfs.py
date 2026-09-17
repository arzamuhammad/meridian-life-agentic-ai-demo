#!/usr/bin/env python
"""
MERIDIAN LIFE — Step 3b: render the AI-generated brochures to branded PDFs
and upload them to @INSURANCE_DEMO.CORE.STAGE_DOC.

Reads PRODUCT_BROCHURE_TEXT (Markdown), renders one PDF per product with a
Meridian Life cover header / footer, then PUTs the files to the stage so
AI_PARSE_DOCUMENT can read them.

Usage:  python 42_render_pdfs.py
"""
import os
import re
import sys
import html
import tomllib
import snowflake.connector
from reportlab.lib import colors
from reportlab.lib.enums import TA_JUSTIFY
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import mm
from reportlab.platypus import (SimpleDocTemplate, Paragraph, Spacer, Table,
                                TableStyle, HRFlowable)

CONN_NAME = os.environ.get("SNOWFLAKE_CONNECTION_NAME", "default")
DATABASE, SCHEMA, STAGE = "INSURANCE_DEMO", "CORE", "STAGE_DOC"
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pdf_out")

BRAND_DARK = colors.HexColor("#0E5C63")   # Meridian teal
BRAND_GOLD = colors.HexColor("#D4A03C")
BRAND_GREY = colors.HexColor("#4A5568")


def connect():
    with open(os.path.expanduser("~/.snowflake/connections.toml"), "rb") as fh:
        cfg = tomllib.load(fh)[CONN_NAME]
    kw = dict(account=cfg["account"], user=cfg["user"],
              role=cfg.get("role", "ACCOUNTADMIN"),
              warehouse=cfg.get("warehouse", "GEN2_SMALL"),
              database=DATABASE, schema=SCHEMA)
    if "token_file_path" in cfg:
        with open(os.path.expanduser(cfg["token_file_path"])) as fh:
            kw["password"] = fh.read().strip()
    else:
        kw["password"] = cfg["password"]
    return snowflake.connector.connect(**kw)


def styles():
    ss = getSampleStyleSheet()
    return {
        "h1": ParagraphStyle("h1", parent=ss["Heading1"], fontSize=18, leading=22,
                             textColor=BRAND_DARK, spaceBefore=6, spaceAfter=10),
        "h2": ParagraphStyle("h2", parent=ss["Heading2"], fontSize=13, leading=16,
                             textColor=BRAND_DARK, spaceBefore=12, spaceAfter=6),
        "h3": ParagraphStyle("h3", parent=ss["Heading3"], fontSize=11, leading=14,
                             textColor=BRAND_GREY, spaceBefore=8, spaceAfter=4),
        "body": ParagraphStyle("body", parent=ss["BodyText"], fontSize=9.5, leading=13.5,
                               alignment=TA_JUSTIFY, spaceAfter=6),
        "bullet": ParagraphStyle("bullet", parent=ss["BodyText"], fontSize=9.5, leading=13.5,
                                 leftIndent=12, bulletIndent=3, spaceAfter=3),
        "cell": ParagraphStyle("cell", parent=ss["BodyText"], fontSize=8.5, leading=11),
        "cellh": ParagraphStyle("cellh", parent=ss["BodyText"], fontSize=8.5, leading=11,
                                textColor=colors.white),
        "meta": ParagraphStyle("meta", parent=ss["BodyText"], fontSize=8.5, leading=11,
                               textColor=BRAND_GREY),
        "foot": ParagraphStyle("foot", parent=ss["BodyText"], fontSize=7.5, leading=10,
                               textColor=BRAND_GREY),
    }


def inline(text):
    """Escape XML then re-apply the small subset of Markdown reportlab supports."""
    t = html.escape(text, quote=False)
    t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
    t = re.sub(r"(?<!\w)\*(?!\s)(.+?)(?<!\s)\*(?!\w)", r"<i>\1</i>", t)
    t = re.sub(r"`(.+?)`", r'<font face="Courier">\1</font>', t)
    return t


def split_row(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def render_table(rows, st, width):
    if not rows:
        return None
    ncols = max(len(r) for r in rows)
    rows = [r + [""] * (ncols - len(r)) for r in rows]
    data = [[Paragraph(inline(c), st["cellh"] if i == 0 else st["cell"]) for c in r]
            for i, r in enumerate(rows)]
    tbl = Table(data, colWidths=[width / ncols] * ncols, repeatRows=1, hAlign="LEFT")
    tbl.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), BRAND_DARK),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#CBD5E0")),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#F2F6F7")]),
        ("LEFTPADDING", (0, 0), (-1, -1), 5),
        ("RIGHTPADDING", (0, 0), (-1, -1), 5),
        ("TOPPADDING", (0, 0), (-1, -1), 3),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ]))
    return tbl


def md_to_flowables(md, st, width):
    """Minimal Markdown -> reportlab: headings, bullets, ordered lists, tables."""
    flow, tbuf, pbuf = [], [], []

    def flush_para():
        if pbuf:
            flow.append(Paragraph(inline(" ".join(pbuf)), st["body"]))
            pbuf.clear()

    def flush_table():
        if tbuf:
            # drop the markdown separator row (|---|---|)
            rows = [r for r in tbuf if not re.fullmatch(r"[\s\|:\-]+", "|".join(r))]
            t = render_table(rows, st, width)
            if t is not None:
                flow.extend([Spacer(1, 4), t, Spacer(1, 8)])
            tbuf.clear()

    for raw in md.splitlines():
        line = raw.rstrip()
        if line.strip().startswith("|") and line.count("|") >= 2:
            flush_para()
            tbuf.append(split_row(line))
            continue
        flush_table()
        if not line.strip():
            flush_para()
            continue
        m = re.match(r"^(#{1,4})\s+(.*)$", line)
        if m:
            flush_para()
            lvl = min(len(m.group(1)), 3)
            flow.append(Paragraph(inline(m.group(2)), st[f"h{lvl}"]))
            continue
        m = re.match(r"^\s*[-*+]\s+(.*)$", line)
        if m:
            flush_para()
            flow.append(Paragraph(inline(m.group(1)), st["bullet"], bulletText="\u2022"))
            continue
        m = re.match(r"^\s*(\d+)[.)]\s+(.*)$", line)
        if m:
            flush_para()
            flow.append(Paragraph(inline(m.group(2)), st["bullet"],
                                  bulletText=f"{m.group(1)}."))
            continue
        if re.fullmatch(r"-{3,}|\*{3,}|_{3,}", line.strip()):
            flush_para()
            flow.append(HRFlowable(width="100%", color=colors.HexColor("#CBD5E0")))
            continue
        pbuf.append(line.strip())

    flush_para()
    flush_table()
    return flow


def build_pdf(path, row, st):
    (pid, pcode, pname, pclass, ptype, tier, minprem, term, md) = row
    doc = SimpleDocTemplate(
        path, pagesize=A4,
        leftMargin=18 * mm, rightMargin=18 * mm,
        topMargin=16 * mm, bottomMargin=16 * mm,
        title=f"{pname} - Product Brochure", author="Meridian Life (fictional)",
        subject=f"{pclass} / {ptype}",
    )
    width = doc.width
    flow = [
        Paragraph("MERIDIAN LIFE", ParagraphStyle(
            "brand", fontName="Helvetica-Bold", fontSize=10, textColor=BRAND_GOLD,
            spaceAfter=2)),
        Paragraph("Product Brochure", st["meta"]),
        HRFlowable(width="100%", thickness=1.6, color=BRAND_DARK,
                   spaceBefore=4, spaceAfter=8),
        Paragraph(inline(pname), st["h1"]),
    ]
    meta = render_table([
        ["Product Code", "Category", "Contract Type", "Tier", "Min. Annual Premium", "Policy Term"],
        [pcode, pclass, ptype, tier, f"Rp {int(minprem):,}".replace(",", "."), f"{term} years"],
    ], st, width)
    flow.extend([meta, Spacer(1, 10)])
    # strip a duplicate H1 that repeats the product name
    body = re.sub(r"^\s*#\s+" + re.escape(pname) + r"\s*$", "", md, count=1, flags=re.M)
    flow.extend(md_to_flowables(body, st, width))
    flow.extend([
        Spacer(1, 12),
        HRFlowable(width="100%", color=colors.HexColor("#CBD5E0")),
        Paragraph(
            "Meridian Life is a fictional insurer created for a software demonstration. "
            "All products, figures, and terms in this document are illustrative only and do "
            "not constitute an insurance contract, an offer, or financial advice. "
            f"Document reference: {pcode} / {pid}.", st["foot"]),
    ])
    doc.build(flow)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    con = connect()
    cur = con.cursor()
    cur.execute("""
        SELECT PRODUCT_ID, PRODUCT_CODE, PRODUCT_NAME, CLASSIFICATION, PRODUCT_TYPE,
               TIER_LABEL, MIN_ANNUAL_PREMIUM, DEFAULT_TERM_YEARS, BROCHURE_MD
        FROM PRODUCT_BROCHURE_TEXT ORDER BY PRODUCT_ID
    """)
    rows = cur.fetchall()
    print(f"Rendering {len(rows)} brochures -> {OUT_DIR}")

    st = styles()
    made = []
    for row in rows:
        pid, pcode, pname = row[0], row[1], row[2]
        fname = re.sub(r"[^A-Za-z0-9]+", "_", pname).strip("_") + f"_{pid}.pdf"
        path = os.path.join(OUT_DIR, fname)
        build_pdf(path, row, st)
        made.append((fname, os.path.getsize(path)))
        print(f"  {fname:<58} {os.path.getsize(path)/1024:6.1f} KB")

    print(f"\nUploading to @{DATABASE}.{SCHEMA}.{STAGE} ...")
    cur.execute(f"REMOVE @{STAGE}")
    put = cur.execute(
        f"PUT 'file://{OUT_DIR}/*.pdf' @{STAGE} AUTO_COMPRESS=FALSE OVERWRITE=TRUE"
    ).fetchall()
    ok = sum(1 for r in put if str(r[6]).upper() in ("UPLOADED", "SKIPPED"))
    print(f"  uploaded/skipped: {ok} of {len(put)}")

    cur.execute(f"ALTER STAGE {STAGE} REFRESH")
    n = cur.execute(f"SELECT COUNT(*) FROM DIRECTORY(@{STAGE})").fetchone()[0]
    print(f"  files visible in DIRECTORY(@{STAGE}): {n}")
    con.close()
    return 0 if n == len(rows) else 1


if __name__ == "__main__":
    sys.exit(main())
