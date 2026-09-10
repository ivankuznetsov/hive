# U1: command usage contract baseline

Fresh base: `794edfb489fc620f526a71bc7e5c62f6f2cca856`, verified as both HEAD
and fetched origin/main on 2026-09-08. The following expectations were transcribed
from that revision's `bin/hive` registry/resolver/payload methods and
`lib/hive/schemas.rb`, before extraction. They are an independent compatibility
inventory, not values obtained from the new resolver.

Required context read: `wiki/index.md`; searched usage/contract in
`wiki/cli.md` and `wiki/commands.md`. `.llm-wiki/config.json` has no main wiki path.

## Current-main versus historical defects

Current main has neither `lib/hive/cli_usage_contracts.rb` nor its unit test.
The historical cold-load seed 1/3 test defect is therefore not executable on
main; absence is not a pass. Current main has no boundary loader to inject.
Historical reference: `93d1132ec7d61579d2428952a838c02e01f35e7d`, reviewed against
`c11abdba6dad4dab1a0d4e3adbc37a87b32cb322`. Candidate cold-load reproductions
belong to U2 after adapting that extraction. Circuits is removed on current main;
do not restore its declaration, boundary, schema, tests or wiki page.

Current main does resolve twice: `thor_usage_error` and `emit_json_usage_error`
each call `json_usage_error_contract`. A worktree-local Ruby stdin probe evaluated
only the helper definitions from `git show 794edfb:bin/hive`, substituted a
stateful resolver returning nil once then the original `run` contract, and called
the two helpers in launcher order. Observed: resolutions **2**, classification
`Hive::UsageError`, emitted JSON `hive-run` v2 with `error_kind: invalid_task_path`
and `error_class: UsageError`, exit code **64**. This reproduces the semantic
mismatch on current-main helpers; it is not a claim that current main has the
historical loader failure. U3 must prove the real launcher's single call.

An ordinary absent contract classifies as `Hive::UsageError`, exits 64, and
prints human usage on stderr with empty stdout, even with JSON requested.
No new fallback schema is promised.

## Independent registry and variant inventory

Append `--json` to each trigger below. `extra` is an excess positional; missing
required positionals are deliberately omitted. All usage envelopes have `ok:false`,
`message`, `exit_code:64`; `error_class` is `InvalidTaskPath` for
`invalid_task_path`, otherwise `UsageError`, except metrics omits it.
Schemas below include their exact existing version. Extras are empty unless listed.
The table includes resolver-only surfaces as well as every static registry key.

| Key / variant | Pre-dispatch trigger | Schema / version | error_kind | Extras / custom behavior |
| --- | --- | --- | --- | --- |
| run | `run` | hive-run / 2 | invalid_task_path | |
| rebase-status | `rebase-status` | hive-rebase-status / 1 | invalid_task_path | Explicit fallback version 1; absent from SCHEMA_VERSIONS |
| approve | `approve` | hive-approve / 2 | invalid_task_path | |
| drop | `drop` | hive-drop / 2 | invalid_task_path | |
| findings | `findings` | hive-findings / 1 | invalid_task_path | |
| patrol | `patrol` | hive-patrol / 3 | error | |
| refactor-patrol discovery | `refactor-patrol` | hive-refactor-patrol / 4 | error | Reporter.error_envelope, explicit V4_SCHEMA_VERSION |
| refactor-patrol jobs list | `refactor-patrol --list` | hive-refactor-patrol-jobs / 2 | usage | action=list |
| refactor-patrol jobs show | `refactor-patrol --show=x` | hive-refactor-patrol-jobs / 2 | usage | action=show |
| refactor-patrol jobs archive | `refactor-patrol --archive=x` | hive-refactor-patrol-jobs / 2 | usage | action=show; archive takes precedence over list |
| refactor-patrol jobs modifiers | `refactor-patrol --full`, `refactor-patrol --limit=1`, `refactor-patrol --cursor=x` | hive-refactor-patrol-jobs / 2 | usage | action=null without list/show/archive |
| setup | `setup extra` | hive-setup / 1 | usage | Native context; mode, url, service, warnings |
| connect | `connect` | schema-less, unversioned | usage | service=screenote |
| disconnect | `disconnect` | schema-less, unversioned | usage | service=screenote |
| accept-finding | `accept-finding` | hive-findings / 1 | invalid_task_path | operation=accept |
| reject-finding | `reject-finding` | hive-findings / 1 | invalid_task_path | operation=reject |
| markers | `markers clear` | hive-markers-clear / 1 | invalid_task_path | |
| status default | `status extra` | hive-running-status / 2 | error | |
| status diagnose | `status --diagnose=task extra` | hive-status-diagnose / 2 | error | Highest option-region precedence |
| status operational | `status --operational extra` | hive-operational-status / 4 | error | Precedes internal graph/daemon task |
| status internal graph | `status --internal-task-graph extra` | hive-status / 8 | error | |
| status daemon task | `status --daemon-task=task extra` | hive-status / 8 | error | |
| runtime | `runtime unknown extra` | hive-runtime-maintenance / 1 | usage | action=unknown, runtime_code=usage, next_action=null, details={} |
| runtime default action | `runtime --json=yes` | hive-runtime-maintenance / 1 | usage | action=status when no positional |
| act empty | `act` | hive-act / 2 | usage | action_id="", target="" |
| act partial | `act workflow.advance` | hive-act / 2 | usage | action_id=workflow.advance, target="" |
| act identified | `act workflow.advance demo:task extra --observation=x` | hive-act / 2 | usage | action_id=workflow.advance, target=demo:task; skip observation value |
| prune | `prune extra` | hive-prune / 1 | usage | |
| forget | `forget project extra` | hive-forget / 1 | usage | |
| metrics | `metrics rollback-rate extra` | hive-metrics-rollback-rate / 1 | error | omit error_class |
| answer-digest | `answer-digest extra` | hive-answer-digest / 1 | usage | |
| answer | `answer` | hive-answer / 1 | usage | |
| workflow default/new/commit/unknown | `workflow a b c` | hive-workflow-new / 1 | usage | |
| workflow install | `workflow install x extra` | hive-workflow-install / 2 | usage | |
| workflow list | `workflow list x extra` | hive-workflow-list / 2 | usage | |
| workflow remove | `workflow remove x extra` | hive-workflow-remove / 1 | usage | |
| workflow update | `workflow update x extra` | hive-workflow-update / 2 | usage | |
| workflow publish | `workflow publish x extra` | hive-workflow-publish / 2 | usage | |
| workflow validate | `workflow validate editorial extra` | hive-workflow-validate / 1 | usage | valid=false, id=editorial, diagnostics=[{message: error.message}] |
| worktree | `worktree status demo extra` | hive-worktree / 1 | invalid_arguments | |
| module lifecycle/default | `module install x extra` | hive-module-lifecycle / 1 | usage | Includes all unlisted subcommands |
| module list | `module list x extra` | hive-module-list / 1 | usage | |
| module inspect | `module inspect x extra` | hive-module-status / 1 | usage | |
| module status | `module status x extra` | hive-module-status / 1 | usage | |
| module doctor | `module doctor x extra` | hive-module-doctor / 1 | usage | |
| module dry-run | `module dry-run x extra` | hive-module-dry-run / 1 | usage | |
| pr alias | `pr` | hive-stage-action / 2 | invalid_task_path | verb=open-pr |
| brainstorm | `brainstorm` | hive-stage-action / 2 | invalid_task_path | verb=brainstorm |
| plan | `plan` | hive-stage-action / 2 | invalid_task_path | verb=plan |
| develop | `develop` | hive-stage-action / 2 | invalid_task_path | verb=develop |
| open-pr | `open-pr` | hive-stage-action / 2 | invalid_task_path | verb=open-pr |
| review | `review` | hive-stage-action / 2 | invalid_task_path | verb=review |
| artifacts | `artifacts` | hive-stage-action / 2 | invalid_task_path | verb=artifacts |
| finalize | `finalize` | hive-stage-action / 2 | invalid_task_path | verb=finalize |
| archive | `archive` | hive-stage-action / 2 | invalid_task_path | verb=archive |
| web status | `web status extra` | hive-web-status / 1 | invalid_task_path | Web.status_error_context(environment: ENV) |
| web install | `web install extra` | hive-web-install / 1 | invalid_task_path | Web.error_context(environment: ENV) |
| web other | `web unknown extra` | none | generic usage | No JSON; bind/port values do not select subcommand |
| bot | `bot status extra` | hive-bot-status / 1 | extra_arguments | All bot subcommands use status usage schema |
| pairing approve | `pairing approve extra` | hive-pairing-approve / 1 | invalid_arguments | |
| pairing other/list | `pairing list extra` | hive-pairing-list / 1 | invalid_arguments | Includes unknown/missing subcommands |
| decide | `decide task approve` | hive-decide / 1 | invalid_task_path | |

Status detection examines only arguments before `--`, recognizes bare and assigned
flags (presence, including assigned false), and ignores invalid encoding.
Refactor jobs uses last boolean list/full setting, recognizing no/skip negation
and false/f/no/n/0 assignment values. Show/archive presence selects jobs regardless
of assignment value. Option modifiers alone select jobs with null action.
Module subcommand selection skips values for receipt, setting, hook, grant,
mapping, input-binding, event, schedule, occurred-at. Native setup mode is
`diagnose_only` for no/skip-bootstrap or bootstrap=false, `service_opt_out` for
no/skip-service or service=false, otherwise `managed_service`; bootstrap wins.
The service object is the existing selected Web context fields. Reporter and
native-context payload builders remain command-owned in the extraction.

## Baseline execution

Initial `bundle exec ruby -Itest test/integration/cli_usage_error_json_test.rb
--seed 1` gave 24 runs, 23 failures and 1 error because isolated HOME hid the
user-installed gems in child processes (`Bundler::GemNotFound`), before launcher
execution. This is an environment failure, not a command regression. The launcher
path in the existing test is correct. Export the absolute installed gem search
path for subprocess runs: `GEM_PATH="$(bundle exec ruby -e 'puts Gem.path.join(":")')"`.

With that environment, `bin/test test/integration/cli_usage_error_json_test.rb
--seed 1` passed: **24 runs, 548 assertions, 0 failures, 0 errors, 0 skips**
in 28.309490 seconds. Existing integration coverage therefore confirms baseline
envelopes and fallback before production changes. `git diff --check` passed.
The trigger inventory is source-derived; U4 must execute the extended cases,
not treat source transcription as a substitute for subprocess validation.

## U2 candidate and isolation evidence

Narrow historical adaptation on U1 commit e8ff235b13: command declaration patches,
resolver, and launcher helpers only; no circuits or historical schema changes.
Before correction, `bin/test test/unit/cli_usage_contracts_test.rb --seed 1`
passed (23 runs, 109 assertions); seed 3 failed (23 runs, 107 assertions) because
bot was cached. A real-launcher RUBYOPT probe with a first-attempt LoadError
observed 2 resolver entries and 2 loader attempts, exit 64, and a hive-run v2
invalid_task_path document classified UsageError. These reproduce both historical
candidate defects. The probe was removed after use.

Cold-load tests now assert fresh declaration and loaded-feature state in children,
and preserve inherited RUBYOPT coverage instrumentation. No production cache reset
or argv-result caching change was necessary. Classification accepts a selected
contract; U3 will remove the remaining separate launcher resolutions.

U2 verification (absolute GEM_HOME/GEM_PATH pinned as above): focused contract
seeds 1, 3, 17 each passed 24 runs / 121 assertions. Existing launcher integration
plus refactor-patrol tests passed 32 runs / 689 assertions (seed 7133).
`bin/test --changed --list` selected the broad fallback for bin/hive; explicit
focused files were used for this incremental checkpoint. `git diff --check` passed.

## U3 single-resolution evidence

Before the launcher change, new real-process regressions failed: the success case
counted 2 resolutions; the first-attempt loader failure produced JSON despite the
expected empty stdout (2 tests, 9 assertions, 2 failures). The committed extraction
at 93d08f1154 was the base for these red tests.

The rescue now resolves once with an invocation-local class-only diagnostic
callback. The same selected value (including nil) reaches classification and
emission. Instrumentation wraps the resolver entry, loader, classifier, and emitter;
cache hits cannot hide a second lookup. Loader and resolver failures are exercised
in JSON and human modes, with secret-sentinel exception messages absent from output.

U3 verification: contract and launcher integration files passed together:
52 runs / 763 assertions, seed 63479. Changed-file RuboCop and diff checks passed.

## U4 initial blocked attempt (historical)

The initial execution stopped without the execute-complete trailer. U1-U3 were
committed; U4 regression tests and this evidence awaited plan repair. The later
schema compatibility fix in `25d5fc0f81` accepts the existing workflow usage
envelopes without changing their fields, versions, or exit statuses.

The expanded independent inventory test fails against preserved current-main
workflow-install output: 30 runs, 1221 assertions, 1 failure, seed 17. A separate
read-only probe evaluated the helper definitions from `git show 794edfb489:bin/hive`
and validated their output against the unchanged schemas. It confirms:

- workflow install v2, list v2, remove v1, update v2 emit `error_kind: usage`,
  which each existing error enum excludes.
- workflow publish v2 emits the same generic usage arm, while its schema requires
  `retryable` and specialized error kinds/exit statuses.

Thus preserving all baseline envelopes and requiring all of them to validate is
not simultaneously possible as specified. No schema, version, or output semantics
were changed to hide this. The regression remains failing rather than suppressing
validation. Plan repair must decide the public compatibility treatment for these
existing workflow usage errors before execution can complete.

The first `bundle exec rake coverage:changed` ran 1235 tests / 6441 assertions
successfully (seed 60924), but the exact full-file gate failed: 93.97% across 29
sources, 364 uncovered lines. It includes pre-existing implementation branches
in approve, run, status, web, stage_action, bot and others, beyond the newly moved
usage-contract code. The added U4 unit cases address the extraction's generic,
variant, callback, and custom-builder lines; no coverage machinery was changed.

`bin/test --all` was started once with its normal two workers, then interrupted
through the runner's signal cleanup after the plan conflict was confirmed. It is
not a passing broad checkpoint. No review, CI, release, or publication was run.

A second changed-coverage run (seed 59136) reached 1243 runs / 6441 assertions,
then failed with 10 DecideTest errors: `workflow :editorial collides with registered
workflow :editorial`. This run did not produce a successful coverage report;
the registration-order failure was not investigated after the schema plan blocker.
The latest standalone contract file passed 31 runs / 160 assertions, seed 3,
before the final added variant cases. Those final cases were included in the
second coverage test run; no complete checkpoint is claimed for U4.

Local raw logs are retained under `tmp/cli-usage-execution/`. All generated probe
files were removed. U4 was incomplete at that checkpoint; the review fix-pass
results below supersede that status.

## U4 review fix pass 01

The changed-source selector previously stopped at a mirrored test file and
omitted other tests that explicitly require the same source. It now combines
both sets, retains deduplication and the existing CI-only exclusions, and keeps
the exact full-file coverage gate unchanged. The first expanded run passed
2,173 tests / 14,037 assertions and covered 6,034 of 6,039 executable lines
(99.92%). The remaining five lines identified the Answer programmatic entry
points and Module JSON error handling; new tests exercise their observable
results, target-slot isolation, silent programmatic output, and matching JSON
error/exit semantics.

A separate regression reproduced the registration leak from
`NewIdempotencyTest`'s authored-workflow fixtures. Its temporary-project helper
now resets the project registry on entry and in `ensure`, covering every fixture
using that helper. The combined New/Decide run passed at the previously failing
seed 59136: 53 tests / 323 assertions. Mapping/enforcement tests passed (11 tests /
25 assertions), as did the Answer/Module files (39 tests / 272 assertions).

The host installs gems beneath the user's home. Tests that replace `HOME` can
hide those gems from Ruby subprocesses inheriting Bundler/coverage startup.
Validation pins the existing gem search path before those fixtures run:

```sh
export GEM_PATH="$(ruby -e 'puts Gem.path.join(File::PATH_SEPARATOR)')"
bundle exec rake coverage:changed
HIVE_TEST_WORKERS=4 bin/test --all
```

The comparison base is `794edfb489fc620f526a71bc7e5c62f6f2cca856` (the branch's
merge base with `origin/main`). Final checkpoint results are recorded below.

- `bundle exec rake coverage:changed`: PASS, 2,177 tests / 14,076 assertions,
  zero failures/errors/skips, seed 38818, 544.10 seconds. All 29 changed library
  sources have exact 100% line coverage. Report:
  `coverage/changed-3611435-539f5762.json`; raw log:
  `tmp/cli-usage-coverage-review-final.log`.
- Changed Ruby-file RuboCop: PASS, 8 files, zero offenses.

The two-worker broad run exposed a component test inheriting the host's configured
Grok executable while asserting default prompt-transport argv. The shared
`AgentCliRuntimeRuntimeTest#compile` fixture now supplies an explicit executable
for every provider. That component file passed with the host override still present (16 tests / 115
assertions), and its RuboCop check passed. The final broad rerun uses the
repository-supported four-worker setting; the changed-library sources are
unchanged from the passing coverage run above.

- `HIVE_TEST_WORKERS=4 bin/test --all`: PASS, 838 files across four root
  partitions plus the component suite; 14,172 tests / 287,669 assertions,
  zero failures/errors, 14 skips, 788.66 seconds. Worker seeds: 42266, 34167,
  43525, 41548, 45138.
  Raw log: `tmp/cli-usage-broad-review-complete.log`; worker summaries and
  receipts: `tmp/test-parallel-20260908-4177286-fkr9f/`.

U4 is complete: changed-library coverage and the broad checkpoint both passed
on the final code and tests. `git diff --check` also passed. The historical
schema conflict and incomplete attempts above are retained as provenance, not
as the current completion status.
