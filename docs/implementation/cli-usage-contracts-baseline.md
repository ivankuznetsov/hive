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
