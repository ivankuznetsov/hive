## [2026-08-10T22:13:42Z] testing — verify and bound Hive test tmp cleanup

**Action:** Replaced the test helpers' permissive `FileUtils.rm_rf` cleanup
with a shared, scope-checked remover that handles read-only managed-package
trees and verifies absence. Added per-test tracking for source/store fixtures,
then migrated the Web app bundle and pairing allocations that previously
outlived their tests. The suite-owned `HIVE_WORKTREE_BASE` is now recorded
separately so an explicit caller override can never be removed at shutdown.
The cleanup family also removes only the root's exact `-worktrees`,
`.origin.git`, and Patrol-lock siblings; a broad-suite proof exposed 56 such
siblings from refactor-Patrol tests, and focused fixer/token-budget reruns now
leave none.

Review then found additional real sibling shapes used by worktree tests. The
allowlist now includes exact `.worktrees`, `.managed-worktrees`,
`.strict-origin.git`, and `.agent-worktree-origin.git` forms, with regression
coverage for every accepted suffix. Suite roots share one aggregate shutdown
hook so one removal failure cannot skip the other root. Helper cleanup keeps an
already-active assertion as the primary failure, and private-TMPDIR, symlink,
direct-child, production-name refusal, and invalid-prefix boundaries are
covered explicitly.

**Recovery broom:** Hardened `rake test:clean_tmp` around exact test-shaped
names, current-uid ownership, a 24-hour age floor, and creator-PID liveness.
The task still recognizes the legacy `~/Dev/hive-test*.worktrees` shape, but
does not sweep generic production `hive-*` temp families. It reports live,
recent, and unowned skips separately, verifies every deletion, and fails on
retained candidates. `HIVE_TEST_TMP_MIN_AGE_SECONDS=0` provides an explicit
inactive-only immediate sweep.

**Coverage:** Added cleanup regressions for 0555/0444 trees, unsafe-name
refusal, silent deletion failure, stale/recent/live classification, and the
legacy worktree shape. Focused Web app bundle, Web command, pairing, managed
store, cleanup-helper, refactor-Patrol fixer, and Patrol token-budget tests
pass. An immediate inactive-only broom removed 3,894 recognized leftovers with
no deletion failures; the final recognized-family count was zero. The broad
checkpoint's standalone runtime package passed (43 runs, 411 assertions). Its
main suite completed 12,353 runs and 157,951 assertions with two failures and
four errors, all from project-capture fixture subprocesses losing Ruby 3.4's
non-default `base64` gem after isolated `HOME`; the untouched checkout
reproduced the same project-capture failures, so they are not caused by this
cleanup change.
