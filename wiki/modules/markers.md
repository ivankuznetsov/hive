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
```

Allowlist: `KNOWN_NAMES = %w[WAITING COMPLETE AGENT_WORKING ERROR EXECUTE_WAITING EXECUTE_COMPLETE EXECUTE_STALE]`.

Regex (single source of truth): `MARKER_RE = /<!--\s*(?<name>WAITING|COMPLETE|AGENT_WORKING|ERROR|EXECUTE_WAITING|EXECUTE_COMPLETE|EXECUTE_STALE)(?<attrs>(?:\s+[^<>]*?)?)\s*-->/`.

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
- `Hive::Commands::Status` reads markers to render the table.

## Backlinks

- [[state-model]]
- [[modules/agent]]
- [[stages/execute]]
