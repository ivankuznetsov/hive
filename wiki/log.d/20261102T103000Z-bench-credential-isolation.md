# Isolate direct benchmark credentials and verify runtime delivery (U4)

Scope: direct `ruby harness/run_all.rb` and `harness/pipeline_run.rb` v1-slate
runs through `IsolationExec`. The packaged `generate.md` → `hive_run.rb` →
`HiveDriver` v2 candidate path, including `env_args`/`auth_mounts` forwarding
and `hive_stages.sh` in-container `auth.json`, remains byte-for-byte unchanged.
Slate models, selection, preflight behavior and exit handling are unchanged.

Canonical baseline: `432e730ea7812246496726fcc9153e98be58eb30`.
Hive execution baseline: `966211001e76d53da50879a582668b5b2e381607`.
Canonical local commits on `fix/profile-credential-isolation`:
`dce0f155` (U1), `a09fd659` (U2), `7383c88b` (U3), `f157ef7` (U4).
Review follow-up `8d562e148902dfbfc9b32c4b333ce3d8593f31e3` applies Hive's
one-CPU real-Docker proof override to canonical; the U3/U4 evidence below now
includes the constrained-runner recheck.
The independent canonical checkout is `tmp/bench-credential-canonical` inside
this worktree because execution permits writes only here. The original dirty
canonical checkout is untouched. These are local commits, not upstream PRs.
Hive implementation commits are `7169b37d19` (U1), `f1b1aabac7` (U2) and
`c851701c9f` (U3), followed by this delivery commit.

| Acceptance | Evidence |
| --- | --- |
| R1/R2 profile selection | Default `isolation_exec_test.rb` and `isolation_shell_test.rb` load the packaged path. Decoy matrices prove exact API names, exclusive read-only OAuth mounts, nil removals of inherited paths and parent ENV/profile preservation. All Slate Pi profiles are enumerated, including both refusing bare routes. |
| R3 gates | Fake and real Docker tests prove no provider variables/auth mounts with every host control populated; network none and resource/security args remain. |
| R4 refusals | Fixed wrapper diagnostics plus exit 70 and zero Docker calls for invalid/missing declarations or auth. Ruby policy validation has a fixed error and zero process-marker writes. Post-invocation Docker exits 70/125/126/127 remain IsolationError with phase/status and no decoy key/path in messages. Prompt cleanup is asserted. |
| Regression baseline | Before implementation, canonical decoy tests observed all ambient keys forwarded, undeclared/incomplete gen accepted, missing policy declarations and secret-bearing raw diagnostics. |
| R5 actual Bash | Bash 3.2.57(2)-release built from GNU bash-3.2.57 sources locally; current GNU Bash 5.3.20(1)-release. Each executed the complete 15-test Ruby/shell matrix against each copy (Hive 602 assertions, canonical 590, per interpreter). Both wrapper syntax checks passed under both interpreters. |
| Named gate/CI | `HB_TEST_BASH_32=... bundle exec rake test:bench_isolation_proof`: Hive 3 tests/55 assertions, canonical 3/40; zero failures/errors/skips. Both CI YAML files have ubuntu-24.04 and macos-15 lanes. Hosted macOS is unrun locally; its lane requires actual /bin/bash 3.2. |
| Hosted CPU correction | At canonical `8d562e148902dfbfc9b32c4b333ce3d8593f31e3`, both real-Docker proofs request one CPU. A shim rejecting requests above four CPUs reproduced canonical's former exit 125, then both full gates passed with actual Bash 3.2.57/5.3.20 and real Docker: canonical 3 tests/40 assertions, Hive 3/55, zero failures/errors/skips. Each interpreter's nested matrix passed (canonical 15/590, Hive 15/602). Hosted confirmation remains pending. |
| Default/coverage exclusion | Proof omitted from HIVE_DEFAULT_TEST_FILES, every coverage shard and bin/test --changed shared/direct selections. Selector/CI/runner checks: 48 tests/406 assertions pass. |
| R6 source synchronization | `cmp` passes for the entire isolation.sh and isolation_exec.rb files, stronger than region-only comparison. Baseline files were also identical. The 37 pre-existing divergent harness files outside this boundary are retained; see gaps. |
| Focused suites | Canonical executor/policy/shell: 43 tests/682 assertions pass. Hive integrated isolation/pipeline/install/workflow/selector/CI/runner run: 122 tests/1574 assertions pass; final strengthened shell assertions separately pass 10 tests/532 assertions. Expanded install regression passes 4 tests/59 assertions. |
| Broad checkpoints | Canonical `bundle exec rake test`: 266 tests/1378 assertions, zero failures/errors/skips. Hive `bin/test --all`: batches of 8045, 7746 and 139 tests; 3 failures, 0 errors. Two stale CI gate expectations were updated in U3; one WikiCommandIndexIntegrationTest read-only snapshot collision was confined to concurrent repository tmp/ fixtures under the explicitly overridden TMPDIR. All failing files rechecked serially with standard temp placement: 21 tests/358 assertions, zero failures/errors/skips. Whole broad suite was not repeated. |
| Lint | Owning canonical RuboCop passes changed Ruby and Rakefile; Hive RuboCop passes changed tests/helpers/Rakefile. ShellCheck 0.11.0 passes all 8 packaged shell scripts and the canonical isolation wrapper. git diff --check passes in both repositories. |
| R7 real container | Docker 29.9.2 available. Six real decoy probe variants pass using docker.io/library/alpine:3.22.2@sha256:4b7ce07002c69e8f3d704a9c5d6fd3053be500b7f1c69fc0d80990c2ad8dd412. Probe receives separate sh/-c/script argv. Exact credentials, selected read-only auth and absent other auth proven; no paid calls. No Docker-unavailable or image-setup-failure exemption used. |
| Entrypoint scope documented | Owning/packaged CREDENTIAL_ISOLATION.md, profiles README, workflow/testing wiki and changelog name both v1 entrypoints and unaffected v2 path/forwarding/auth.json. git diff against both baselines is empty for v2 files, Slate, Profile and preflight. |
| Fresh install | Install regression compares both installed files byte-for-byte with the corrected packaged sources and checks their credential-policy markers. |
| Existing refresh/recovery | Exact existing CLI install route exercised on a legacy-runtime fixture, followed by an isolated hive/state commit revert. Full legacy runtime tree matches the pre-change packaged tree, and reverting restores that exact tree. Old/new hashes and state OIDs below; unrelated tracked note, config bytes and pre-existing untracked status are preserved. No automatic upgrade was added. |
| Slate/preflight consequences | README/changelog explicitly document minimax-3 and qwen-2.6-coder refusals, every default unfiltered pass parking both in failed and exiting 2, PI_MODELS/README future migration surfaces and binary/auth/version-only preflight. No model ids invented. |
| Attachments, separate | `bin/test test/integration/new_test.rb`: 53 tests/225 assertions pass. No attachment failure reproduced, no baseline failure asserted and no attachment code changed. |

Runtime-byte comparison, SHA256 (canonical and packaged values match):

| File | Old | Corrected | Reverted |
| --- | --- | --- | --- |
| isolation.sh | e99d9adea718660dfcba6aa69f79801840083eddb0531b03ced5d2753541e14c | f4c1f0d9b49ad1baa2cdfe9b921c20f51e3544335ac830138edbdaef7e260587 | e99d9adea718660dfcba6aa69f79801840083eddb0531b03ced5d2753541e14c |
| isolation_exec.rb | b5a206fef085381f696ce20a31d0c531e9524dde650911770a71df07d00852fb | 1bbd66693e5ff0f0450807944cbc8ca3dc13a9c8a958d84dfe89734eaa4eede4 | b5a206fef085381f696ce20a31d0c531e9524dde650911770a71df07d00852fb |

Refresh/recovery specimen from the expanded fixture regression:

- Old hive/state revision: `50dccd12e0c1249cb004ae4cc99ca3c6cd3b3dad`.
- Refresh commit: `f3d87594241e08e5dc01b56583cb88d53b1b6d17`.
- Revert commit: `a223bb7d01e4ccbf7272afec888624677953a9ba`.
- Old/restored runtime tree: `8ccc1ecaf8b3984eb52309de866aa72c13e1dd77`,
  exactly Hive baseline `templates/builtins/bench/runtime`'s tree.
- Refresh changed only `bench-runtime/harness/lib/isolation.sh`,
  `bench-runtime/harness/lib/isolation_exec.rb`, `bench-runtime/harness/profiles/README.md`
  and the new `bench-runtime/harness/CREDENTIAL_ISOLATION.md`.
- Fixture commands use `bin/hive init PROJECT --workflow bench`,
  `git -C .hive-state show`/`diff-tree`, and
  `git -C .hive-state revert --no-edit REFRESH`; exact operator commands,
  clean/conflict checks, hash verification and revert-abort recovery are in
  the owning guide. The generated per-run receipt is
  `tmp/bench-credential-refresh-evidence.json`; fixture repositories are removed
  after the test. The hashes and OIDs here preserve the observed result.

Rollback deliberately restores the old credential posture; the new wrapper
never falls back to forwarding all credentials.

Broad-check follow-up details (no unrelated product fixes):

- `CiTestPartitionTest#test_ci_runs_each_expensive_test_as_a_named_merge_gate`
  and `#test_default_suite_excludes_the_expensive_ci_gates` had the old five-gate
  expectation in the already-running process. The U3 commit updates that
  contract and verifies the new dedicated OS matrix/failure artifacts.
- `WikiCommandIndexIntegrationTest#test_public_help_metadata_and_navigation_are_one_read_only_contract`
  snapshots ignored files too. Its 57 changed entries were all under `tmp/`,
  including concurrent fixture creation, because the broad run deliberately set
  TMPDIR inside the repository. `env -u TMPDIR bin/test
  test/integration/wiki_command_index_test.rb test/unit/ci_test_partition_test.rb`
  passes all 21 tests/358 assertions in a quiet serial run. No wiki-command
  implementation or test was changed. This is separate from attachment tests.
