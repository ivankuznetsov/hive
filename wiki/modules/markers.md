---
title: Hive::Markers
type: module
source: lib/hive/markers.rb
created: 2026-04-25
updated: 2026-07-25
tags: [marker, protocol, flock, recovery, migration]
---

**TLDR**: Locked HTML-comment marker protocol. `Markers.current(path)` returns the *last* marker in a file as a `State` struct; `Markers.set(path, name, attrs)` writes via `flock(LOCK_EX)`, replacing the last marker (or appending if none).

## Marker grammar

```
<!-- WAITING -->
<!-- COMPLETE -->
<!-- AGENT_WORKING pid=12345 started=2026-04-25T10:23:45Z -->
<!-- ERROR reason=timeout timeout_sec=300 marker_id=<hex16> -->
<!-- EXECUTE_WAITING reason=no_worktree_changes -->
<!-- EXECUTE_WAITING reason=dirty_worktree -->
<!-- EXECUTE_WAITING reason=branch_mismatch -->
<!-- EXECUTE_COMPLETE -->
<!-- EXECUTE_COMPLETE mode=research -->

# 6-review stage markers (added in U3):
<!-- REVIEW_WORKING phase=ci pass=1 -->                          # transient — replaced at phase exit
<!-- REVIEW_WAITING escalations=3 pass=2 -->                     # terminal — user inspects escalations
<!-- REVIEW_CI_STALE attempts=3 -->                              # terminal — CI hard-block; reviewers don't run
<!-- REVIEW_STALE pass=4 -->                                     # terminal — max review passes reached
<!-- REVIEW_COMPLETE pass=3 browser=passed -->                   # terminal — ready to run `hive artifacts` into 7-artifacts
<!-- REVIEW_ERROR phase=reviewers reason=all_failed -->          # terminal — agent-level failure
```

Allowlist: see `KNOWN_NAMES` in `lib/hive/markers.rb`.

Every recoverable marker written through `Markers.set` — `ERROR`,
`REVIEW_ERROR`, `REVIEW_STALE`, or `REVIEW_CI_STALE` — receives a generated
`marker_id` unless the caller supplies one. `REVIEW_WORKING` also receives an
identity so a stale-working rewrite cannot race a newer review phase. The
identity is the canonical failure-generation guard for recovery; reason,
mtime, and other attrs are diagnostics, not fallback identities.

`hive migrate` performs the one-off identity backfill for an old recoverable
marker. Runtime recovery rejects an id-less occurrence with
`recovery_migration_required`; it never guesses from mtime or low-cardinality
attrs. The migration uses `Markers.upgrade_recovery_marker_id`, a compare-and-
swap under the marker sidecar lock: it re-reads the exact raw marker observed
by the scan and upgrades only if that occurrence is still current and id-less.
A concurrent agent or operator write therefore wins instead of being replaced
by stale migration input.

`Hive::Daemon::RecoveryCoordinator` is the sole production owner of destructive
recoverable-marker transitions. It calls
`Markers.clear_current(..., purge_history: true)` only after re-resolving the
task, marker identity, safety checks, and durable recovery request under the
task lock. The low-level `hive markers clear` command remains an explicit
operator repair primitive and performs the same history purge after its
current-name and optional attribute guards pass. Both paths remove every
recognized marker comment while preserving surrounding prose, so a successful
retry cannot expose an older shadowed marker.

Regex: `MARKER_RE` enumerates every name in `KNOWN_NAMES`, requires a marker-name boundary, and captures attrs until the terminating `-->` without crossing another `<!--`. Quoted error details may contain `>` (for example Git stderr `branch -> branch`) and newlines. Adding a marker name requires updating BOTH the list AND the regex alternation (they are two sources of truth).

### EXECUTE_* attribute schemas

| Marker | Attributes | Lifecycle |
|--------|------------|-----------|
| `EXECUTE_WAITING` | Current 4-execute pause reasons: `reason=no_worktree_changes`, `dirty_worktree`, `missing_research_output`, `branch_mismatch`, or `head_not_descendant`. Legacy pre-U9 review markers may carry `findings_count=` / `pass=` — these attrs are still parsed but no live consumer reads them (the TUI triage mode that once routed off `findings_count` was removed). | Terminal until the user/agent fixes the worktree, updates plan frontmatter, or reruns the implementer. |
| `EXECUTE_COMPLETE` | No attrs for normal implementation commits. `mode=research` when `plan.md` explicitly declares `execution_mode: research` and a structured final agent message was captured. | Terminal success — ready to move to 6-review. |
| `EXECUTE_STALE` | Legacy review-loop stale marker. | No longer written by current 4-execute; retained for historical recovery. |

### REVIEW_* attribute schemas

| Marker | Attributes | Lifecycle |
|--------|------------|-----------|
| `REVIEW_WORKING` | `phase=ci\|reviewers\|triage\|fix\|browser`, `pass=NN` | Transient — set at phase entry, replaced at phase exit per ADR-005's last-marker-wins. |
| `REVIEW_WAITING` | Two shapes per `reason` attr: (1) **escalations-only** (no `reason`): `escalations=N`, `pass=NN` — user inspects `reviews/escalations-NN.md`. (2) **`reason=fix_guardrail`**: `matches=N`, `head=<sha>`, `pass=NN` — user inspects `reviews/fix-guardrail-NN.md` and ticks every `[x]` to approve; approval re-checks count + HEAD + worktree-clean. Legacy markers without `head=` (hive ≤ PR-A round-2) skip the HEAD check with a stderr notice. Reviewer infra failures now use `REVIEW_ERROR phase=reviewers reason=reviewer_partial_failure` because no user answer is required. | Terminal until next `hive run`. |
| `REVIEW_CI_STALE` | `attempts=N` | Terminal — `cfg.review.ci.max_attempts` reached without green CI. Reviewers don't run on red CI. After inspecting or editing `reviews/ci-blocked.md`, submit retry through the TUI, web, bot, or `Hive::Recovery::API`; the coordinator owns the guarded transition. |
| `REVIEW_STALE` | `pass=NN` | Terminal — `cfg.review.max_passes` reached. If highest-NN reviewer files have no `escalations-NN.md`, the incomplete triage pass is directly retryable. Otherwise edit reviewer files / escalations, then use the TUI's forced `r` recovery gesture; both paths submit to the coordinator. |
| `REVIEW_COMPLETE` | `pass=NN`, `browser=passed\|warned\|skipped` | Terminal success — ready to run `hive artifacts` into 7-artifacts. `browser=warned` means browser test failed twice but loop continued (soft-warn); 8-finalize stage surfaces this in the PR body. |
| `REVIEW_ERROR` | `phase=...`, `reason=...`; optional `message="..."` for phase-agent failures whose captured cause should be visible in status diagnostics; `retry_after=<iso8601>` for `reason=limits_reached`. Known `phase=resume` `reason=` values (added in PR-A round-3): `approval_head_mismatch` (worktree HEAD differs from marker `head=`), `approval_dirty_worktree` (uncommitted edits in worktree at approval time), `malformed_marker_matches` (fix_guardrail marker has missing/non-Integer `matches`), `resume_no_findings` (legacy: reviewer files were deleted between trip and resume). Triage/fix phase-agent non-limit failures are written through `Hive::ReviewErrorReason` as `merge_conflict`, `network_timeout`, `tool_permission_denied`, `agent_crashed`, or `unknown`; provider limits still write `limits_reached` first. In practice the plumbing forwards a condensed wrapper string (not raw agent output), so the specific buckets rarely fire and the reason normally lands on `unknown` with the raw cause in `message=` — see [[stages/review]]. Other phase/reason families (`phase=fix reason=fix_tampered`, `phase=reviewers reason=reviewer_partial_failure`, etc.) per the runner's protected-files + agent-error contracts. | Terminal agent-level error or protected-file tampering. Every persisted occurrence enters the shared recovery lifecycle after the configured cooldown when its safety gates permit; provider-limit metadata affects explanation, not eligibility. |

## `State` struct

```ruby
State = Struct.new(:name, :attrs, :raw, keyword_init: true)
# name: Symbol (downcased — :waiting, :execute_waiting, :none)
# attrs: Hash<String, String>
# raw: original marker text
# none?: true when name == :none
```

## `current(path)`

- Returns `State(name: :none, attrs: {}, raw: nil)` if the file is missing.
- Otherwise scans the entire content with `MARKER_RE` and keeps the *last* match.
- Returns `:none` if no markers are present (e.g. an in-flight agent that hasn't written one yet).

## `set(path, name, attrs = {})`

- `name` is upcased; raises `ArgumentError` if not in `KNOWN_NAMES`.
- Builds the marker text via `build_marker`. Attribute values containing whitespace get double-quoted. Double quotes are normalized to single quotes, `<!--` is rewritten to `< !--`, and `-->` is rewritten to `-- >` so generated attrs cannot confuse HTML-comment marker boundaries.
- Opens the file with `RDWR | CREAT, 0o644`, takes `LOCK_EX`, reads the full body, replaces the *last* marker via `replace_last_marker`, or appends if none. Truncates and rewrites in place.
- This locking is what makes concurrent writes from `Hive::Agent` (during a run) and `Markers.set` (from tests or recovery) safe.

## `parse_attrs`

Parses the attribute string into a Hash. Format: `key=value` pairs, optional double-quoted values for whitespace-containing payloads. Quoted values may span newlines and may contain `>` characters; parsing stops at the closing quote, not at branch-arrow text. Regex: `/(\w[\w-]*)=("[^"]*"|\S+)/`.

## Tests

- `test/unit/markers_test.rb` — round-trip set/get, attribute quoting/sanitization, last-marker semantics, missing-file handling, Git stderr attrs containing `branch -> branch`, and migration compare-and-swap refusal after a newer generation lands.

## Used by

- `Hive::Agent#run!` writes `AGENT_WORKING` pre-spawn and `ERROR` on failure.
- Every `Stages::*.run!` reads the post-run marker to derive the run's status and commit action.
- `Stages::Execute#run_pass` writes `EXECUTE_WAITING` / `EXECUTE_COMPLETE` after validating final output, branch ancestry, worktree cleanliness, and research-mode eligibility.
- `Stages::Review.run!` writes `REVIEW_WORKING` at every phase entry; the orchestrator owns every terminal `REVIEW_*` marker per ADR-005's last-marker-wins rule.
- `Hive::Commands::Status` reads markers to render the table.

## Backlinks

- [[state-model]]
- [[modules/agent]]
- [[stages/execute]]
