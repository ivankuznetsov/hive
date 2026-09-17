---
slug: implement-prdigest-v0-1-0-260715-fe8f
created_at: 2026-07-15T14:57:51Z
original_text: |
  Implement prdigest v0.1.0 from the completed architecture-plan handoff.
  
  Source of truth: <architecture-repository>/.hive-state/stages/4-done/standalone-open-source-project-prdigest-260715-04ea/plan.md
  Repository: https://github.com/ivankuznetsov/prdigest (work in <prdigest-repository>).
  
  Build on the existing Ruby gem scaffold; do not restart it. Follow milestones in order:
  - M1: add tzinfo; implement Clock, versioned atomic State, capped Schedule, including DST and corrupt/missing-state tests.
  - M2: implement Octokit GitHub merged-PR search by repo and UTC day window, pagination, optional detail stats, retry/error mapping, WebMock fixtures, and manually validate D1 query semantics without putting tokens in artifacts.
  - M3: implement deterministic Telegram HTML renderer, config-order grouping, totals/footer, empty days, hostile-title escaping, and 4096-character section-aware splitting with golden tests.
  - M4: implement Net::HTTP Telegram sendMessage client, sender-level chat allowlist refusal, 429 retry_after behavior, message pacing, and token-redacted errors with WebMock tests.
  - M5: integrate Runner and CLI: per-day state advancement, dry-run, explicit date override bypassing state, JSON results, meaningful exit codes, catch-up and partial-failure tests. Resolve R6 safely: PRDIGEST_CONFIG, then /etc/prdigest/config.yml if present, otherwise require --config.
  - M6: production packaging/docs: Alpine tzdata and non-root image, modern Bundler config, verified systemd walkthrough, PAT/bot scoping docs, changelog and release readiness.
  
  Fixed contracts: deterministic/no LLM output; explicit owner/name repos only; one allowlisted delivery chat; one message per owed day oldest-first; tokens only from ENV and never logged; HTML parse mode; sender-level allowlist defense; state advances immediately after each settled day; all automated tests run offline.
  
  Acceptance criteria:
  - All M1-M6 implementation and offline tests pass in CI.
  - Existing scaffold behavior remains compatible except for the documented safe production config-path change.
  - GitHub/Telegram failures never advance state for the failed day; catch-up retries correctly.
  - Dry-run performs no Telegram send and JSON/human output contains no secrets.
  - Do not add Hive integration, a web UI, non-GitHub forges, multi-chat routing, or long-running serve scheduling.
  - Do not publish the gem or create a release/tag automatically; prepare v0.1.0 and leave publication for explicit operator approval.
  
  Reviewers are codex-ce-code-review and grok-ce-code-review. Preserve both unless Grok explicitly reports its weekly usage limit; only then continue with Codex alone.
---

# implement-prdigest-v0-1-0-260715-fe8f

Implement prdigest v0.1.0 from the completed architecture-plan handoff.

Source of truth: <architecture-repository>/.hive-state/stages/4-done/standalone-open-source-project-prdigest-260715-04ea/plan.md
Repository: https://github.com/ivankuznetsov/prdigest (work in <prdigest-repository>).

Build on the existing Ruby gem scaffold; do not restart it. Follow milestones in order:
- M1: add tzinfo; implement Clock, versioned atomic State, capped Schedule, including DST and corrupt/missing-state tests.
- M2: implement Octokit GitHub merged-PR search by repo and UTC day window, pagination, optional detail stats, retry/error mapping, WebMock fixtures, and manually validate D1 query semantics without putting tokens in artifacts.
- M3: implement deterministic Telegram HTML renderer, config-order grouping, totals/footer, empty days, hostile-title escaping, and 4096-character section-aware splitting with golden tests.
- M4: implement Net::HTTP Telegram sendMessage client, sender-level chat allowlist refusal, 429 retry_after behavior, message pacing, and token-redacted errors with WebMock tests.
- M5: integrate Runner and CLI: per-day state advancement, dry-run, explicit date override bypassing state, JSON results, meaningful exit codes, catch-up and partial-failure tests. Resolve R6 safely: PRDIGEST_CONFIG, then /etc/prdigest/config.yml if present, otherwise require --config.
- M6: production packaging/docs: Alpine tzdata and non-root image, modern Bundler config, verified systemd walkthrough, PAT/bot scoping docs, changelog and release readiness.

Fixed contracts: deterministic/no LLM output; explicit owner/name repos only; one allowlisted delivery chat; one message per owed day oldest-first; tokens only from ENV and never logged; HTML parse mode; sender-level allowlist defense; state advances immediately after each settled day; all automated tests run offline.

Acceptance criteria:
- All M1-M6 implementation and offline tests pass in CI.
- Existing scaffold behavior remains compatible except for the documented safe production config-path change.
- GitHub/Telegram failures never advance state for the failed day; catch-up retries correctly.
- Dry-run performs no Telegram send and JSON/human output contains no secrets.
- Do not add Hive integration, a web UI, non-GitHub forges, multi-chat routing, or long-running serve scheduling.
- Do not publish the gem or create a release/tag automatically; prepare v0.1.0 and leave publication for explicit operator approval.

Reviewers are codex-ce-code-review and grok-ce-code-review. Preserve both unless Grok explicitly reports its weekly usage limit; only then continue with Codex alone.

<!-- WAITING -->
