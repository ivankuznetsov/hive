# 2026-07-27 — Pin github-script v9 for trusted skill checks

**Why:** The live-agent proof workflow moved to github-script v9 but still
trusted the mutable major tag.

**Change:** The single `actions/github-script` call now pins the immutable
v9.0.0 commit.

**Boundary:** Hive's script uses only the injected `github` and `context`
objects. It neither imports the now-ESM-only `@actions/github` package nor
declares `getOctokit`, so v9's breaking context changes do not affect it.
