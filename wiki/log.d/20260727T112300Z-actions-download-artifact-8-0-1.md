# 2026-07-27 — Pin download-artifact v8.0.1 across workflows

**Why:** The dependency update advanced every download site but left most
workflow calls trusting a mutable version tag.

**Change:** All nine `actions/download-artifact` calls now use the immutable
v8.0.1 commit. Existing artifact names, patterns, merge behavior, and
destinations are unchanged.

**Boundary:** v8 fails closed on an artifact digest mismatch and understands
both archived and direct-upload artifacts. Hive currently downloads archived
artifacts produced by its paired upload steps, so decompression behavior
remains unchanged. All consumers use GitHub-hosted Node 24-capable runners.
