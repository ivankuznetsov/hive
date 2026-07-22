## [2026-07-21T17:23:39Z] native web — align CI with readiness and shell proof

- Kept the strict nonzero `hive web install` result when a managed service
  cannot answer `/health`, while teaching the real macOS launchd job to accept
  only a structurally valid `inactive` or `active_not_ready` install envelope
  for its intentionally unbootstrapped service.
- The launchd proof still requires the macOS target path, written outcome,
  manager availability, installed/enabled state, plist bytes, and live
  `launchctl` registration; ready installs must still exit zero.
- Made the authenticated managed-web verifier clean under ShellCheck 0.11 by
  preserving the generated launchctl stub's runtime interpolation explicitly
  and representing scrubbed provider keys as explicit empty strings.
- Added a source-level regression contract for the launchd workflow. The exact
  ShellCheck verifier, focused packaging tests, workflow shell syntax, and the
  native-web positioning contract pass locally.
