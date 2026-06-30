# diagnose evidence resolver — review pass 3 hardening

**Action:** Third review pass on the `--diagnose` evidence fallback
([[commands/status]]), closing the remaining never-raise / never-block /
consistency gaps in `Hive::DiagnosticEvidence` and mirroring them in
`TaskAction::Diagnostic`:

- **`SystemStackError` / `NoMemoryError` no longer escape (never-raise).**
  Deeply-nested flow YAML in `diagnostics/red-status.md` frontmatter makes
  `YAML.safe_load` raise `SystemStackError` — which is **not** a
  `Psych::Exception` and **not** a `StandardError`, so it slipped past both
  `red_status_frontmatter_summary`'s rescue and `summarize`'s `StandardError`
  boundary and would kill the no-timeout bot reaper thread. Both rescues now also
  catch `SystemStackError`/`NoMemoryError`, and the same widening was applied to
  the producer's `Diagnostic#diagnostic_frontmatter` (whose un-widened rescue let
  a corrupt red-status.md on a red task crash the whole `hive status --json`
  snapshot past the per-project `rescue StandardError`).
- **Never-block extended to the authoritative `state_file`.** The caller-supplied
  state-file pin (`marker_summary_from_state_file → current_marker`) bypassed
  `contained?`, so a FIFO / char-device at that path could wedge the reaper on a
  blocking `open(2)` (`File.size(fifo) == 0` sailed past `marker_file_oversized?`).
  `current_marker` now gates on a regular-file check first; a present-but-irregular
  path leaves a breadcrumb, a missing one stays silent.
- **`STATE_FILE_NAMES` drift removed.** The hand-maintained literal had drifted
  from the canonical workflow state files (`artifacts.md` plural never matched the
  coding `artifact.md`; `notes.md` matched no workflow). It is now derived lazily
  from `Hive::Task::STATE_FILES.values` (`LoadError`-guarded, like
  `inferred_task_log_dir`, to preserve the no-load-couple contract).
- **Symlink-escape helpers consolidated.** `realpath_or_expand` + `path_inside?`
  were byte-identical in the resolver and the producer; they now live once in
  `Hive::DiagnosticHelpers` (`evidence_root_realpath` + `path_inside?`), so the
  security-relevant guard can't drift between the two surfaces (plan R-5).
- **Symlinked task folder no longer regresses (trust anchor).** The pass-2
  symlink-leaf rejection also fired for `task.folder` itself (`Task` uses
  `File.expand_path`, which doesn't resolve symlinks), dropping it from the
  trusted roots so a `red-status.md` under an operator-symlinked folder was
  silently discarded. `evidence_root_realpath(..., trust_anchor: true)` now
  realpaths the folder unconditionally while the `logs/` subdir roots keep the
  symlink-leaf rejection (the `logs -> /outside` smuggling vector). Mirrored in
  `Diagnostic#diagnostic_roots`.
- **`kind` validated inside the boundary.** `summary_payload` now raises
  `ArgumentError` for an unmapped kind, so a future tier minting one degrades to
  nil *inside* `summarize`'s rescue instead of `KeyError`-ing later at the consumer
  render helpers (which sit outside it).
- **`evidence_diagnostic` redaction symmetry + `artifact_paths` guard.** The
  CLI's on-disk-evidence branch now routes `detail` / `source_path` /
  `artifact_paths` through `SecretPatterns.redact` (mtime still stats the raw
  path), and emits `[source_path].compact` so a future nil source_path can't ship
  schema-invalid `artifact_paths: [nil]`.
- **Polish:** breadcrumb prefix centralized in one private helper;
  `marker_state_file` dropped a redundant `!marker.none?` (current_marker already
  normalizes `:none → nil`); the `status.rb` local that shadowed the
  `marker_summary` method was renamed; the schema `summary`/`detail` descriptions
  now cite the real constant names (`Hive::TaskAction::Diagnostic::SUMMARY_MAX` /
  `DETAIL_MAX`); the aliasing comment no longer overclaims that all three caps are
  schema-pinned; the bot's no-evidence diagnose reply now points at `daemon.log`
  when the failure persists.

**Coverage:** Added regression tests for the nested-frontmatter `SystemStackError`
degrade (resolver and producer), the FIFO state-file never-block gate, the
`state_file_names` derivation + `LoadError` fallback, the unknown-`kind` boundary
raise, the symlinked-folder trust-anchor (resolver and producer), the
`evidence_diagnostic` ↔ `Diagnostic#to_h` key-set parity, and the 120-char
summary cap round-trip.
