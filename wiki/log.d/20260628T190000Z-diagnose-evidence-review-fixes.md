# diagnose evidence resolver — review fixes

**Action:** Hardened and de-duplicated the `--diagnose` evidence fallback
([[commands/status]]) after code review:

- Extracted `Hive::Markers.summary(marker)` as the single NAME+attrs marker
  rendering; `Diagnostic#marker_summary`, `Status#marker_summary`, and
  `DiagnosticEvidence` now delegate to it (was triplicated). Returns nil for the
  `:none` marker so a markerless task's envelope reads `marker_summary: null`,
  not `"NONE"`.
- Added `Hive::DiagnosticHelpers` to hold the schema-pinned caps
  (`SUMMARY_MAX`/`TAIL_BYTES`/`LOG_GLOB_CAP`/`FRONTMATTER_SCAN_BYTES`) and the
  `tail_file`/`truncate`/`safe_mtime`/`utf8` helpers shared by both diagnose
  surfaces, so the two can't truncate or tail differently.
- `tail_file` now drops the partial first line when the read began mid-file,
  closing a tail-boundary redaction bypass (a secret split across the 8 KB
  window could survive prefix-anchored `SecretPatterns`). Applies to both
  `DiagnosticEvidence` and `TaskAction::Diagnostic`.
- The resolver carries an explicit `kind` tier (`:red_status`/`:log`/`:marker`)
  so the CLI detail line and bot reply label the source `Diagnostics:`/`Log:`/
  `Marker:` instead of always `Log:`. The authoritative `state_file` is threaded
  in so the marker tier's `source_path` and `marker_signature` describe the same
  file.
- Symlink-escape guard mirroring `Diagnostic#safe_diagnostic_artifact?`: evidence
  whose realpath escapes the task/log roots is refused before any read.
- `inferred_task_log_dir` reuses `Hive::Task::PATH_RE` (lazy require) instead of a
  second hand-rolled layout regex.
- Error handling: outer `rescue` on `summarize` (never crash a reply); leaf
  rescues split `ENOENT` (silent) from other `SystemCallError` (warn breadcrumb);
  `current_marker` drops the dead `EncodingError` rescue and documents the
  `ArgumentError` (invalid-UTF-8 scan) case.
- `marker_summary` is routed through `SecretPatterns.redact` before it enters the
  JSON envelope.

**Coverage:** Strengthened the R4 net to exercise the marker-only resolver path
for real (no planted log) and to assert red + synthetic states (PLAN_MISSING_
OUTPUT / FINALIZE_* / stale-agent) on the production `TaskAction` path. Added
large-tail seek, tail-boundary secret, symlink-escape, authoritative-state-file
threading, and breadcrumb tests, plus a JSONSchemer round-trip on the real
evidence envelope and tier-prefix assertions in the CLI/bot tests.

**Docs:** Updated [[commands/status]] to record the deliberate read-path
divergence (non-red rows get a non-null diagnostic here, so `diagnostic == null`
is not a health signal), the inferred global `.hive-state/logs/<slug>/*.log`
source, and the tier-derived detail prefix.
