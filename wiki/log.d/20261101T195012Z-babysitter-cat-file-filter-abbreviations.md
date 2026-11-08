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
- For external-diff options, only exact `--ext-diff` is denied. Its rejected
  prefixes reach Git on allowlisted `log`/`show` reads.
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
  root worker ran 7,738 tests and reported failures in
  `ReleaseCandidateCliTest#test_no_verb_defaults_to_read_only_plan_with_committed_input_blocks`
  and `WikiCommandIndexIntegrationTest#test_public_help_metadata_and_navigation_are_one_read_only_contract`.
  The two complete affected files passed when run together without the parallel
  harness (9 tests, 134 assertions):

  ```sh
  bundle exec ruby -Itest -Ilib -e 'ARGV.each { |path| require File.expand_path(path) }' test/integration/release_candidate_cli_test.rb test/integration/wiki_command_index_test.rb
  ```

  The wiki command-index failure was reproduced on base
  `236b127953504c9aa521d6b0f5258a181f6504f0` and on this change with:

  ```sh
  bundle exec ruby script/test_parallel.rb test/integration/wiki_command_index_test.rb test/unit/babysitter/dry_run_env_test.rb
  ```

  Its repository snapshot diff contained only the parallel runner's
  `tmp/test-parallel-*/worker-2.log`.
- Both launchers establish a recorded ordinary `cat-file` read before checking
  no handoff for denied tokens, with independent skip logs per launcher.
  Every allowed fixture case requires no skip record; glued object-filter
  output checks use the fixture's recorded exit status. Independent
  leading-global classification and literal hardened argv checks cover `log`,
  `show`, and glued `cat-file` object filtering. Acceptance audit assertions
  explain failures, and the policy comment names the parsing dependencies of
  excluded forms.
- Focused verification via `bin/test` passed for the policy, dry-run environment,
  and acceptance files (88 tests, 1,973 assertions, no failures/errors; one
  CI-only matrix skip). The three compatibility/helper tests passed on Git
  2.45.4 (568 assertions) and 2.55.0 (572 assertions), without skips. RuboCop
  passed all four changed Ruby files, and `git diff --check` passed.
