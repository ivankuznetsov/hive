# 2026-07-27 — Pin upload-artifact v7.0.1 across workflows

**Why:** The dependency update advanced all upload sites but left most
workflows trusting a mutable major/minor tag, while the Agent CLI Runtime
release already used an immutable action commit.

**Change:** All seven `actions/upload-artifact` calls now use the immutable
v7.0.1 commit. Existing archive, missing-file, hidden-file, and retention
settings are unchanged.

**Boundary:** v7 uses Node 24 and therefore requires Actions Runner 2.327.1 or
newer. Hive's upload jobs use GitHub-hosted runners, and the new direct-upload
mode remains disabled so downstream archive downloads keep their current
shape.
