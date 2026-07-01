# diagnose evidence resolver — never-block / never-raise hardening

**Action:** Second review pass on the `--diagnose` evidence fallback
([[commands/status]]), closing reliability and isolation gaps in
`Hive::DiagnosticEvidence` (and mirroring the security fixes in
`TaskAction::Diagnostic`):

- **Never-block on non-regular files.** `contained?` now gates every tier on
  `File.file?(real)` (realpath first so a symlink loop still warns), so a FIFO /
  socket / device / directory named like evidence (`*.log`, `*.md`,
  `red-status.md`) is refused before any `open(2)`. Previously only the red tier
  guarded this; a FIFO in `logs/` could wedge the bot reaper thread permanently.
- **Symlinked evidence *directory* escape.** `realpath_or_expand` now rejects a
  root whose own leaf is a symlink (`File.symlink?`), so a `logs -> /outside`
  directory symlink can no longer resolve into a TRUSTED root and leak arbitrary
  host `*.log` contents. A symlinked *ancestor* (the legit `.hive-state -> /vol`
  deployment) still resolves normally because only the leaf is checked. Mirrored
  in `Diagnostic#diagnostic_roots`.
- **Bounded marker read.** The marker tier was the only unbounded read (asymmetric
  with the 16 KB red / 8 KB log tiers); an oversized `*.md` (e.g. a multi-MB
  `artifacts.md` swept up by the bot glob) could raise `NoMemoryError` through the
  rescue. `current_marker` now skips candidates above `MARKER_READ_MAX` (1 MiB)
  with a breadcrumb.
- **LoadError no longer escapes.** The lazy `require "hive/task"` in
  `inferred_task_log_dir` now rescues `LoadError` (a `ScriptError`, not a
  `StandardError`) so a cold caller can't reintroduce a raise past summarize's
  boundary.
- **Newest-log correctness (plan R2).** `log_candidates` now sorts by mtime
  *before* capping at `LOG_GLOB_CAP`, so the freshest log is considered even when
  its filename sorts earlier than older logs. (The producer's
  `latest_log_artifacts` keeps its filename-first cap deliberately — it runs on
  every status poll and trades exactness for a bounded stat sweep.)
- **Smaller correctness/clarity fixes:** path blank-check (`present_path`) no
  longer whitespace-collapses a filesystem path; `current_marker`'s
  invalid-UTF-8 `ArgumentError` now leaves a breadcrumb; the `kind → (source,
  label)` mapping is one `.fetch`-ed table (`KIND_RENDERING`) so an unmapped kind
  raises instead of silently shipping `source:"artifact"`; the evidence-tier
  `detail` is truncated to `DETAIL_MAX`; internals are `private_class_method` so
  only `summarize`/`source_label`/`source_kind` are public; the dead `TAIL_BYTES`
  aliases were removed.

**Envelope/schema:** Added an optional `state_file` field to the
`hive-status-diagnose` SuccessPayload (the authoritative state file the
`marker_summary` was read from) and threaded it through the bot so the marker
tier's `source_path` pins to the same file the CLI did, instead of the first
`*.md` glob hit under an advanced folder. `marker_summary` was relaxed from
`required` to optional so adding it (and `state_file`) stays a non-breaking
additive change per `lib/hive.rb` — no v3 bump. The `detail` schema description
now notes the evidence path emits a one-line `Label: path` pointer.

**Coverage:** Added regression tests for the FIFO guard, the directory-symlink
escape (resolver and producer), red-status/marker-tier symlink refusals, the
no-trailing-newline boundary secret, newest-log-by-mtime, the `:agent_died`
stale-agent variant, oversized/LoadError degradation, the bot marker-tier
state-file pin, `Markers.summary(:none) → null` end-to-end, and the `detail` cap.
