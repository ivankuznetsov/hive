## permissions - per-stage Claude tool scopes

**Action:** Added opt-in project and per-stage `permissions:` specs for Claude
spawns. `yolo` remains the default and preserves historical per-mode behavior;
`read-only` and `scoped` resolve through `Hive::PermissionScope` and feed
Claude `--allowedTools`, `--disallowedTools`, `--permission-mode default`, and
extra task-relative add-dirs.

**Implementation notes:** `Config.permission_spec` returns a full-replacement
stage spec or the project default. `Stages::Base.stage_permission_scope` is the
shared wiring point for bespoke coding stages, generic descriptor-backed agent
stages, and review helper/reviewer spawns. Non-yolo scopes fail closed on
non-Claude runners.

**Verification:** Unit tests cover resolver/config validation, headless/tmux
argv plumbing, stage-scope default preservation, and review spawn paths. The
live smoke `test/smoke/permission_scope_headless_smoke_test.rb` proves a
read-only headless write attempt completes without writing, while yolo writes.

**Pages:** [[modules/config]], [[modules/agent]], [[stages/index]]
