## [2026-07-14T21:49:46Z] babysitter - block verbose status textconv execution

**Action:** Fixed Hive patrol finding `command-bin-hive-e2e-2` by rejecting
every Git-accepted positive verbose form for allowlisted `git status` reads:
`-v`, repeated or clustered short flags, and unambiguous long prefixes from
`--v` through `--verbose`. Verbose status renders a diff, so passing these forms
through could execute a repository-configured `diff.<driver>.textconv` helper.

**Coverage:** Added a real-Git regression that installs a marker-writing
textconv driver and confirms every verbose status spelling is skipped without
creating the marker. Plain non-verbose status remains allowlisted.
