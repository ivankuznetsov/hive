---
title: Hive::Markers
type: module
source: lib/hive/markers.rb
created: 2026-04-25
updated: 2026-04-25
tags: [marker, protocol, flock]
---

**TLDR**: Locked HTML-comment marker protocol. `Markers.current(path)` returns the *last* marker in a file as a `State` struct; `Markers.set(path, name, attrs)` writes via `flock(LOCK_EX)`, replacing the last marker (or appending if none).

## Marker grammar

```
<!-- WAITING -->
<!-- COMPLETE -->
<!-- AGENT_WORKING pid=12345 started=2026-04-25T10:23:45Z -->
<!-- ERROR reason=timeout timeout_sec=300 -->
<!-- EXECUTE_WAITING findings_count=3 pass=2 -->
<!-- EXECUTE_COMPLETE pass=2 -->
<!-- EXECUTE_STALE max_passes=4 pass=4 -->

# 5-review stage markers (added in U3):
<!-- REVIEW_WORKING phase=ci pass=1 -->                          # transient — replaced at phase exit
<!-- REVIEW_WAITING escalations=3 pass=2 -->                     # terminal — user inspects escalations
<!-- REVIEW_CI_STALE attempts=3 -->                              # terminal — CI hard-block; reviewers don't run
<!-- REVIEW_STALE pass=4 -->                                     # terminal — max review passes reached
<!-- REVIEW_COMPLETE pass=3 browser=passed -->                   # terminal — ready to mv to 6-pr
<!-- REVIEW_ERROR phase=reviewers reason=all_failed -->          # terminal — agent-level failure
```

Allowlist: see `KNOWN_NAMES` in `lib/hive/markers.rb` (twelve names total — six pre-U3, six REVIEW_* added in U3).

Regex: `MARKER_RE` enumerates every name in `KNOWN_NAMES`. Adding a marker name requires updating BOTH the list AND the regex alternation (they are two sources of truth).

### REVIEW_* attribute schemas

| Marker | Attributes | Lifecycle |
|--------|------------|-----------|
| `REVIEW_WORKING` | `phase=ci\|reviewers\|triage\|fix\|browser`, `pass=NN` | Transient — set at phase entry, replaced at phase exit per ADR-005's last-marker-wins. |
| `REVIEW_WAITING` | `escalations=N`, `pass=NN` | Terminal until next `hive run` (user inspects `reviews/escalations-NN.md` and edits). |
| `REVIEW_CI_STALE` | `attempts=N` | Terminal — `cfg.review.ci.max_attempts` reached without green CI. Reviewers don't run on red CI. Recovery: edit `reviews/ci-blocked.md`, remove the marker, re-run. |
| `REVIEW_STALE` | `pass=NN` | Terminal — `cfg.review.max_passes` reached. Recovery: edit reviewer files / escalations.md, delete or rename the highest-NN reviewer files, remove the marker, re-run. |
| `REVIEW_COMPLETE` | `pass=NN`, `browser=passed\|warned\|skipped` | Terminal success — ready to `mv` to 6-pr. `browser=warned` means browser test failed twice but loop continued (soft-warn); 6-pr stage surfaces this in the PR body. |
| `REVIEW_ERROR` | `phase=…`, `reason=…` | Terminal — agent-level error or protected-file tampering. Mirrors ADR-013's `:error` shape for `EXECUTE_*`. |

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
- Builds the marker text via `build_marker`. Attribute values containing whitespace get double-quoted.
- Opens the file with `RDWR | CREAT, 0o644`, takes `LOCK_EX`, reads the full body, replaces the *last* marker via `replace_last_marker`, or appends if none. Truncates and rewrites in place.
- This locking is what makes concurrent writes from `Hive::Agent` (during a run) and `Markers.set` (from tests or recovery) safe.

## `parse_attrs`

Parses the attribute string into a Hash. Format: `key=value` pairs, optional double-quoted values for whitespace-containing payloads. Regex: `/(\w[\w-]*)=("[^"]*"|\S+)/`.

## Tests

- `test/unit/markers_test.rb` — round-trip set/get, attribute quoting, last-marker semantics, missing-file handling.

## Used by

- `Hive::Agent#run!` writes `AGENT_WORKING` pre-spawn and `ERROR` on failure.
- Every `Stages::*.run!` reads the post-run marker to derive the run's status and commit action.
- `Stages::Execute#finalize_review_state` writes `EXECUTE_WAITING` / `EXECUTE_COMPLETE`.
- `Stages::Review.run!` (U9, future) writes `REVIEW_WORKING` at every phase entry; the orchestrator owns every terminal `REVIEW_*` marker per ADR-005's last-marker-wins rule.
- `Hive::Commands::Status` reads markers to render the table.

## Backlinks

- [[state-model]]
- [[modules/agent]]
- [[stages/execute]]
