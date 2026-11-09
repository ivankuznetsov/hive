# 2026-11-05 — Muse 6-review reviewer

**Action:** `hive init` offered `muse-ce-code-review`, but
`templates/project_config.yml.erb` had no block for it and there was no
prompt template, so selecting it silently produced no reviewer. Added
`templates/reviewer_muse_ce_code_review.md.erb`, the init render block, and a
`muse` entry in `Hive::Reviewers::ROUTED_REVIEW_TEMPLATES` (explicitly routed
native reviews on a Muse adapter now get the Muse template instead of the
Codex one).

**Verification:** init, reviewer, reviewer-diff-range, and config-defaults
doc tests pass locally.
