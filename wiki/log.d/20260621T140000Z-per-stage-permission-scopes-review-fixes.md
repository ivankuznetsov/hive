## permissions - review-pass fixes for per-stage scopes

**Action:** Hardened the per-stage `permissions:` feature after code review.

- **`scoped` no longer denies the tools it grants.** `PermissionScope.scoped_scope`
  derived its deny list as the full `READ_ONLY_DISALLOWED` set regardless of the
  granted `tools:`/`bash:`, so a `scoped tools: [Read, Write, Edit]` (or
  `bash: true`) put the granted tool in BOTH `--allowedTools` and
  `--disallowedTools`; Claude's deny rules win, silently revoking the grant. Now
  `disallowed = READ_ONLY_DISALLOWED - allowed`, so the lists never overlap.
- **A8 runner-gate failures attribute an `:error` marker.** Every single-agent
  stage now resolves its scope through `Stages::Base.stage_permission_scope_or_mark!`,
  which stamps `:error reason=permission_config_error` on the stage's own task
  before re-raising — mirroring `Review.run!`'s ConfigError rescue. Previously a
  non-yolo scope on codex/pi escaped uncaught and left a stale `AGENT_WORKING`.
- **`review.permissions` is rejected at load.** A bare `review:` permissions key
  was validated then silently ignored (every review sub-stage fell back to the
  project default) — a fail-OPEN downgrade. `permission_entries` now scans only
  the resolved locations and `reject_unsupported_review_permissions!` fails closed.
- **`tool_csv` dedups** (first-occurrence order) so repeated `tools:` entries
  can't reach Claude's argv twice.
- Removed dead `BrainstormTmux.wrapper_command` and the dead re-validation in
  `resolve_dirs`; co-located `permission_spec` with `permission_at` /
  `MISSING_PERMISSION`; extracted the `YOLO` preset constant.

**Verification:** Unit tests now pin the scoped allow∩deny disjointness invariant,
the codex/pi attributed-marker path (helper + `Execute.spawn_implementation` e2e),
the reviewer `permissions:` resolution-into-spawn path, a per-stage/per-mode yolo
argv golden, and the `review.permissions` load rejection. The live smoke
`test/smoke/permission_scope_headless_smoke_test.rb` now also proves a `scoped`
agent with `Write` granted actually creates the file.

**Pages:** [[modules/config]], [[modules/agent]], [[stages/index]]
