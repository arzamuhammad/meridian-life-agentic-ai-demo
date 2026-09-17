#!/usr/bin/env python
"""Deduplicate semantic-view synonyms.

Snowflake requires every alias AND synonym in a semantic view to be unique
across the whole object, and a synonym may not collide with a semantic
expression name. This walks the DDL in order, seeds the reserved namespace
with all table aliases and semantic expression names, then drops any synonym
that is already taken (keeping the first occurrence).
"""
import re
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "05_semantic_view/51_semantic_view.sql"

src = open(PATH).read()
m = re.search(r"^AI_SQL_GENERATION", src, re.M)
head, tail = src[: m.start()], src[m.start():]
lines = head.splitlines(keepends=True)

reserved = set()
for line in lines:
    for a in re.findall(r"^\s*(?:\w+\.)?(\w+)\s+AS\s", line):
        reserved.add(a.lower())
    for a in re.findall(r"^\s*(\w+)\s+AS\s+INSURANCE_DEMO", line):
        reserved.add(a.lower())

used, removed, out = set(reserved), [], []
for i, line in enumerate(lines, 1):
    mm = re.search(r"(WITH SYNONYMS\s*=\s*\()([^)]*)(\))", line)
    if not mm:
        out.append(line)
        continue
    keep = []
    for syn in re.findall(r"'([^']*)'", mm.group(2)):
        key = syn.strip().lower()
        if key in used:
            removed.append((i, syn))
        else:
            used.add(key)
            keep.append(syn)
    repl = "WITH SYNONYMS = (" + ",".join(f"'{x}'" for x in keep) + ")" if keep else ""
    out.append(line[: mm.start()] + repl + line[mm.end():])

open(PATH, "w").write("".join(out) + tail)
print(f"reserved names: {len(reserved)}  synonyms kept: {len(used) - len(reserved)}  removed: {len(removed)}")
for i, syn in removed:
    print(f"  line {i}: {syn!r}")
