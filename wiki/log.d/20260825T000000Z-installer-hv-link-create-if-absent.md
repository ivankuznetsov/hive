# Fix: bash installer never creates the `hv` collision-fallback link on unconflicted installs

- **Date:** 2026-08-25
- **Actor:** patrol fix agent (generation 1)
- **Task:** patrol-hv-symlink-is-never-created-on-faa403c56a
- **Area:** `install.sh` user-bin launcher publication; [[operating]]
- **Type:** bugfix

## What happened

Patrol flagged that on a host with no prior `hive`/`hv` in
`${XDG_BIN_HOME:-~/.local/bin}`, a full `install.sh` run never created the `hv`
symlink even though `${gem_home}/bin/hv` exists and is executable. The hv
link logic only handled two cases: a conflicting foreign `hive` on PATH (which
publishes `hv` as fallback) and refreshing an already Hive-owned `hv` symlink.
The unconflicted branch (fresh install where `hive` publishes cleanly and no
foreign `hive` is on PATH) had no create-if-absent arm, unlike the qmd managed
link logic in `install_qmd`.

## Fix

Replaced the refresh-only guard in the unconflicted `else` branch with an
unconditional `publish_managed_link "$hv_path" "${gem_home}/bin/hv" "hv"` call.
`publish_managed_link` already implements exactly the desired ownership
contract: create when absent, leave an identical owned symlink in place, and
back off with a warning when another program owns the name.

## Regression coverage

- `test_fresh_install_creates_the_hv_collision_fallback_link` — fresh install
  must create `${XDG_BIN_HOME}/hv -> ${gem_home}/bin/hv`.
- `test_reinstall_recreates_a_removed_hv_collision_fallback_link` — resolves
  `hive` on PATH to the managed launcher via a fake-bin shim so the reinstall
  deterministically takes the unconflicted branch, then asserts a removed `hv`
  link is recreated (fails on the pre-fix code regardless of host state).
- `test_fresh_install_preserves_an_unowned_hv_when_hive_link_publishes` — an
  unrelated operator-owned `hv` is still preserved unchanged.

## Notes

- Local validation requires invoking the suite without bundler's inherited
  `RUBYOPT=-rbundler/setup`; otherwise the installer subprocess's Ruby preflight
  fails because Bundler cannot resolve gems under the test tmp `HOME`.
- Updated [[operating]] to state that `hv` is exposed whenever the destination
  is absent, not only under collision/refresh conditions.
