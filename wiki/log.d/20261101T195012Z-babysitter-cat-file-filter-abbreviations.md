# 2026-11-01 — Pin the babysitter cat-file filter boundary

- The shared babysitter Git policy denies the six exact bare `cat-file` tokens
  `--filters`, `--fi`, `--fil`, `--filt`, `--filte`, and `--filter`, including
  either `--path` ordering, independently of Git version. The original
  unscoped exact `--filters` guard remains. Glued `--filter=<spec>`, shorter
  `--f`, and other commands' object-filter options stay outside the new matcher.
- This fixed fail-closed boundary deliberately over-blocks ambiguous errors,
  invalid filter specs, and legitimate separate-word object-filter reads.
  Interception preserves synthetic success, empty stdout, skip diagnostics,
  audit behavior, and no real-Git handoff. Public/serialized contracts and
  hardened passthrough argv are unchanged.
- Only exact `--ext-diff` is denied in that family. Its rejected prefixes reach
  Git on allowlisted `log`/`show` reads; no rejected-prefix guard was added.
  The command Wiki's read-only allowlist no longer includes working-tree `diff`.
- `test/fixtures/babysitter/git_option_spellings.v1.json` records 36 exact forms
  separately for locally reproduced Git 2.45.4, 2.55.0, and 2.56.0, with exit
  status, first diagnostic, stdout presence, and helper marker. Official source
  archive hashes and the latest successful CI run's 2.56.0 version identity are
  recorded as provenance. On 2.45.4 all six bare tokens execute smudge; on
  2.55.0/2.56.0 four are ambiguous and bare `--filter` selects object filtering.
  Only exact `--filters` is used as the raw smudge positive control.
- Pure tests establish repeatable, non-mutating classification. Ordinary stub
  tests prove helper interception, recording-binary absence, generated-overlay
  behavior, and one audit record per repeated invocation. The existing named
  matrix consumes the fixture; the full babysitter acceptance path accounts
  for all seven commands, skipping `cat-file --fi` and delegating `log --ext`.
- Verification passed: focused policy (17 tests), ordinary dry-run environment
  (70 tests, with only the matrix-only test skipped), babysitter acceptance
  (1 test), the named security matrix (1 test, 1,928 assertions), and the three
  new compatibility/helper tests on both reference binaries. RuboCop passed
  for all four changed Ruby files. `bundle exec rake coverage:changed` reports
  exact 100% line coverage for the changed Git policy from ordinary tests.
- Broad checkpoint: `bin/test --all` ran 931 files. The 458-file root worker
  passed (8,042 tests), as did all 14 component files (139 tests). The other
  root worker ran 7,738 tests and reported two repository-state failures.
  `ReleaseCandidateCliTest#test_no_verb_defaults_to_read_only_plan_with_committed_input_blocks`
  had captured U1's HEAD before the U2 commit occurred during the run; its
  candidate-SHA assertion therefore saw a different revision. Both complete
  affected files passed in a stable isolated checkout of current code and of
  unmodified base `236b127953504c9aa521d6b0f5258a181f6504f0` (9 tests and 134
  assertions each), using:

  ```sh
  bundle exec ruby -Itest -Ilib -e 'ARGV.each { |path| require File.expand_path(path) }' test/integration/release_candidate_cli_test.rb test/integration/wiki_command_index_test.rb
  ```

  The remaining parallel-run baseline is
  `WikiCommandIndexIntegrationTest#test_public_help_metadata_and_navigation_are_one_read_only_contract`
  at `test/integration/wiki_command_index_test.rb:52`, with the matching error
  `public help or the command-index guard modified the repository`. The same
  command reproduces it on base and current code in isolated checkouts:

  ```sh
  bundle exec ruby script/test_parallel.rb test/integration/wiki_command_index_test.rb test/unit/babysitter/dry_run_env_test.rb
  ```

  Both snapshot diffs identify only the runner's concurrently written
  `tmp/test-parallel-*/worker-2.log`. This unchanged parallel-harness failure
  is outside the filter-policy fix; the standalone read-only checks pass.
- Review proof corrections: both launchers now establish a recorded ordinary
  `cat-file` read before checking no handoff for denied tokens, with independent
  skip logs per launcher. Every allowed fixture case requires no skip record;
  glued object-filter output checks use the fixture's recorded exit status.
  Independent leading-global classification and literal hardened argv checks
  cover `log`, `show`, and glued `cat-file` object filtering. Acceptance audit
  assertions now explain failures, and the policy comment names the dependence
  of excluded `--f` / `--filters=<value>` forms on Git's current parsing.
- Review verification: `bin/test` with the policy, dry-run environment, and
  acceptance files passed (88 tests, 1,973 assertions, no failures/errors; the
  CI-only security matrix remains skipped in this ordinary run). The three
  compatibility/helper tests passed again on Git 2.45.4 (568 assertions) and
  2.55.0 (572 assertions), without skips. RuboCop passed all four Ruby files.
  Removed the disposable Git build directories and source archives after
  verification; retained characterization/test logs and the dirty isolated
  verification checkout for the documented broad-suite evidence.
- Review scope correction (pass 2): the unrelated web flash repair, its
  browser-test extension, and its owning Wiki updates are preserved separately
  on local branch `fix/web-flash-acknowledgements` (commit `6446862a74`).
  This branch retains only the planned babysitter policy, fixture, tests,
  owning Wiki updates, and this one source fragment. Both lockfiles retain
  the patched versions already present on `origin/main`.
- Scope correction verification: the focused policy, dry-run environment,
  and acceptance files passed via `bin/test` (88 tests, 1,973 assertions,
  no failures/errors; one CI-only matrix skip). An explicit final-diff
  allowlist check confirmed all ten planned paths and one log fragment,
  both lockfiles match main, and `git diff --check` passed.
