---
title: Testing
type: reference
source: test/, Rakefile, bin/hive-eval, .rubocop.yml, .github/workflows/{ci,live-agent-skills,release-candidate,release}.yml, packaging/{live_agent_skills,release_candidate}/, config/brakeman.ignore
created: 2026-04-25
updated: 2026-08-04
tags: [test, minitest, fixtures, honeycomb, agent-skills, component-boundaries, terminal-outcomes, release-proof]
---

**TLDR**: Minitest covers unit/integration behavior; opt-in layers cover outer
e2e, eval, native package/bootstrap, authenticated agent skills, install
verification, release proof, and Hivebox images. Offline tests pin the
agent-first status/watch/action contracts, coherent daemon snapshots, canonical
four-platform skill projections, safe consent-gated provisioning, native web
service/readiness contracts, and the exact-artifact proof verifier. The trusted
pre-tag candidate workflow owns release readiness without provider
credentials; the live-agent workflow is an optional diagnostic that directly
exercises native OpenClaw, Claude, Codex, and Pi discovery/use when credentials
are available and can never replace a deterministic blocking row.

The natural-language workflow creator has a hermetic primary acceptance gate
in `test/integration/workflow_creator_e2e_test.rb`. It exercises AE1–AE5 through
the real CLI collaborators: exact editorial approve/reject semantics,
byte-identical collision refusal, no-write minimal-init preview followed by
confirmed execution, explicit old-version and unconfirmed-preview refusals,
durable populated-graph commit evidence, no-task default behavior, and
state-wide idempotent task retry after movement. Focused parser, decision, validation, init, task-meta,
skill projection, schema, package, and release-contract tests own the smaller
contracts, including visit-bound decision IDs, marker-only/concurrently changed
artifact rejection, no-follow human-state entry, read-only managed validation,
minimal-init registration collisions, symlink refusal, timer disablement, and
JSON failures, serialized idempotent creation with index rollback and authored
content fingerprints, concurrent/self-target decision behavior, and the
distinct completed-human action.

`test/smoke/live_hive_workflow_creator_smoke_test.rb` is a separate,
OpenClaw-only protected proof. The exact candidate projection receives the
editorial prompt in a disposable initialized project. Its controlled Hive
surface permits only version, workflow inventory, scaffold, validation, and
the populated-graph commit before task creation.
Attestation verifies the prompt digest, native `/hive` discovery, ordered argv,
created-file digests, exact normalized graph, zero tasks after creation-only,
then one created-and-run slug plus a no-op retry with the same idempotency key,
operational status, no external actions, secret scanning, and cleanup. Missing
provider credentials make this live gate explicitly unavailable; they never
turn a skipped test into release evidence.

The U1b adapter publishes through `WorkflowCreatorEvidence` but deliberately
retains a typed non-passing receipt after a successful model loop until U14
supplies execution custody and U15 owns the final authenticated claim.

## Local feedback loop

During implementation, run the smallest relevant test files directly:

```bash
bundle exec ruby -Itest test/unit/example_test.rb
bundle exec ruby -Itest test/integration/example_test.rb
```

Do not run the full suite after every commit. Use the default suite as a broad
local checkpoint, normally once before handoff:

```bash
bundle exec rake test
```

Tests that construct project-local state stores must pass a disposable project
root from `with_tmp_dir`. Isolating `HOME` does not redirect
`<project>/.hive-state`, so using the checkout root can pollute live Patrol
recovery state. The Patrol PR-opener helper rejects the repository root before
creating or reserving an occurrence, in addition to keeping each stateful test
inside its own temporary project.

Pre-release candidate operations are separately scoped. `plan`, `list`,
`inspect`, and `collect` are observational; `run`, `resume`, and `rerun` append
local candidate evidence; only `dispatch` writes to GitHub. A successful local
scope remains `qa_blocked`, while the trusted remote aggregate requires every
deterministic cell and treats provider-backed live proof as advisory. See
[[release-candidate]] for the exact commands, cache materialization argv,
retry identities, and tag handoff. The default local runner has no production
historical executor and reports `compliant_local_upgrade_executor_unavailable`;
focused tests inject its fixed executor seam, while the real upgrade cells are
hosted proof.

The default suite excludes four expensive outer-proof files and skips the
single large babysitter command-classification matrix. CI runs all five proofs
as named gates and feeds their matrix result, together with exhaustive coverage,
into the already-required `rake test (Ruby 3.4)` check. The aggregator uses
`always()` and fails unless coverage and the complete matrix succeeded,
preserving one fail-closed merge contract for branches created before and after
this workflow change. The remaining babysitter dry-run tests stay in the normal
suite because they are the fast/core coverage for `DryRunEnv`. Every generated
gate also enables a test-helper guard that requires at least one non-skipped
test with an assertion, preventing an emptied file or stale filter from passing
with zero useful work.
Contributors do not normally need the dedicated tasks locally. When diagnosing
a corresponding CI failure, use:

```bash
bundle exec rake test:packaged_web_bootstrap
bundle exec rake test:tui_reactivity_perf
bundle exec rake test:setup_agents_integration
bundle exec rake test:babysitter_dry_run_security_matrix
```

The packaged-web gate is commit-bound: it archives `HEAD:web` to reproduce the
release artifact. Commit relevant web changes before using that task locally;
otherwise it deliberately tests the previously committed tree.

The standalone Agent CLI Runtime component suite is part of the root `test`
dependency graph and also has an explicit task:

```bash
bundle exec rake test:agent_cli_runtime
bundle exec ruby -Itest -Ilib test/unit/agent_cli_runtime_component_test.rb
bundle exec ruby -Itest -Ilib test/unit/agent_cli_runtime_release_contract_test.rb
```

The first command runs the package's own tests. The two root files pin
Hive/package behavioral parity and the component release workflow contract.
Parity covers non-default compilation, successful local probes, custom named
capabilities, nested/missing usage variants, and observable redaction across
Claude, Codex, Pi, and Grok.

## Component boundary contract

`config/component-boundaries.yml` is checked by
`test/unit/component_boundaries_test.rb`. The test validates catalog shape,
repository-local paths, unique ownership, an acyclic component graph, bounded
migration exceptions, selected source-level dependency/construction rules,
exact authorized internal-construction sites, and fresh-process loading for
every `boundary-ready` component. One staged candidate may have an empty
consumer list only when it carries exactly one bounded migration exception;
removal units accept hierarchical plan IDs such as `U1a1c`:

```bash
bundle exec ruby -Itest -Ilib test/unit/component_boundaries_test.rb
bundle exec ruby -Itest test/unit/packaging/workflow_creator_values_test.rb
bundle exec ruby -Itest test/unit/packaging/workflow_creator_text_safety_test.rb
bundle exec ruby -Itest test/unit/packaging/workflow_creator_core_test.rb
bundle exec ruby -Itest test/unit/packaging/workflow_creator_evidence_test.rb
bundle exec ruby -Itest test/unit/packaging/live_agent_proof_test.rb
```

Ready components cannot depend on candidates. Forbidden-construction rules
also apply to guarded candidates. Components can name a bounded construction
scan surface; its Ripper fence recognizes both parenthesized and
parenthesis-free `.new` calls and permits a private collaborator only at the
catalog-authorized composition file. The helper can run a named focused
clean-load proof for a candidate such as Attempts without representing the
whole component graph as ready.

The live-agent proof suite exercises the strict U1a2 cutover: source admission
requires the exact four canonical vocabulary-named JSON files in an
owner-private directory, attestation retains those exact bytes, and verification
revalidates them after the source directory disappears. Missing, extra,
symlinked, hardlinked, non-private, oversized, noncanonical, cross-bound, or
retained-substituted members fail through the existing proof error boundary.
Semantically valid support members containing credential-shaped bytes also
fail before any proof directory is created. Release-candidate coverage proves
the managed-Web archive executes the exported candidate helper even when it
differs from the checkout-loaded implementation.
The live workflow still produces only the former primary file, so provider-backed
Workflow Creator proof remains unavailable until the complete bundle-producing
units land; this focused suite is deterministic custody/semantic proof, not a
live pass.

Workflow Creator Values keeps its clean-load and dependency proof outside the
generic component loader. The Values suite directly runs its leaf under
`ruby --disable-gems -I<repository-root>`, verifies JSON remains unloaded and
that capture performs no `File`, `Dir`, or `Process` calls, and uses a
leaf-local `Ripper.lex` token check that catches bare and qualified `require`
and `require_relative` identifiers without treating comments or strings as
code. It also covers exact core type admission, recursive ownership/freezing,
canonical bytes, hostile dispatch, post-load core replacement, copy/Marshal
denial, and declared resource ceilings. The expensive 20,000-case IEEE-754
and randomized canonicalization campaign is opt-in: run
`bundle exec rake test:hostile` (or set `HIVE_HOSTILE_TESTS=1` for the focused
Values file). Normal `rake test` and coverage still run the deterministic
Values and TextSafety contract tests, but skip those two property methods so
the merge gate does not pay the hostile-campaign runtime.

The TextSafety suite passes positive public inputs only through
`Values.capture(...).value`. It covers UTF-8 byte truncation, safe-relative-path
matrices, bounded unique exact-secret scanning, fixed pattern ordering,
overlapping redaction ranges, complete and truncated private-key envelopes,
fixed failures, private captured handles, both load orders, and post-load core
replacement. The Values suite's honest Ripper counter includes methods and
proc/lambda callables and proves the exact individual and composed
line/callable/decision caps; the R43 RuboCop overlay checks every method in both
production files. These tests do not assert generic require-path
canonicalization or origin authentication.

The helper uses Ruby syntax rather than comments or string examples for literal
`require`, `require_relative`, and `Constant.new` checks. It remains an
architecture guard, not a security sandbox; see [[component-boundaries]] for
the enforced contract and its limits.

### Patrol U3a protocol and report conversion

The U3a slice is deliberately local and deterministic. Its focused files pin
canonical receipt bounds, independent full fault-step and typed-artifact
bindings including exact receipt identity, a non-public verified-token
constructor, exact-replay telemetry versus semantic/idempotency duplicates,
unsettled-effect refusal, occurrence/capture wrapper consistency, unique comparable decision identity plus
decision-class/repository-SHA/change-window diversity, stable configuration,
cross-lane candidate/catalogue/source/manifest/scenario/configuration binding,
monotonic report CAS with two fresh lanes required after invalidation, exactly
superseded contradiction invalidation, two-lane partial report reload/merge,
strict JSON-schema composition with the U2 values, complete released-v1 migration shapes,
source/archive/receipt linkage, interrupted receipt repair, reverse digest CAS,
descriptor-safe shared locking, stable-admission restoration after interrupted
upgrade, typed report-v2 cutover refusal, and report migration from every stable
Patrol adoption state. The focused module-migration command test also pins the
bounded strict-UTF-8 stdin facade, exact top-level request keys, delegation,
result projection, and deterministic-qualification consent gate. They do not execute a
scenario, launch a provider, produce installed/live qualification, or exercise
authorized cutover and rollback:

```bash
bundle exec ruby -Itest -Ilib -e \
  'ARGV.each { |path| require File.expand_path(path) }' \
  test/unit/modules/migration/patrol_evidence_receipt_test.rb \
  test/unit/modules/migration/patrol_evidence_verifier_test.rb \
  test/unit/modules/migration/patrol_effect_index_test.rb \
  test/unit/modules/migration/patrol_qualification_test.rb \
  test/unit/modules/migration/report_projection_test.rb \
  test/unit/modules/migration/report_migration_test.rb \
  test/unit/modules/migration/report_test.rb
bundle exec ruby -Itest -Ilib test/unit/modules/migration/patrols_test.rb
bundle exec ruby -Itest -Ilib test/unit/schema_files_test.rb
bundle exec ruby -Itest -Ilib test/unit/component_boundaries_test.rb
```

The component test fixes the U3a topology at exactly six production-owner
paths and compares each owner's literal Hive require edges with the approved
one-way graph. Existing U2 evidence tests remain the regression boundary for
the receipt's embedded capture, intent, and terminal effect values.

### Patrol reduced installed-CLI qualification smoke

`bundle exec rake e2e:patrol_qualification_reduced` is opt-in and hostile to a
casual checkout: it requires absolute `HIVE_PATROL_QUALIFICATION_PROJECT`,
`HIVE_PATROL_QUALIFICATION_HOME`,
`HIVE_PATROL_QUALIFICATION_OBSERVATIONS`, and
`HIVE_PATROL_QUALIFICATION_EVIDENCE` paths. The disposable project must already
contain exactly twenty real comparable shadow records described by the
committed catalogue and observation document. The controller is read-only over
those records.

The observation document is a
`hive-patrol-reduced-observations` v1 object with one exact case row per
catalogue ID. Each row binds the persisted trigger ID, repository SHA, change
window, catalogue fault label, and one-to-four typed external process outcomes
(`exit`, `signal`, or `child_timeout`). Success is `{kind: "exit", status: 0}`;
retry and restart cases must retain both the failed/signalled first outcome and
the successful successor. These rows are process evidence supplied with the
prepared project, not facts inferred from a receipt returned by the candidate.

The controller uses `git archive <full HEAD>`, hashes the archive, builds and
privately installs the exact candidate gem through
`packaging/live_agent_skills/install_candidate_gem.sh`, and invokes only that
installed `bin/hive` from the project cwd. Both first-party modules are
installed through the public preview/receipt/consent CLI against a local Git
catalogue selected with `GIT_CONFIG_*` URL rewriting. Apply responses and
`module inspect` readback must bind the exact catalog commit, source revision,
manifest digest, and configuration digest. Each ordinary and
Architecture Patrol selector goes through the internal installed-CLI facade,
`hive module migration deterministic-receipt --json`; the final raw receipts
and independently reconstructed bindings go through
`deterministic-qualification --yes --json` and real report-v2 digest CAS. The
returned v2 projection must equal the canonical persisted report and bind this
campaign's candidate, run, scenario, receipts, module summaries, and content
identities.

Every child has bounded stdin/stdout/stderr, an allowlisted environment, a
monotonic child deadline nested under a campaign deadline, `pgroup: true`, and
TERM/KILL whole-group teardown. Spawn, exit, signal, child-timeout, and
campaign-timeout results remain distinct. Success and failure summaries are
bounded, redacted, secret-scanned, mode-0600 evidence; successful evidence is
not discarded. The successful proof records the exact E2E and focused-contract
counts plus a compact, ID-sorted `case_results` inventory containing each
case's module, fault label, and typed process outcomes.

The catalogue labels only externally observable process-boundary cases as
`e2e`: the combined post-reservation process restart, provider/CLI failure,
released-attempt retry, and finalized outbox/reconciliation recovery. Capture versus
decision persistence, module projection persistence, effect-intent uncertainty,
and the GitHub shim barrier are `focused_test` links to exact existing test
methods. External process kills do not claim those interior atomic contracts.
The same-head catalogue is not an independent oracle, prepared records are not
a fresh scheduler-driven matrix, and a private exact-gem install is not
Homebrew/AUR/install.sh installed/live proof. This smoke therefore does not
close full U3b, U3-ARCH-005, or U3c.

## Coverage

```bash
bundle exec rake coverage
```

The coverage task uses Ruby's stdlib `Coverage` API. It starts line and branch coverage in the parent test process and prepends `RUBYOPT=-Itest -rhive_coverage_boot` so Ruby subprocess tests dump their own result files under a per-run `coverage/.resultset/<run-id>/` directory. The final merged report is written to `coverage/coverage.json` and prints the lowest-covered source files plus uncovered line numbers.

`bundle exec rake coverage` is the exhaustive CI coverage-report path, not an
after-every-commit agent loop. It instruments the default suite; three
outer-proof files and the large babysitter command-classification matrix run in
their dedicated CI jobs instead. Coverage fails when an executable source file
was never loaded, when a subprocess result file cannot be read, or when line
coverage drops below the default 100% threshold.
At a 100% minimum, the gate compares the exact covered and executable line
counts; the displayed two-decimal percentage is informational and cannot hide
one uncovered line that rounds to `100.00%`. Set `HIVE_COVERAGE_MIN_LINE` to a
different numeric percentage only when intentionally loosening or tightening
that gate; lower configured thresholds retain percentage comparison semantics.
Visual-artifact and Screenote code paths are part of that 100% gate, including
error/default branches such as invalid Screenote JSON, default Net::HTTP
transport, manifest upload exceptions, missing media directories, screenote
config type errors, and dry-run digest completion failures.

Coverage-included tests that only need a generic stdout/stderr subprocess should avoid `RbConfig.ruby` children unless they are explicitly testing Ruby coverage propagation. Those nested Ruby processes inherit the coverage `RUBYOPT`, which can make startup latency part of otherwise unrelated timeout assertions; use a tiny executable fixture script for generic capture/timeout seams.

In CI (`CI=true`), tests that exercise backgrounding commands must force a foreground path (for example `foreground: true`) or stub daemonization. Otherwise the test process can daemonize before Minitest `after_run` writes `coverage/coverage.json`, leaving the parent coverage task with a missing report while child output keeps streaming. Bundler evaluates the gemspec before coverage starts, so the bootstrap reloads the preloaded `lib/hive/version.rb`, `lib/hive/errors.rb`, and `lib/hive.rb` files in dependency order. Reloaded code must therefore be idempotent; for example, self-derived enum constants must exclude `:ALL` to stay reload-safe.

`Rakefile`:
```ruby
HIVE_CI_GATE_TESTS = {
  "test:packaged_web_bootstrap" => "test/integration/web_packaged_bootstrap_test.rb",
  "test:tui_reactivity_perf" => "test/integration/tui_reactivity_perf_test.rb",
  "test:setup_agents_integration" => "test/integration/setup_agents_test.rb",
  "test:babysitter_dry_run_security_matrix" =>
    "test/unit/babysitter/dry_run_security_matrix_test.rb"
}.freeze
HIVE_CI_GATE_TEST_OPTIONS = {
  "test:babysitter_dry_run_security_matrix" =>
    "--include=test_stubs_skip_unknown_and_mutating_commands_but_allow_read_only_commands"
}.freeze
HIVE_DEFAULT_TEST_FILES = FileList[
  "test/{unit,integration,babysitter}/**/*_test.rb"
].exclude(*HIVE_CI_GATE_TESTS.values).to_a.freeze

Rake::TestTask.new do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = HIVE_DEFAULT_TEST_FILES
  t.warning = false
end
task default: :test
```

## Test helpers (`test/test_helper.rb`)

- Normal test processes replace `HOME` with a disposable
  `hive-test-user*/home` directory before loading Hive, then remove it after
  the suite. They delete inherited Hive, XDG, Claude/Codex/Pi/Grok, GitHub, and
  Git global-path overrides instead of pinning them to fixed paths. Production
  defaults therefore keep following `HOME` when an individual test swaps it,
  while Git's standard global files remain under that test's disposable home.
  `GIT_CONFIG_GLOBAL` is removed rather than replaced because the babysitter
  correctly rejects that caller-controlled execution channel. This keeps
  subprocesses hermetic even when the caller is a daemon
  exporting real user paths: tests cannot recreate legacy attempt roots,
  rewrite managed agent skills, consume real GitHub configuration, or change
  credential helpers, hooks, and signing settings. The authenticated
  `rake smoke` task explicitly opts out because it exists to exercise real
  operator logins; direct smoke-file runs must set
  `HIVE_TEST_ALLOW_REAL_USER_ENV=1` deliberately.
- `with_tmp_dir` — `Dir.mktmpdir("hive-test", &block)`.
- `with_tmp_git_repo` — `git init -b master`, configures user/email and disables GPG signing, makes one initial commit, yields the path.
- `with_tmp_global_config(home: nil)` — overrides `ENV["HIVE_HOME"]` to a tmp dir, writes an empty `registered_projects: []` YAML, and defaults `HOME` to the same tmp dir so subprocesses and service-installer tests do not touch the operator's real home. Pass `home:` when a test intentionally installs fake user-level skills or plugins under a separate fake HOME.
- `run!(*cmd)` — shells out and raises on non-zero exit (used in setup helpers; not for testing the CLI itself).

## Fixtures

| Path | Purpose |
|------|---------|
| `test/fixtures/fake-claude` | Shell fixture for built-in provider headless argv. It can log/output/write, make one commit, or create a deterministic multi-commit sequence with progress/release sentinels for durable caller-loss scenarios. E2E points `HIVE_CLAUDE_BIN`, `HIVE_CODEX_BIN`, `HIVE_PI_BIN`, and `HIVE_GROK_BIN` at it. |
| `test/fixtures/fake-gh` | Shell script that handles `gh pr create` / `gh auth status` / `gh pr list`, returns a dummy URL. |
| `test/fixtures/voice/voice-idea.oga` | Checked-in Ogg/Opus speech sample saying "voice idea" for the Telegram voice-note E2E path. `run_idea_e2e.sh` uses it by default when `TG_IDEA_MODE=voice`; explicit voice mode hard-fails when `HIVE_WHISPER_API_KEY` is unset. Voice mode uses the same fixture for both new audio idea capture and audio brainstorm answers. |

## Unit suite (`test/unit/`)

| File | Covers |
|------|--------|
| `config_test.rb` | `Hive::Config` — defaults, `default_workflow`, deep-merge, register/find, observation-only legacy-registry reads without moving it into XDG storage, malformed YAML rejection, normal and patrol reviewer validation, Screenote base URL validation, and the migration error for obsolete `screenote.api_token`. |
| `workflow_test.rb`, `stage_label_test.rb`, `bot/title_formatter_test.rb`, `workflow_selection_test.rb`, `content_workflow_fixture_test.rb`, `workflows/{coding,content,bench,descriptor_parser,loader,project}_test.rb`, `commands/workflow_new_test.rb` | Shared acronym-aware stage labels, workflow selection, descriptor parsing/loading, project overlay registration including resolved-config reuse, blank/research scaffold authoring, retired Architecture/Writing guidance to Honeycomb, built-in descriptor shape, and test-only fixture support — CLI selector validation, runtime discovery, cache invalidation, deterministic content-agent artifacts, registry leak guards, agent/model/effort and council validation, active terminal stages, archive-retention omission defaults, exact positive-integer/`never` validation, explicit built-in/scaffold `3`, lazy malformed-descriptor isolation, and content-signature reloads without a last-good policy fallback. |
| `task_test.rb` | `Hive::Task` — path regex, descriptor-driven stage/index validation, explicit workflow pin/project default/`coding` fallback, derived paths, metadata completion-clock access, and slug edge cases. |
| `markers_test.rb` | `Hive::Markers` — set/get round-trip, attribute quoting, last-marker semantics, generated recovery identities, and compare-and-swap migration that cannot overwrite a newer marker generation. |
| `atomic_file_test.rb` | `Hive::AtomicFile` — atomic file replacement plus the shared directory-fsync helper's real flush and unsupported-platform (`NotImplementedError` / `EINVAL` / `ENOTSUP` / `EBADF`) behavior. |
| `attempts/*_test.rb`, `daemon/attempt_loss_healer_test.rb` | Durable task attempts — record/schema/CAS edges, competing claim/expiry, artifact-plus-dependency-verdict generation duplicates/successors, inherited-output fallback, authenticated launching handoff acceptance, capacity, detached session lifecycle, final terminal/lost frame drain, PID-reuse-safe adoption and orphan cleanup, marker/git evidence precedence, legacy backfill, mutation-free dirty capture, and restart-persistent unbounded loss healing paced by the shared cooldown. |
| `attempts/context_test.rb`, `commands/{run,stage_action}_test.rb`, `integration/{run_error_envelope,run_stage_action}_test.rb` | Durable command-result interpretation — authenticated task/stage binding for generic `run`/`approve` and stage-specific admitted argv, plus the shared `CommandDispatch` policy for success receipts, lost attempts, non-zero receipts with or without worker JSON, exact exit propagation, and one command-shaped error document when a failed worker emitted none. |
| `work_ledger_test.rb`, `task_journal_test.rb`, `conditions/*_test.rb`, `task_projection*_test.rb`, `task_action_conditions_test.rb` | Policy-light WorkLedger plus Hive-owned generation conditions — clean loading without workflow/condition/attempt policy; structural descriptor topology; exact cursor/hash receipts; locked, fsynced, idempotent complete JSONL append with short-write completion and partial-append rollback; generic replay duplicate/malformed refusal; strict Hive journal durability/attempt integrity; authenticated compatibility replay with future-schema/forged-attempt rejection; registry/evidence lifecycle; generation/HEAD reconciliation; deterministic supersession; telemetry-tail-stable snapshot validation/replay; gate/migration/shadow modes; execute boundary ordering; canonical TaskAction/status consumption; and sanitized task-1849 replay across missing/corrupt/stale snapshots with durable-attempt metadata and live-observation sentinels. |
| `lock_test.rb` | `Hive::Lock` — acquire/release, stale-PID detection, commit lock parallelism. |
| `worktree_test.rb` | `Hive::Worktree` — create attach-vs-new, dependency override stacking (incl. narrow-refspec and origin-ahead-of-local **and** local-ahead-of-origin placeholders), explicit remote-head selection over a same-named tag, stalled-transport deadline/process-group cleanup, empty placeholder re-pointing, fail-closed preservation when the emptiness check errors, local-only prerequisite fallback, real-commit preservation, detached exact analysis materialization plus orphan-registration self-healing, PR-head materialization/retry/failure handling, delete-failure errors, `local_branch_ref_exists?` blank-name guard, remove, exists?, pointer round-trip, prefix validation. |
| `dependencies_test.rb`, `task_meta_test.rb`, `plan_frontmatter_test.rb`, `repository_identity_test.rb`, `dependency_admission_test.rb`, `dependency_snapshot_test.rb` | Fail-closed dependency admission and preserving task metadata — exhaustive scalar grammar and duplicate-key rejection; tolerant-vs-strict metadata reads and corrupt-mutation refusal; immutable UTC `completed_at` first-write behavior and preservation across rewrites; bounded optional exact plan assertion; indexed same/cross-project and archived-fallback resolution; workflow/action-aware completed dependency snapshots; full cycle paths; and unexpected-error backstop. |
| `completion_time_test.rb`, `completed_at_backfiller_test.rb`, `commands/{approve,run}_test.rb` | Completion-clock durability — inert versus active terminal stamping, first-completion immutability, metadata/move/index/runner-failure/interrupt rollback, earliest credible membership-workflow Git event before state-file/folder mtime fallbacks, deadline-killed history and blocked-reader work, captured-generation backfill, restart-persistent fair rotation, cursor I/O degradation, path-only commits that preserve unrelated staging, concurrency, and fail-open warnings when discovery or persistence cannot provide a durable clock. |
| `integration/dependency_admission_test.rb`, `run_approve_test.rb`, `run_stage_action_test.rb`, `new_test.rb` | Supported-boundary coverage — anonymized plan-only ordering and repository-mismatch fixtures, fresh validation before run/rebase/runner or forward approve mutation, retryable waits, non-retryable admission errors, `--force` refusal, backward recovery, composed JSON propagation, and all three creation forms. |
| `git_ops_test.rb` | `Hive::GitOps` — default-branch detection, orphan worktree bootstrap, idempotent gitignore, empty-diff commit skip. |
| `rebase_test.rb` | `Hive::Rebase` — skip/fail-soft guards, conflict handling, exact-OID leased publication after successful history rewrites, real bare-remote proof that later commits remain fast-forward pushable, pre-PR branches staying absent from the remote, concurrent remote movement rejecting the stale lease without overwrite, and no publication after failed preflight, divergence, or rebase. |
| `agent_git_gate_test.rb`, `managed_git_test.rb` | `Hive::AgentGitGate` — clean-loadable immutable read/observation/materialization/publication values; closed operations and unknown-argument refusal; hook/fsmonitor/diff/filter/config/environment helper suppression; repository-local executable-config refusal; forbidden transports; real bare-remote expected-absence and expected-OID leases; independently observed before/after receipts without target leakage; ref-movement refusal; bounded reads; and root-confined detached exact materialization/reuse. |
| `gh_test.rb`, `gh_digest_test.rb` | `Hive::Gh` — PR frontmatter parsing, secret-scan fetch-failure semantics, open/merged PR lookup, `pr_state` success/error parsing, `pr_metadata` parsing/error handling/project `chdir:` scoping, `PushResult`, managed Agent Git Gate observation/publication delegation, owner-private draft body tempfiles, process-group timeout/termination including a TERM-resistant stdout-inheriting helper, shared strict GitHub host/repository validation across normal and architecture-patrol transports, exact created-PR head/base OID identity checks, `mergeStateStatus` request shape for open PR listing, merged-PR digest repo discovery/listing helpers, failing-job log clipping, and digest-specific explicit-host REST pagination/detail/raw-diff/file evidence with malformed/cap failure coverage. |
| `draft_pr_receipt_test.rb`, `stages/draft_pr_handoff_test.rb` | Managed draft-PR controller — strict atomic phases and receipt evidence; exact absence-leased publication and one-attempt ambiguous push/create recovery; byte-exact UTF-8 report resume and reparsing; retried root-confined no-fix cleanup and quarantine redaction; PAT/history/binary/oversize quarantine through closed hardened reads; PII-safe projection; remote identity blocks; terminal artifact repair; and no corrective/ready/merge/close/edit/release/publish/deploy operations. |
| `pr_test.rb` | `Hive::Pr` — pull-request-number extraction from `/pull/<number>` URLs, including query/fragment/trailing-slash tolerance, nil for issue/non-number/subpage URLs, `identifier_to_number` acceptance/rejection for `hive review --pr`, and http(s) URL validation including invalid-URI rejection. |
| `agent_limit_test.rb` | `Hive::AgentLimit` — provider-limit classifier for Claude usage-credit menus and common quota/rate-limit API errors; provider reset-estimate parsing for display; marker-age-only periodic retry eligibility; and the shared quota-held display/JSON helpers (`held?`, provider extraction, UTC reset display, label text, and `held` field shape), with runnable false-positive guards for source line numbers and ordinary "missing rate limit" findings. |
| `agent_runtime_test.rb`, `agent_test.rb`, `agent_profile_test.rb`, `agent_profile_modes_test.rb` | `Hive::AgentRuntime` / `Hive::Agent` / `AgentProfile` — immutable provider-neutral request/invocation/evidence/result contracts; exact positional, stdin, and flag-value transport for Claude/Codex/Pi/Grok; fail-closed headless, sandbox, required-directory, model/effort, raw-argument, and named-capability requests; bounded redacted diagnostics; spawn/wait/timeout/SIGINT forwarding; version/capability process-group cleanup; observable status/usage normalization; safe-mode non-leakage; and provider-limit classification before generic exit-code / expected-output failures. |
| `artifact_firewall_test.rb`, `protected_files_test.rb`, `secret_patterns_test.rb`, `agent_profile_modes_test.rb`, `claude_launcher_test.rb`, and affected `stages/*` tests | `Hive::ArtifactFirewall` — immutable manifest/snapshot/report contracts; bounded and duplicate-free manifest inputs; no-follow add/change/delete/symlink/directory/mode/parent/unreadable classification; descriptor-bound captured bytes and baseline identity, including open-time type changes and legacy capture verification; non-empty regular required outputs inside realpath-checked writable roots; immutable in-memory captures; bounded injectable redaction and fail-closed internal-error translation; snapshot/report binding; atomic verified restoration with parent-substitution refusal, including exceptional spawn exits; non-recursive and unreconstructable failure; symlink rejection in headless/tmux output polling; exact execute/open-PR/finalize/review/managed-worktree marker and result adapters, including aliased Git config environment paths; clean loading; and the production `ProtectedFiles` bypass guard. |
| `skill_check_test.rb` | `Hive::SkillCheck` — exact Claude `/hive`, Codex `$hive`, Pi `/skill:hive`, and Grok top-level invocation parsing/discovery; Claude/Codex plugin fallback paths; enabled Grok installed-plugin registry/config resolution; Pi package/settings/git discovery; malformed invocation hints; and deterministic `npm root -g` success/timeout coverage. |
| `agent_skills/{facade,canonical_skill,directory_publisher,inspector,openclaw}_test.rb`, `commands/{doctor,doctor_managed_skills}_test.rb`, `openclaw_skills_test.rb` | Canonical Hive operating skill and diagnosis — clean-loading `Hive::AgentSkills` render/inspect/plan/apply contracts; deterministic OpenClaw/Claude/Codex/Pi projections and invocations; canonical/file digests; Codex interface metadata; generated OpenClaw correspondence; non-mutating previews; stale-plan and foreign-content refusal; safe whole-directory atomic publication; ownership/mode/symlink refusal; rollback boundaries; orphan detection; filesystem-only native/ClawHub evidence; zero agent-runner calls; production internal-require guards; and byte-identical disposable homes under Doctor. |
| `operational_status_test.rb`, `operational_action_test.rb`, `commands/{status,act,watch}_test.rb` | Agent operations — seven closed task states including dependency-blocked precedence, partial/unknown completeness, policy-complete scheduler joins/freshness, id-less migration blockers, canonical-request-only queued recovery, max-pass review intervention, candidate-filtered lean recovery projection, compact human bands/overflow, workflow-retention-filtered ordinary sets and aggregate hidden counts, command-free tokenized actions with lock-time freshness checks and real stage/run/approve command paths, bounded semantic JSONL observation, target resolution, source/disappearance budgets, signals, EPIPE, and read-only behavior. |
| `daemon/{operational_snapshot,status_consumer,concurrency_controller,dispatcher}_test.rb` | Coherent scheduler observation — ordinary visible-row consumption and hidden-count aggregation, owner-private atomic storage, generation-bound runtime-readiness and shutdown acknowledgement, live daemon generation/expiry/phase validation, duplicate project/slug frame rejection, identity/generation/marker/action/dependency/admission revalidation across the tick source window, task-only capacity that excludes patrol/digest workers, queue/provider/recovery evidence, and advisory publication failures that cannot stop dispatch. |
| `wiki_log_test.rb` | `Hive::WikiLog` — fragment sorting, generated-block idempotency, stale detection for compiled `wiki/log.md`, and dropping template prose that is not a real legacy `##` entry. |
| `schema_files_test.rb` | Published JSON schema contracts — current-version schema files exist for every `Hive::Schemas::SCHEMA_VERSIONS` entry, back-compat schema files remain for pinned consumers, producer required-key drift is pinned, `hive-status` task properties stay aligned with `Snapshot::Row` including the optional quota `held` object, `hive-dispatch-request` claimed files remain schema-valid, and every schema filename/version matches its `$id` basename or URN suffix plus `title` version text. |
| `commands/{approve,finding_toggle,run,stage_action,status}_test.rb`, `integration/{run_error_envelope,status_error_envelope,run_findings,markers_command}_test.rb` | Shared runtime error-envelope production — command-specific schemas, closed error-kind mappings, condition-gate recovery fields, approve final-stage extras, findings operations, status/diagnose schema selection, single-document stdout guards, internal-error wrapping, and emit-time JSON failures after the producers converge on `Hive::Schemas::EnvelopeEmitter`. |
| `cli_test.rb` | `Hive::CLI` — command delegation and option threading for the Thor surface, including `hive workflow new`, `hive generate-name` lookup scoping, and internal archive recovery flags. |
| `commands/bench_submit_test.rb` | `Hive::Commands::BenchSubmit` — resolves completed `9-done` tasks from registered projects, derives the source repo from GitHub `origin`, requires `worktree.yml` + `pr.md`, aborts before PR creation on local secret findings, and surfaces missing slugs/checkouts as usage errors. Coverage now includes the default local secret scanner, JSON/text reporting, `run_git`, extractor invocation against a stub `harness/extract.rb`, and submission branch creation with a real local Git push to a bare fixture while `gh` and external GitHub interactions remain stubbed; no real hive-bench validator or GitHub PR is exercised. |
| `workflow_package/*_test.rb`, `commands/workflow_{install,list,remove,update,publish}_test.rb`, `integration/{honeycomb_workflow_lifecycle,workflow_publish_cli,workflow_publish_submission}_test.rb`, `web/workflow_lifecycle_test.rb`, `workflow_lifecycle_schema_test.rb` | Legacy Honeycomb author-package canonicalization/security plus current v2 authoring, publication, and install lifecycle — metadata/README/no-follow component snapshots, canonical immutable v1 package bytes, canonical YAML and release/package fingerprints, checksum-bound pinned lint rules/fixtures/expectations with redacted findings, exact actor permission projection and optional-input redaction, exact/wildcard domain and shell/path-hook enforcement, direct-governance negation hardening, catalog/manifest/source-provenance binding, owner-private receipt/bundle/object integrity with retained-checkout symlink refusal, monotonic concurrent receipt/observation updates, intent-before-effect direct/fork submission recovery, fork-parent and commit-parent authority, digest-matching external-branch adoption, deleted-terminal-branch lifecycle recovery with live-open and surviving-branch identity checks, current-vs-cached PR/catalog lifecycle, schema-v2 dry-run/digest binding and exact error-kind/exit/retry arms, v2 flat-catalog install/configuration snapshots, immutable store transaction/task-pin concurrency, isolated invalid-selection warnings, incomplete-pin cleanup refusal, executable-mode hardening, Hivebox-to-real-CLI preview/apply delegation with package/selection/configuration identity rebinding, Rails `Workflow` row modelling, route-bound workflow-change operations, lifecycle preview/consent/ownership, post-commit warning semantics, closed JSON envelopes, deterministic legacy packaging, and injected fork/PR seams. No fixture executes package instructions or uses live GitHub. |
| `commands/daemon_test.rb` | `Hive::Commands::Daemon` and `Hive::Daemon::StatusReport` — lifecycle command routing, PID-file ownership/status handling, detached start/re-exec behavior, service install/enable/disable output, daemon-status service/binary fields, `safe_payload` web degradation, `binary_drift` classification including `unreadable`, queue inspection, start-path wiring of daemon/update/answer-digest config into the dispatcher, and `daemon.auto_retry.enabled` config threading into the dispatcher. |
| `commands/setup/*_test.rb` | `Hive::Commands::Setup` — agent-skills-first ordering, one consent boundary, `--yes`, JSON/non-TTY refusal before diagnostics or agent discovery, diagnose-only `--no-bootstrap`, nested-init preflight suppression, phase-success predicate and JSON/process-exit agreement, the shared `phase(name)` StandardError-to-`ok:false` wrapper for QMD bootstrap, web-bundle, daemon-service, enrollment, and optional web-service phases, and hard diagnostic failures. |
| `packaging/live_agent_proof_test.rb`, `packaging/managed_web_archive_test.rb`, `release_contract_test.rb` | Exact-SHA candidate construction — deterministic manifest/archive bytes including commit-timestamp-pinned managed-Web subtree archives, offline byte-for-byte verification of all four canonical projections, installed-version binding, and web-bundle digest verification before trusted hosted fan-out. Optional authenticated proof coverage still pins four required evidence rows, command allowlists, native-activation attestation, secret scanning, Check Run binding, and selector rejection of stale or substituted proof. |
| `packaging/release_candidate_{baseline_catalog,baseline_cache_materializer,asset_verifier}_test.rb`, `integration/release_candidate_installed_target_test.rb` | Reviewed pre-release baselines — strict v0.6.9/v0.4.1/v0.4.2 catalog identity, exact package and checksum/signature/certificate metadata, checked-in digested runtime-closure manifests, non-floating latest-stable freshness, producer/observer dependency-lock and offline-closure completeness, catalog closure-policy attempt identity plus predecessor cache revalidation, read-only tag-scoped release-asset and explicit cache-materialization fetch argv, regular-file/symlink/substitution/archive safety, signed-checksum binding, role-only gem/skills targets, closed process environment, and engine-specific no-network/no-socket/no-device sandbox argv. The coverage job fetches full Git history so these tests can compare the checked-in closure metadata with the reviewed release-tag locks. The tests otherwise use synthetic cached bytes and command contracts; they do not run a historical package or container. |
| `packaging/release_candidate_{remote_identity,remote_workflow,aggregate,hosted_stage,release_selector}_test.rb`, `release_contract_test.rb` | Trusted hosted candidate proof and exact-byte tag handoff — protected-main/workflow/action-lock/run/attempt/artifact identities, bounded request resolution/collection, closed blocking aggregation, exact ordinary-CI identity, predecessor retry composition, staged-before-install containment, full-SHA Actions, 30-day artifacts, the checkout-free final `checks: write` publisher, trusted Check/evidence selection, safe archive extraction, original-producer identity across retries, and manifest/version/latest-stable validation before publication. Tests use deterministic API/cache fixtures and do not dispatch GitHub Actions, run historical packages, create a tag, or publish. |
| `packaging/release_candidate_{invariant_snapshot,process_teardown,upgrade_runner}_test.rb`, `integration/release_candidate_{fixed_phase_executor,latest_stable_upgrade,legacy_bench_v041_upgrade}_test.rb` | Pre-release upgrade survivors — fixed role-only producer/observer/candidate phase order, real-executor argv and exact legacy bench descriptor/instruction creation, required v0.4.2 collision observation, semantic status/doctor normalization, named task/config/attempt/receipt/web/service invariants, explicit migration diffs, strict second-run idempotency, bounded closed-environment subprocesses, process/service leak failure, authenticated-cache/sandbox no-start preflight, exact candidate-SHA next action, and cloned-prefix Linux/macOS candidate identity with stale-file rejection. Fixtures cannot satisfy the real producer contract; these tests do not run historical gems or a container. |
| `user_service/user_service_test.rb`, `commands/{bot,daemon,web}/service_installer_test.rb`, `commands/service_installer/base_test.rb`, `commands/uninstall_test.rb` | `Hive::UserService` and thin Hive adapters — non-mutating inspect/plan, exact observation revalidation, drift refusal, atomic force backup/replace, typed manager partial failures, safe idempotent removal, systemd/launchd rendering and lifecycle behavior, cycle-free `WantedBy=default.target` daemon ordering, unchanged already-loaded launchd idempotency, unsupported-platform state, Homebrew stable-binary selection, macOS ProgramArguments `$0` parsing, web environment/path substitution, and uninstall ordering/warnings. |
| `commands/{bot,daemon}_test.rb`, `integration/daemon_command_test.rb`, `integration/bot/bot_lifecycle_test.rb` | Shared service-install result presentation — bot/daemon-specific text prefixes and schemas, every success/outcome mapping, drift exit 64, manager failure exit 70, force/backup guidance, hostile-installer fallback envelopes, and schema-valid subprocess behavior after both commands converge on `ServiceInstaller::ResultPresenter`. |
| `daemon/digest_scheduler_base_test.rb`, `daemon/answer_digest_scheduler_test.rb`, `london_date_test.rb`, `local_date_window_test.rb` | The retained shared scheduler-base contract, answer-digest cadence and cursor behavior, and calendar-window handling used by Hive's remaining host-local scheduling contracts. |
| `claude_launcher_test.rb` | `Hive::ClaudeLauncher` — headless/tmux delegation, readiness deadlines, prompt submission, pane logging, tmux-session loss before terminal markers and expected-output waits, Claude ready-prompt variants for line-start, line-end, banner-scrolled, Claude Code 2.1.179 separator/caret/footer, NBSP, and narrow NBSP shapes plus false-positive rejection for menus, trust/permission prompts, stale carets, and non-footer `⏵⏵` output, provider-limit menu classification, signal cleanup, and wrapper argv policy including model/effort pins. |
| `commands/run_test.rb`, `stages/agent_test.rb`, `stages/council_test.rb`, `stages/resolver_test.rb` | Descriptor-backed runner dispatch — `Run#pick_runner` passing `task.workflow`, generic `kind: :agent` prompt rendering, prior-artifact nonce wrapping, per-stage agent/model/effort spawn kwargs, provider-limit error envelopes and agent-written quota markers remaining `limits_reached` for daemon cooldown retry while non-limit envelopes remain `agent_preflight_failed`, council reviewer fan-out/triage/revise/max-round behavior including default wait and opt-in bounded completion, marker-to-action mapping, coding-name bespoke runner precedence, generic non-coding fallback, `StageError` fallback, and lazy require behavior. |
| `task_action_test.rb`, `task_action_generic_test.rb`, `daemon/policy_test.rb` | Status action classification and daemon decision coverage — coding action/command invariants, coding action golden matrix, descriptor-generic marker classification, council-stage ready/waiting/complete actions, terminal agent/council deliverable gates, generic `hive approve ... --from <stage>` and `hive run` command shape, and `ready_to_advance` policy dispatch/block/skip behavior. |
| `diagnostic_evidence_test.rb` | `Hive::DiagnosticEvidence` — read-only `hive status --diagnose` evidence fallback for rows whose status JSON diagnostic is nil, including red-status/log/marker tier ordering, source labels, newest-log-by-mtime selection, global log-dir inference, state-file fallback, redaction/truncation, invalid UTF-8 tolerance, symlink/regular-file safety, never-raise degradation, and deep YAML hardening. |
| `stages/brainstorm_tmux_sentinel_test.rb` | Claude/tmux sentinel and cleanup behavior — readiness/sentinel delegation, pgrep pattern shape, missing/failing pgrep logging, oversized orphan-sweep log rotation, and the v0.2.3 invariant that a task cleanup kills matched Claude PIDs individually while skipping a matched tmux server. |
| `display_name/generator_test.rb` | `Hive::DisplayName::Generator` — timeout handling, process groups, agent output sanitization, best-effort sidecar updates/commits, and Codex stdin prompt delivery. |
| `tmux_runner_test.rb` | `Hive::TmuxRunner` — detached session startup, environment propagation, prompt injection via tmux buffers, typed tmux failure/timeout classes, prompt-buffer cleanup, paste-settle polling before Enter submit, bounded pane-tail capture, PID lookup, idempotent teardown including tmux's `no current target` race after a short-lived child exits, and a lightweight fake-tmux timeout harness so setup commands cannot consume the timeout budget before the intentionally hanging `send-keys` call. |
| `daemon/pr_merge_reconciliation_store_test.rb`, `daemon/pr_merge_watcher_test.rb`, `daemon/dispatcher_test.rb`, `task_closure_test.rb` | Durable task-bound merge reconciliation — schema-valid/private atomic ledger writes, identity/corruption quarantine, concurrent-update locking, persisted fair cursor and uncapped/capped-time backoff; stage 5–8 plus error observation; held-candidate retention/release; open and closed-unmerged visibility; exact repository/head/reachable-merge checks; phase checkpoints before architecture/archive; restart without duplicate GitHub or intake work; per-project failure isolation; dry-run; daemon-owned same-repository closure, idempotent replay, public-channel rejection, and operator-receipt non-takeover. Dispatcher coverage proves reconciliation precedes provider recovery and consumes no provider slot. |
| `screenote/{credential_store,oauth_client,loopback_server,pkce,mcp_client,mcp_config}_test.rb`, `commands/{connect,disconnect}_test.rb` | Screenote OAuth/MCP support — mode-0600 credential storage, expiry boundaries, OAuth discovery/DCR/auth-code exchange/revoke with injectable HTTP, loopback callback state validation, PKCE S256 vectors, authenticated MCP `list_projects`, ephemeral MCP config shape/cleanup, connect project selection/client reuse, and disconnect revoke/clear behavior. |
| `stages/artifacts_test.rb` | `Hive::Stages::Artifacts` — marker/idempotent behavior, Screenote connected/disconnected context resolution, Claude-only MCP config injection/removal, strict allowed-tools behavior, and preserving the agent-written `media/manifest.json` without Ruby-side post-upload mutation. |
| `screenote_oauth_live_test.rb`, `screenote_capture_live_test.rb` | Opt-in live Screenote tests — real OAuth discovery, rate-limited dynamic registration when enabled, auth-code token exchange when preseeded, and the blocked real `create_screenshot_upload` round-trip through Screenote's non-interactive test-token endpoint once that endpoint ships. |
| `daemon/status_consumer_test.rb` | `Hive::Daemon::StatusConsumer` — ordinary `hive status --json` envelope parsing including canonical task `pr_url`, schema-version skew handling, strict `live_task_lock` and non-negative project hidden-count coercion, aggregate hidden-count parity, legacy project filtering, and local `state_file` mtime re-stat so daemon edit-resume decisions keep subsecond precision even though public JSON timestamps are whole-second ISO8601. |
| `daemon/stale_agent_healer_test.rb` | `Hive::Daemon::StaleAgentHealer` — stale `AGENT_WORKING` healing, wedged `REVIEW_WORKING` lock cleanup, marker-id/live-owner guards, attempt-loss successor release, and delegation of cooled durable errors. |
| `daemon/{recovery_coordinator,dispatch_request_queue,dispatcher,operational_snapshot}_test.rb`, `recovery_authority_test.rb`, `operational_{action,status}_test.rb`, `commands/act_test.rb` | Universal durable-error recovery — one destructive coordinator for every adapter; retry count derived from durable request history; shared cooldown/safety; strict marker-id, requestor, and canonical task identity validation; active-workflow terminal agent/council retry; restartable admitted/cleared/dispatched/terminal phases; post-clear dispatch-failure pacing; request-lock serialization; one shared queue scan per tick; hourly terminal pruning; terminal replay/retention; no phantom queued state without a canonical request id; max-pass review input enforcement across action, bot, and web; and source guards preventing adapters or attempt-loss processing from owning another marker lifecycle. |
| `hv_test.rb` | `bin/hv` — refuses unsafe Apache Hive fallback paths (`/usr/bin/hive`, `/opt/hive/bin/hive`), verifies `HIVE_BIN_OVERRIDE` can point at a custom Hive CLI install path, pins watchdog cleanup for timeout-present probes whose bad candidates fork stdout-inheriting helpers, and rejects a candidate that prints a bare semver then hangs and traps the watchdog's TERM to exit 0 (watchdog-fired sentinel forces a non-zero status). |
| `gemspec_test.rb`, `install_script_test.rb` | RubyGem/install packaging — direct runtime dependencies include Fiddle for descriptor-relative managed storage, the architecture manifest validator, PKCE Base64, and the exact managed-web Bundler; `hv` stays out of `spec.executables` so RubyGems does not create a broken Ruby binstub for the bash launcher; the bash installer writes its own `hv` wrapper and does not expect a gem-installed `hv` shim. Fault-injected installer executions also pin exact wrapper/shim byte and mode restoration across gem failure, missing output, shim staging, wrapper write, and chmod failures. |
| `babysitter/dry_run_env_test.rb` | `Hive::Babysitter::DryRunEnv`, shared `StubEnvironment`, and Git/GitHub stubs — default-deny classification, Git 2.45+ lazy-fetch preflight, hosts-only per-invocation `gh` auth views, prompt suppression, shared startup/dynamic-loader env scrubbing, direct Ruby GH launcher handoff, invalid-byte argv, executable-path scrubbing, working-tree diff/verbose-status/filter guards, `gh api` value-consuming option parsing, private pre-agent skip-log creation, concurrent append serialization, and deterministic direct-stub creation/replacement race rejection. |
| `bot/router_test.rb`, `bot/slash_handlers_test.rb`, `bot/supervisor_test.rb`, `bot/status_watcher_test.rb`, `bot/format_test.rb`, `bot/notification_builders_test.rb`, `bot/notification_dispatcher_test.rb`, `bot/pairing_store_test.rb`, `daemon/pairing_approval_queue_test.rb`, `commands/pairing_test.rb` | Telegram bot slash/menu/status/notification/pairing surface — router classification for supported slash commands including first-contact `/start`, first-contact pairing-code reply/throttle, `PairingStore` code lifecycle and expiry, approval-notice queue persistence/drain semantics, `hive pairing list`/`approve` config mutation and JSON, `SlashHandlers#start` welcome copy with concrete next steps, the `setMyCommands` quick-actions list (`/idea`, `/status`, `/queue`, `/answer`, `/approve`, `/autofix`, `/details`, `/done`, `/help`), `StatusWatcher` parsing of status rows including id/display name/`pr_url`, HTML escaping and PR-link formatting, `/status` and `/queue` PR-link rows, ready-for-review push enrichment, parse-mode forwarding, fingerprint stability, live `agent_running` stale-marker notification suppression, and recovery confirmation holds while a retry lock is active. |
| `openclaw_skills_test.rb` | OpenClaw skill metadata — only the umbrella `@ivankuznetsov/hive-cli` listing is published; setup stays visible before the CLI is installed and preserves package-manager confirmation; core provisioning uses `setup --no-init` before separate interactive enrollment; setup-agents and Honeycomb operations retain preview/approval boundaries; workflow publication requires a JSON dry-run plus exact name/version/release-digest confirmation and schema-v2 state/freshness handling; patrol dry-runs stay consent-gated; TUI token totals remain a human-only handoff; current workflow/patrol/bench/TUI/web paths stay present; patrol tiers name subscription/token limits and the higher architecture allowance; direct installed-runtime/service overrides stay absent; daemon auto-advance remains bound to prior enrollment consent; normal recovery uses fresh `hive act workflow.retry`; id-less markers point at `hive migrate`; low-level marker clearing stays explicitly exceptional; forbidden remote/release actions remain guarded; and README publishing avoids shortcut listings. |
| `commands/babysit_test.rb` | `Hive::Commands::Babysit` — lifecycle command routing, PID-file ownership handling, stale-runtime status/reload warnings, foreground restart, detached restart re-exec into canonical `start --detach` through the stable invoked wrapper, aborting restart and failing direct stop after a refused stop, clear detached re-exec failure reporting, initial/post-grace ownership-probe clean-exit handling, pre-KILL ownership refusal, bounded PID-lock timeout, guarded stop cleanup that preserves a replacement PID file, and skip-KILL PID-file preservation when ownership becomes unverified. |
| `babysitter/worktree_test.rb` | `Hive::Babysitter::Worktree` — exact PR-head replacement, project-relative state paths, undeletable cleanup residue moved into same-filesystem project quarantine, immediate expired-metadata pruning, and explicit failures when quarantine or prune cannot complete. |
| `test/unit/web/{web_command,app_bundle,environment,service_status}_test.rb`, `test/integration/web_packaged_bootstrap_test.rb`, `web/test/integration/{production_host_authorization,local_loopback_auth,sessions_flow}_test.rb` | Hive web app-dir resolution (canonical input plus warned alias), exact six-variable precedence/warnings, launchd lifecycle/readiness polling including unsupported/disabled fallbacks, readiness-failing install and versioned status-error contracts, release-workflow-and-tag-pinned bundle authentication, authenticated lockfile preservation across Bundler/assets, bounded verifier output/termination cleanup, real packaged-root Bundler/Rails bootstrap without a parent checkout, arbitrary production proxy hosts reaching the controller-level GitHub gate, raw-Host enforcement despite spoofed `X-Forwarded-Host`, bracketed IPv6 loopback access, owner-claim copy on proxied native login, configured Action Cable origin retention, mutation rejection before side effects, `db:prepare` typed failure guidance, final Rails `Kernel.exec` env/argv, and loopback/public-bind policy. |
| `web/test/models/{task,task_mutations,project,daemon}_test.rb`, `web/test/integration/{ideas,tasks,daemon_repairs}_test.rb` | Rails resource ownership — canonical stage-run verb mapping, fresh-row action/stage comparison, unknown-action and queue-grammar refusal before writes, canonical recovery receipt routing and disabled lifecycle UI, Reject's prior-gate derivation, custom-workflow Approve/Drop, brainstorm answer/intervention writes, idea capture through `Project`, path-redacted typed handling of task-capture I/O failures without partial mutation, and global daemon repair. |
| `web/test/models/agent_login_test.rb`, `web/test/integration/agents_test.rb`, `web/test/system/agents_login_flow_test.rb` | Rails agent-login resource ownership — immutable PTY-session snapshots, session/agent URL binding, dedicated create/show/completion routes, login-status rendering without account/project/skill inventory, Turbo frame responses without a recursive source, binary-output safety, paste-back/operator-ward polling policy, and real-browser polling that stops when the CLI session completes. |
| `test/unit/web/{status_feed,task_target_resolver}_test.rb`, `web/test/channels/status_channel_test.rb`, `web/test/models/{project,board,status_broadcaster}_test.rb`, `web/test/integration/{status,tasks}_test.rb`, `web/test/system/{kanban_board,pipeline_flow}_test.rb` | Hive web status/archive views and broadcasting — descriptor-ordered board bands, ordinary producer filtering and linked hidden summaries, separate lossless archive snapshots that do not replace the ordinary feed baseline, project-scoped archive navigation, expired-task detail lookup through explicit archive source and exact project/stage resolution, immutable archive logs without repeated polling, hidden-count-only semantic changes, unknown-stage/degraded-project visibility, Board/Grid preferences and filtering, one shared scan per poll tick, first-request priming, canonical semantic tokens, confirmed-channel catch-up, broadcast lifecycle/error recovery, mutation survival, and real-browser Board-to-Archive-to-task navigation. |
| `web/agents_auth_test.rb`, `web/agents_auth_login_test.rb`, `web/agents_routes_test.rb` | `Hive::Web::AgentsAuth` — Claude paste-back PTY login URL capture, Codex and Grok `--device-auth` poll-login behavior, `gh auth login --web` URL capture plus auto-Enter prompt handling, binary PTY output scrubbing, rejected-code errors, watchdog/process-group cleanup, concurrent-session cap, Pi token JSON rejection/persistence, and route wiring. |
| `web/config_test.rb`, `web/supervisor_test.rb`, `web/app_coverage_test.rb` | Hivebox config/supervisor packaging support — global web defaults/validation, child restart/backoff/reload/shutdown decisions, and route coverage attribution guardrails. |
| `modules/migration/{occurrence_journal,occurrence_recovery_index,patrol_evidence,effect_delivery_collaborators}_test.rb`, `daemon/{patrol_scheduler,refactor_patrol_scheduler}_test.rb`, `modules/adapters/{patrol,architecture_patrol}_test.rb`, `patrol/{effect_gateway,state_store_effect_intents,pr_opener,review_handoff,fixer}_test.rb` | Patrol selection, effect recovery, and publication — strict separate ordinary/architecture selection inputs projected into one immutable shared value; provisional-versus-terminal capture invariants; one canonical occurrence journal with no legacy StateStore effect maps, persisted sender liveness, or released-JobStore v2-import trigger/outcome; generation-fenced bounded active-record indexing, crash-window repair, and idle ticks without retained-history scans; fixed lock order; sequence high-water/floor compaction for scheduled, module-event, and architecture-job traffic; bounded fail-closed non-sequence retirement; restart-persistent normalized recovery diagnostics with 60/300/900 backoff; process-local keyed mutex plus stable `0600` never-unlinked flock serialization (including a forked contender); uncertainty persisted before invocation; crash recovery without blind redispatch; recursive effect-outcome secret redaction before journal/evidence persistence and byte-identical comparison/replay; gateway-owned local retry-safe absence; remote absence refusal; store-minted byte-stable terminal receipts; atomic typed publication outbox handoff; exact `(kind, id, digest)` acknowledgement when receipt and publication share an id; binding-before-ack crash replay; multiple pending-publication restart recovery; immutable predecessor-cycle binding reuse without a second PR effect; projection-crash restart recovery with exactly one push and one PR creation; missing, malformed, mismatched, or unreadable bound custody stopping before branch reset, agent rerun, new patch, or worktree cleanup; nonterminal-finalization and finalized-dispatch refusal; reconcile-only adoption of an exact existing hosted PR; exact repository/base/head and clean-worktree binding; complete terminal-receipt binding mismatch and pending projection retaining the exact worktree; verified remote publication; final remote base/head recheck before task publication; stale-base failed-handoff retry refusal; durable `reconciliation_pending` URL/patch receipts across lookup/auth failures; fail-closed exact-diff/title/body secret scanning; closed results, proof handoff, and exact-patch handoff retry. |
| `patrol/value_objects_test.rb`, `patrol/feature_batch_test.rb`, `patrol/candidate_selector_test.rb`, `patrol/reviewer_test.rb`, `patrol/fingerprint_test.rb`, `patrol/fixer_test.rb` | Ordinary patrol alpha policy and shared legacy state persistence — tolerant hash-only JSON reads, exact detached SHA-bound review rotation across default advances and first-batch errors, observable partial reviews, bounded/atomic source-matching evidence, immutable finding ids, legacy/current and same-run deduplication, retryable pending publication, model-label-light alpha ranking, strict fresh-base creation with no stale-local fallback, language-neutral declared regression paths, guardrails, nonblocking no-follow regular-file proof reads, normal regression-identified fail-before/pass-after proof, and non-suppressing fixer rejection. |
| `patrol/source_reader_test.rb`, `patrol/mapper_test.rb`, `patrol/architecture_mapper_test.rb`, `refactor_patrol/leverage_test.rb` | Architecture source inspection — polyglot/unknown-text/shebang and bounded docs mapping, source-only dependency leverage, canonical-root confinement at both the outer semantic mapper and architecture mapper, external package/Python/docs symlink and device rejection before feature construction, confined in-repository symlink support, regular-file checks, UTF-8 scrubbing, and the 256 KiB per-source read cap. |
| `managed_directory_test.rb`, `refactor_patrol/{job_store_files,job_query_index,job_store,job_store_fresh_start,job_store_writer_fence}_test.rb`, `daemon/{activation_lock,operational_snapshot,writer_quiescence}_test.rb`, `commands/{daemon,refactor_patrol_reset}_test.rb`, `integration/refactor_patrol_command_test.rb` | Patrol managed storage and explicit JobStore fresh start — descriptor-relative no-follow reads, locks, directory traversal, live v3 job/index/quarantine/lock I/O, atomic pre-lock enforcement of the 8,192-job capacity, v3-only runtime admission, no-write fresh status (including no registry move or update-temp cleanup), mandatory confirmation, exact registered-project binding, stable profile activation exclusion, generation-bound daemon shutdown and restarted-runtime readiness, exclusive Patrol effect-lock coverage, generation lock, independent PID/start-time writer fence, atomic exchange of opaque `v2/jobs` without enumeration, exact archive/marker/receipt binding, archive-without-marker runtime refusal, interrupted-reset resume, preservation of other v2 owners, empty-v3 admission, non-empty-v3 conflict refusal, and absence of constructor, package, timer, all-user, converter, or restore fallbacks. |
| `modules/migration/{bounded_file_inventory,evidence_store,shadow_comparator,shadow_decision_migration,patrols}_test.rb`, `integration/module_migration_test.rb` | Module shadow migration storage — linked managed-component, file, and lock refusal; filesystem-order-independent bounded inventories; source/archive/replacement-digest-bound v1-to-v2 shadow-decision checkpoints; strict native-v2 replacement validation; and completion only after a fresh inventory proves no live v1 evidence remains. This is the module ownership/evidence migration, not a JobStore v2 reader. |
| `refactor_patrol/*_test.rb` | Architecture patrol — strict run-wide reviewer output and wall-clock budgets, canonical leading JSON-fence extraction with optional trailing rationale while rejecting leading prose or multiple fences, root-confined and 256 KiB-bounded real-byte evidence verification (including sparse oversize sources and beyond-cap rejection), bounded mapper-selected context/test paths in reviewer prompts, immutable manifests/policy, exhaustive dispositions and partial feature resume, host-namespaced semantic families/canonical actions, exact-marker-first legacy issue-family reconciliation, immutable global proof archives plus disposable catalog rebuild (including handoff recovery after a synthetic task advances through coding's later stages), exact-registration ownership including disabled pending continuations, repository-global fix branches, complete coherent cross-feature fixes whose file count and diff size remain receipt evidence rather than an acceptance gate, semantic admission plus root/path confinement, `.hive-state` and protected-path rejection, secret scanning, dependency and public-contract guards, configured validation and inert-document-only built-in diff validation with preserved failure diagnostics, effective-policy revalidation of persisted patch receipts, actual-patch-path trunk overlap reanalysis, confined workspace-write fixing, verified Claude safe-mode discovery, generation-fenced job/action transitions, PR/issue intent and reconciliation including outcome-only remote recovery, OPEN-draft rejection, created-PR head/base OID verification, fenced mandatory review handoff, fully non-mutating dry-run parity, and mixed fix/issue/suppression completion. |
| `refactor_patrol/{effect_gateway,job_store,claim_maintenance_transitions}_test.rb`, `refactor_patrol/pr_opener_test.rb`, `refactor_patrol/action_runner_test.rb`, `refactor_patrol/repository_ownership_test.rb` | Generation-scoped transition and publication recovery — one job-bound occurrence across discovery/actions, v3-only JobStore authority with released v2 blocked behind an explicit opaque reset, exact recorded transition reconciliation after a settlement crash, durable diagnostic retry episodes, gateway-routed semantic mutations, one narrow claim-maintenance port, one blocking process/thread sender authority per semantic intent, local transition retry safety without a second recovery record, remote absence refusal, canonical receipt replay, action-local generation fences with no run-global effect correlation, append-only phase/descriptor validation, pre-create trunk drift rechecks, immutable supersession, exact proven-old-OID branch replacement, and publication phases as continuation ownership. The end-to-end regression uses a real git repository/worktree, bare Git remote, `JobStore`, `ActionRunner`, and `PrOpener`: a forked worker is hard-killed after the remote push but before its completion receipt, trunk advances, a new process owner reconciles the uncertain remote effect and receipts/supersedes the landed patch, then the fixer replaces only the proven old remote OID and creates/verifies/hands off exactly one PR. |
| `daemon/refactor_patrol_merge_progress_store_test.rb` | Incremental merge-catch-up sidecar — atomic owner-only round trips, base-checkpoint fingerprints, directory-fsynced unlink, restart-persistent bounded exponential backoff with deterministic jitter, identity-drift/corruption quarantine without rewriting evidence, strict timestamp/scalar/OID/cursor shape rejection including consumed-current-cursor resumes, in-memory dry-run parity, and invalid backoff configuration. |
| `daemon/refactor_patrol_merge_reconciler_test.rb`, `daemon/pr_merge_watcher_test.rb`, `daemon/refactor_patrol_scheduler_test.rb`, `daemon/patrol_arbiter_test.rb`, `daemon/child_supervisor_test.rb`, `daemon/dispatcher_test.rb`, `daemon/patrol_scheduler_test.rb` | Architecture-patrol daemon boundary — first-enable baseline and exact-host paginated/equal-time merge intake, one exact timestamp-range search qualifier, frozen merge-time upper bounds and result-count restart convergence, unchanged host-bound reconciler schema v2, page-cursor and intake-index resume across restart, task-bound exact-PR intake before repository catch-up, bounded shared catch-up budget, hanging-`gh` termination, slow-project isolation and fair time slicing, failure-time-based persisted retry `not_before`, next-UTC-day pacing for every daily architecture quota, non-burning intake deferral plus consecutive intake-failure accounting, crash-leftover recovery after checkpoint-before-sidecar-unlink, manifest/directory durability and idempotent predecessor replay, missing/duplicate/continuation-owner blocking, one tick-scoped candidate ownership snapshot plus fresh reservation rechecks, candidate/reservation config-failure durability, oldest-first/fair reservation, dead-owner fencing, schema-valid completion, large job-bound result-file transport, ordinary-patrol capacity isolation, exact active-occurrence recovery without history scans, bounded structured recovery diagnostics/backoff, verified full-tree graceful-shutdown termination before canonical claim completion, fenced unverifiable exits, nil-safe terminal recovery, and signal-derived ordinary-patrol failure backoff. |
| `stages/review/{ci_fix,triage,browser_test,fix_guardrail,suppression}_test.rb` | Review phase helpers — CI-fix retries, triage prompt/bias/custom-template/protected-file behavior, triage `review_triage` default fallback values (75 / 1800), browser-test protocol handling, fix-guardrail approval gates, and no-fix suppression fingerprint/strip/seed behavior. |
| `stages/review/run_reviewers_test.rb` | `Hive::Stages::Review.run_reviewers` — reviewer list selection for normal vs patrol-sourced tasks, per-reviewer failures, wall-clock deadlines, shared Claude tmux sessions, and GitHub comment mirroring. |
| `stages/review/phase_failure_helpers_test.rb` | `Hive::Stages::Review` phase-failure helpers — bounded `message=` summary truncation through `review_phase_error_summary`, capped exponential `triage_retry_backoff` delay through stubbed sleep, and the `run_triage_with_retries` wall-clock bail that returns `:wall_clock_exceeded` instead of launching another long triage spawn after the review budget is spent. |
| `commands/status_test.rb`, `archive_filter_test.rb`, `schema_files_test.rb`, `tui/schema_correspondence_test.rb` | Shared archive projection, machine contract, and scan boundary — workflow/action-aware archive membership, exact 72/168-hour strict boundaries, `never`, one refresh clock, all-project workflow/config generation capture before scanning, visible invalid-workflow error rows, ordinary project/operational hidden counts, lossless dedicated archive mode, unchanged task shape, additive schemas, required task-key correspondence, preserved `folder_mtime`, and stage-move race handling. |
| `tui/snapshot_test.rb`, `tui/state_source_test.rb`, `tui/views/{archive_pane,tasks_pane,hyperlink}_test.rb`, `tui/{bubble_model,app}_test.rb` | TUI projection consumption — producer-authoritative ordinary rows/counts, admission/quota/closure and PR rendering, no public-mtime retention calculation, separate lossless archive cache, descriptor/config/visible-and-hidden-pin fingerprints including same-size preserved-mtime changes, exact next-boundary expiry, malformed-workflow error visibility, exact singular/plural summary rendering, and archive-pane completeness. |
| `tui/clipboard_test.rb` | `Hive::Tui::Clipboard` — Wayland/X11/macOS clipboard-command selection, image-byte/file probes, image signature and size guards, test-only fixture clipboard sequencing, timeout sentinels, and `DefaultShim.capture3` stdout/stderr/timeout behavior. Generic subprocess checks use tiny executable fixture scripts rather than nested `RbConfig.ruby` children so coverage-injected `RUBYOPT` does not dominate unrelated timeout assertions. |
| `tui/app_test.rb`, `tui/state_source_test.rb`, `integration/tui_reactivity_perf_test.rb` | `Hive::Tui::App` / `StateSource` — charm-only backend selection, synchronous ordinary-plus-archive startup, snapshot-poller dedup/error dispatch, HUP/WINCH handling, content-fingerprint-gated refresh reuse, hidden-archive metadata invalidation and invalid-count fallback, next-retention-boundary and liveness-fallback reparsing, lossless complete/visible archived dependency-context caching, workflow/policy stat-fault sentinels, and per-project degradation retention. |

`babysitter/dry_run_env_test.rb` also pins the private-permission boundary for
both dry-run stubs: pre-existing `0644` and `0666` audit logs are left unchanged,
the blocked invocation is not appended, and stderr reports both the permission
refusal and normal skip marker.

Implementation ownership has focused unit coverage in `implementation_identity/{resolver,store,reconstructor}_test.rb`, `task_journal_test.rb`, `task_projection_test.rb`, `attempts/generation_test.rb`, `protected_files_test.rb`, agent/profile argv tests, the three implementation-owning stage launch tests, status/schema correspondence, and the TUI detail view. These tests pin the shared identity event builder across capture and legacy reconstruction, durable-before-spawn ordering, journal/projection tamper detection, fail-closed downstream generation reads, project/task/generation-bound legacy reconstruction, persisted-provider failure attribution, generation idempotency/conflicts, raw partial overrides, legacy precedence, exact Claude/Codex argv, provider-default pi/grok behavior, and honest unsupported effort.

`stringify_keys_test.rb` pins the shared recursive key transform's deep-copy
contract. Task-journal, condition evidence/policy/reconciler, attempt
record/store/generation, task-projection, and Screenote credential suites
exercise every migrated consumer. The follow-up attempt/projection slice runs
72 tests and 287 assertions.

## Integration suite (`test/integration/`)

| File | Covers |
|------|--------|
| `init_test.rb`, `llm_wiki_scheduler_test.rb` | `hive init` plus Linux LLM-wiki scheduling — stale `main_wiki_path` removal and rediscovery, primary-owned shared-runtime reconciliation that rejects stale linked-worktree copies, activation-relative timers with randomized starts, one repository timer across linked worktrees, the canonical cross-package global lock, executable shared-runner guard, a four-hour outer timeout covering three bounded agent/index batches, cgroup memory limits, headless user-bus environment recovery, marked and exact E2E debris cleanup, service-only partial cleanup, ambiguous-unit and disabled-schedule preservation, timer-only cleanup, non-fatal init activation, and durable stop/reload retry state. |
| `init_doctor_preflight_test.rb`, `commands/init_agent_skills_test.rb` | Optional post-init agent-skill diagnosis and consented repair — healthy/missing/config-error/inspector-error reporting, non-TTY and JSON non-mutation, interactive consent provenance, setup failure containment, and EPIPE handling. Generic direct Minitest construction defaults this optional preflight off so disposable-project fixtures do not repeat native/filesystem discovery; these focused tests opt in explicitly, and a clean Ruby subprocess proves the production default remains enabled when Minitest is absent. |
| `llm_wiki_post_commit_refresh_test.rb` | Transactional wiki refresh plus the scheduled compatibility wrapper — shared-runner preference, bounded-systemd commit dispatch with headless bus recovery and durable marker retention on signal failure, compiled-log-only no-op filtering, machine-wide fallback admission, project-local fallback, configured-provider-only production dispatch with a disposable test-copy seam, exact `--project <root> --drain` delegation, committed/template/generated copy parity, source-ref transaction chunking for large queues, reconstruction of interrupted queue writes, fast-forward publication to `llm-wiki/refresh`, freshly fetched remote-default reconciliation, crash-safe receipt revalidation after remote deletion, mixed retained/new and no-diff publication without duplicate agent runs, durable merge-conflict blocking, and dirty primary-checkout preservation. Each fixture uses a private `XDG_RUNTIME_DIR`, so a real operator refresh cannot consume its stub-agent work; explicit lock tests override that directory to retain machine-wide serialization coverage. |
| `bench_workflow_install_test.rb` / `workflows/bench_test.rb` | Fresh `hive init --workflow bench` installs and commits the packaged runtime under `.hive-state/bench-runtime`, creates a bench-pinned task without copying a project descriptor, and resolves the built-in stage/state contract. Legacy-upgrade coverage pins one-commit archive/runtime/config rebinding, same-process descriptor cache reset, tracked instruction archives, safe retry after a rejected commit, Ctrl-C cleanup at archive and both runtime-move boundaries, preservation after a post-commit interrupt, symlink-root and raced-target refusal, descriptor/child-name/parent-directory replacement rejection at classification, quarantine, and post-staging boundaries, dirty-config isolation, staged-index preflight, and previous-runtime retention when rollback deletion fails. The descriptor test pins Codex as the shell-control agent, campaign-sized one-hour/seven-day stage timeouts, provider-only pending generation as cooldown-aware `limits_reached` rather than manual `WAITING`, GPT-5.6 stage-profile selection to the combined `hive-bench-runner:sol` image, and the judge-stage invariant that a null round-two final is rejected while the incomplete cell remains eligible for retry. |
| `agent_skill_adapters_test.rb`, `setup_agents_test.rb` | Process-level fake Claude/Codex/Pi contracts — bundled Hive projection plus native package argv/JSON, fresh convergence and second-run no-op, unattended refusal with a per-invocation tripwire proving zero native discovery calls and byte-for-byte home stability, unavailable skips, independent offline failure, cache/resolution/provenance verification, filtered prerequisite retention/fail-closed blocking, timed-out descendant process-group cleanup, and conflict byte preservation. |
| `new_test.rb` | `hive new` — slug derivation, reserved rejection, `--workflow` task overrides, non-coding project-default pinning, coding override in non-coding projects, unknown-workflow fail-fast, marker handling for non-coding inert versus agent entries, captured commit, and per-project commit-lock serialization around the `hive/state` write. |
| `run_brainstorm_test.rb` | `hive run` of `2-brainstorm/`. |
| `run_plan_test.rb` | `hive run` of `3-plan/`. |
| `stages/execute_test.rb`, `run_execute_test.rb` | `Hive::Stages::Execute` and `hive run` of `4-execute/` — init pass, iteration pass, stale handling, worktree-missing recovery, execute-agent quota wall classification from `error_message` and raw `limit_text`, and the non-limit `implementer_failed` marker invariant. |
| `run_open_pr_test.rb` | `hive run` of `5-open-pr/` — push, draft PR creation, idempotent existing-PR path. |
| `run_review_test.rb`, `adhoc_review_test.rb` | `hive run` of `6-review/` and ad-hoc review — pre-flight states, reviewer/triage/fix/browser branching, no-fix suppression convergence and negative cases, manual wait and stale/error recovery, auto-commit/guardrail boundaries, provider-limit marker behavior for reviewers, CI-fix and triage/fix limit vs non-limit failures, classified residual triage/fix failure reasons, bounded transient triage retry recovery including wall-clock handoff to `REVIEW_STALE`, Claude/tmux fix Stop-hook fallback success for commit and whole-pass no-change evidence plus rejection for missing evidence/unresolved escalations, ad-hoc PR create/reuse/error paths, ad-hoc fix-disabled/fix-opt-in branching, and `message=` surfacing on terminal phase-agent (triage and fix) errors. |
| `run_finalize_test.rb` | `hive run` of `8-finalize/` — clean/pushed verification, already-merged PR short-circuit (`merged=true`, no `gh pr ready`, no `summary.md`), PR-ready wrap-up, and summary rendering. |
| `run_done_test.rb` | `hive run` of `9-done/` — cleanup instructions, complete marker. |
| `run_stage_action_test.rb` | Workflow verbs — archive idempotency plus internal merged-error archive recovery, including rejection when the current `ERROR reason=` does not match the recovery reason or when the PR still reports `OPEN`. |
| `status_test.rb` | `hive status` — concise operational default, explicit/full/compatibility modes, empty registry, multi-stage rendering, stale-lock decoration, and stage-move race behavior through the command surface. |
| `archive_visibility_retention_test.rb` | Fixed-clock cross-surface archive-retention acceptance — one real mixed project with legacy omission, explicit `3`, `7`, and `never`; exact-boundary rows; identity/count parity across status, operational/daemon, TUI, and web; lossless archive parity; unchanged task shapes; and a same-size preserved-mtime `7 -> 3` descriptor edit observed on the next web refresh. |
| `content_workflow_daemon_e2e_test.rb`, `content_workflow_stage_test.rb`, `content_workflow_e2e_test.rb` | Content workflow proof layers — the test-only fixture e2e advances `1-inbox -> 4-done`; the built-in `:content` tests pin per-stage slash-skill prompt rendering plus marker→runner-result mapping and drive real init/new/status/daemon/policy/approve/run to `6-done/article.md` with non-empty carried artifacts. |
| `honeycomb_workflow_lifecycle_test.rb` | A local immutable v2 git registry fixture drives canonical `catalog.json` plus `packages/NAME/VERSION/manifest.yml` through install, no-write dry-run, update, catalog-commit task pinning, list selected/retained dimensions, remove, and offline execution of the retained task. A second fixture-backed path runs preview→apply install/update/remove through the real Hive Web adapter and command constructors. Recommendation coverage pins package-effort selection, compatible-prior retention, interactive agent/model/effort editing, and identical preview/apply configuration receipts. Unit lifecycle/store coverage also pins strict browser-preview source/digest identities, first-install still-unselected checks, cleanup-error cause preservation, post-commit warning envelopes, and removal rechecks inside the mutation lock. |
| `user_workflow_e2e_test.rb` | Project-authored workflow acceptance — `hive workflow new` scaffolds a descriptor, `hive new --workflow` creates a pinned task, generic run/approve drives it from `1-inbox -> 2-work -> 3-done`, and a same-process coding capture still uses the default coding path. |
| `daemon_auto_retry_test.rb`, `daemon_stale_agent_healing_test.rb` | Status-to-recovery integration — real status rows feed the sole automatic scheduler, pinning stale `AGENT_WORKING` rewrites, closed coordinator events, `daemon.agent_marker_grace_sec` threading, ordinary `ERROR` / `REVIEW_ERROR` reasons sharing one cooldown, exact `terminal_outcome_blocked` / `terminal_outcome_invalid` errors remaining operator-owned, current-work safety deferral, global/project kill switches, and fresh failure generations retrying without an exhaustion counter. |
| `full_flow_test.rb` | End-to-end: idea → brainstorm → plan → execute → open-pr → review → finalize → done. |
| `cli_test.rb`, `cli_version_test.rb`, `cli_usage_error_json_test.rb`, `new_wrapper_argv_test.rb`, `bin_hive_refactor_patrol_usage_error_test.rb` | CLI/help/wrapper contract — init help derives the advertised `hive-init.vN` from `SCHEMA_VERSIONS`; top-level `--version`; command-local help after option-bearing invocations; leading JSON booleans and malformed assignment rejection; invalid-byte argv rejection; `hive new` task-text protection and option lifting; representative pre-dispatch JSON errors; and mode-aware refactor-patrol usage errors that validate as v1 for legacy argv and v2 for `--pr`, `--job-manifest`, or enabled `--actions`. |
| `patrol_command_test.rb`, `unit/patrol/{finding_registry,fixer,reviewer,validator}_test.rb`, `unit/patrol/token_budget_test.rb`, `unit/usage_db_test.rb` | `hive patrol` — JSON envelope, dry-run behavior, language-neutral mapping, exact-remote SHA pinning, durable active/resolved/rejected/superseded finding lifecycle, indexed all-history semantic dedup before persistence, dry-run-to-shipping and transient-failure retry reuse, newer-target resolved/rejected recurrence, single-read/single-timestamp lifecycle transitions, shared configured validation-key admission, clean-baseline preflight, stale-target rejection/transition, globally ranked selection, immutable audit records, retry/backoff outcomes, schema validation, shared daily tokens, separate ordinary/architecture launch accounting, architecture multipliers/backstops, and patrol attribution. |
| `refactor_patrol_command_test.rb`, `refactor_patrol/job_query_test.rb`, `refactor_patrol/job_query_index_test.rb`, `refactor_patrol/job_store_test.rb` | `hive refactor-patrol` — v1 compatibility plus PR-scoped/manual v2 manifest consumption, daemon-attached `--job-manifest` discovery-token recovery with incremental transition-gateway checkpoints, freshly fetched analysis-SHA pinning, detached exact analysis worktrees shared by mapper/reviewer/leverage, dirty or branch-switched registered-checkout isolation, contaminated-analysis rejection and cleanup, terminal replay ledgers with fresh-head repinning, partial feature resume on the original SHA after default-branch advancement, invocation-unique dry-run analysis keys, exhaustive zero/error envelopes, action projection, recursive suppression, exact-registration/duplicate-owner blocking before manual metadata resolution, bounded read-only job inspection even while discovery is disabled, immutable sequence/high-water cursor membership across same-time inserts and clock rollback, selected-job-only parsing, honest namespaced and legacy-flat publication truncation metadata, claim-generation-ordered current blockers, pre-index backfill, both membership/job crash windows, rebuild/write fencing, failed-rebuild generation retention, explicit index rebuild/stale-cursor rejection, selector-less jobs-v1 usage errors, and dry-run proof that current consent/ownership is evaluated while durable state, refs, branches, and external collaborators remain unchanged and any temporary analysis worktree is removed. |
| `wiki_command_test.rb` | `hive wiki` — compile-log writes the generated aggregate, `--check` distinguishes stale vs up-to-date output, invalid subcommands/missing wiki dirs raise usage errors, CLI dispatch reaches the command, and help lists the wiki surface. |
| `tui_smoke_test.rb`, `tui_smoke_charm_test.rb` | PTY-driven `bin/hive tui` smokes — boot, first useful paint with a seeded project, clean `q` exit, horizontal and vertical resize handling, and the startup regression gate (a generous 5s bound that catches a revert to the starved-poll loading grid without flaking; the 10s read_until is the hard gate). |
| `skip_worktree_test.rb` | Verifies hive-state commits on master don't leak into feature worktrees. |
| `bot/pairing_flow_test.rb` | Telegram pairing flow acceptance — empty-allowlist bootstrap with pairing enabled, unauthorized `/start` reply/throttle, owner approval writing global config and approval notice, reaper-delivered approved DM, reload authorization, and unknown/expired code rejection without allowlist mutation. |

Pre-dispatch JSON integration coverage also exercises variant-aware status,
web, pairing, bot, and digest error envelopes, including option-value collisions,
invalid encodings, and `--` terminators that keep later flag-looking positionals
from changing the selected schema. Focused command tests also pin the shared
envelope scaffold's legacy serialization-failure policies, the closed markers
error key set, text-mode durable failure exits, and recursive copy isolation.

`test/integration/implementation_identity_routing_test.rb` drives a real temporary attempt store, task journal, projection, generation change, and status preview without external model calls. It covers Codex routing/status correspondence, restart/config-drift stability, a fenced new owner, and unpinned pi/grok provider defaults. `run_execute_test.rb`, `run_open_pr_test.rb`, and `run_review_test.rb` retain the stage-level fake-launcher coverage.

`test/integration/mixed_agent_model_routing_test.rb` invokes checked-in fake
Codex and Claude binaries for the mixed-provider acceptance configuration,
asserting Codex global ordering and cross-provider non-leakage.
`test/integration/model_routing_surface_test.rb` enumerates the authoritative
registry through the profile/Agent argv seam and pins recognized-stage
fallback plus byte-stable unscoped legacy argv.

## E2E suite (`test/e2e/`)

The e2e layer is documented in [[e2e]]. It remains separate from the default
`rake test` task and can be run directly with:

```bash
bundle exec rake e2e:lib_test
bin/hive-e2e list
bin/hive-e2e run
bin/hive-e2e run --filter incident-regression --json
bin/hive-e2e coverage --match "provider retry" --json
bin/hive-e2e run --coverage workflow.full_pipeline
bin/hive-e2e run --profile release
```

The current scenarios copy `test/e2e/sample-project/` into a per-run sandbox, set `HIVE_HOME` to a run-local directory, and call the real `bin/hive` as a subprocess. `SandboxEnv` routes every built-in provider binary (Claude, Codex, Pi, and Grok) to `test/fixtures/fake-claude`, places the checked-in default-deny `gh` shim first on `PATH`, pins the direct `HIVE_GH_BIN` seam, and exposes only Bundler's resolved gem require paths through a protected `RUBYLIB` for every CLI, background, tmux, and replay process. Harness-owned home, dependency, agent, Hive, and GitHub paths cannot be replaced by scenario overrides. No scenario can fall through to a host `gh` or make a real GitHub request. Scenarios that exercise `4-execute` with the default Codex profile must ask the fixture to create a real worktree commit, or execute will correctly stop at `EXECUTE_WAITING reason=no_worktree_changes`. TUI scenarios use private tmux sockets (`hive-e2e-<run-id>`) so they never touch the operator's daily tmux server; teardown captures the final pane, terminates unfinished detached workflow process groups from the run-scoped PID lifecycle log, and then stops tmux before GitHub verification and filesystem evidence capture.

The semantic layer joins `test/e2e/coverage.yml` to each scenario's
`coverage.primary` / `coverage.supporting` metadata. Catalog, parser, runner,
and binary tests pin all-scenario classification, closed maturity/profile
vocabulary, root-confined references, duplicate/unknown mapping rejection,
lexical discovery, JSON/prose parity, required release-gap preflight, unique
primary execution, and the separate versioned `selection.json` companion.
Discovery conforms to `schemas/hive-e2e-coverage.v1.json`; semantic selection
conforms to `schemas/hive-e2e-selection.v1.json` beside the ordinary
`report.json`. Existing list/report v1 payloads and ordinary pattern/tag
execution stay unchanged.

Incident scenarios add stable incident and sibling metadata. Sibling-gated YAML
remains visible in `report.json#scenario_metadata` with `pending: true`, while
its steps and ordinary result row remain absent. CI runs
`bundle exec rake e2e:lib_test` and `bundle exec rake e2e` in a dedicated
pull-request job, uploads the configured `HIVE_E2E_RUNS_DIR` on success or
failure, and feeds the functional job result into the protected
`rake test (Ruby 3.4)` aggregate. That job treats missing enabled results,
duplicate metadata/results, and invalid durations as functional failures. A
separate `continue-on-error` job downloads the retained report and runs only
the timing mode of `test/e2e/check_incident_budget.rb`, flagging enabled
incidents at or above ten seconds (including sandbox bootstrap) or a group
total at or above thirty seconds without blocking the merge. The #9771
dependency-gate and repository-routing incidents are enabled; four
sibling-gated fixtures remain pending. The incident index and activation rules
live in `test/e2e/scenarios/README.md`.

`durable_attempt_1849_replay.yml` is the ownership acceptance replay. It starts
a foreground develop attachment, makes three provider commits, kills the
temporary caller group, asserts the execute lease remains running without a
daemon, releases the provider, and validates exactly one successful terminal
receipt. Focused attempt unit suites cover claim/expiry races, PID reuse,
framed logs, restart adoption, legacy backfill, dirty capture, and unbounded
successor healing paced by the shared cooldown.

`test/e2e/lib/hive_e2e_binary_test.rb` pins the harness binary contract:
scenario inventory JSON, cleanup JSON, the single-document stdout invariant for
successful `list --json` / `clean --json` calls, unknown-command JSON errors,
missing argument errors, top-level version output, command-local help after
command options (`run --filter tui --help`), leading JSON option normalization
for commands and top-level help/version flags, leading `--json --help run` /
`--json -h run` preserving human command help,
malformed JSON assignment rejection, last-JSON-boolean-wins usage-error mode,
replay path safety, missing, non-executable, symlinked runs-root, and symlinked
replay artifact validation, cleanup retention validation, and the single-dispatch invariant for
successful JSON commands.
The cleanup cases also pin the namespaced
`HIVE_E2E_RUNS_RETAIN_DAYS` / `HIVE_E2E_RUNS_RETAIN_FAILED_DAYS`
defaults and prove the old generic environment names no longer affect deletion.

The install-smoke workflow's `verify-release.sh (end-to-end behavior)` job
runs `packaging/verify-release.sh --version=v0.1.0` against the published
release after the pinned-release existence gate. The script itself requires
`jq` for envelope assertions; CI first uses runner-provided `jq` when present
and only falls back to apt provisioning when missing. If that fallback's
`apt-get update` is blocked by transient `packages.microsoft.com` repository
errors, the workflow disables those Microsoft source files and retries so an
unrelated third-party apt outage does not hide the verifier's actual behavior.
`test/unit/packaging/verify_release_test.rb` pins the safety boundary that
inert per-prefix `systemctl`/`launchctl` stubs enter `PATH` before any installed
Hive command can contact the host's live user service manager. It also pins the
published-release path through `packaging/verify-managed-web-setup.sh`: after
cosign identity and checksum validation, the installed binary must run managed
`hive setup --no-init --yes --json` from the authenticated archive. The release
verifier supplies sandbox-local Ruby/Bundler launchers so the exact candidate
gem wrapper can keep its private `GEM_HOME`/`GEM_PATH` without hiding Bundler
from managed web dependency installation or asset compilation. The release
contract tests require the pre-tag candidate workflow to build and exercise
that archive once, then require the tag workflow to select, download, rehash,
and publish the same manifest-bound bytes without a fallback build. The
packaged-bootstrap integration test
uses a real `git archive HEAD:web`, checks its members against the tracked web
tree, and verifies setup preserves every tracked file's bytes and executable
bit after extraction and asset preparation.

The macOS `launchd service install` CI job keeps its scope on real service
installation mechanics while preserving the web command's readiness contract.
It runs `hive web install --no-bootstrap --json`, requires the versioned
envelope to report a written macOS plist plus an available manager and an
installed/enabled service, and separately verifies the plist and live
`launchctl` registration. Because that job intentionally has no web bundle, it
accepts a nonzero command only when the same envelope reports `inactive` or
`active_not_ready`; a genuinely ready service must still exit zero.

The browser layer lives in the Rails app: `web/test/integration/*` (device-flow auth via the http DI seam, ownerless first-login claim and later non-owner refusal, Board/Grid route and preference rendering, linked archive-retention summaries, lossless project-scoped Archive rendering and expired-task lookup, plain `/health` versus daemon-backed `/health?deep=1`, ideas with bounded uploads, Puma pre-Rack body rejection, task Q&A/actions including Advanced Drop, stale-stage 422, red-task Retry recovery queueing, task artifact ordering/markdown rendering/log layout, bounded oversized task diff rendering, media route streaming/refusal plus captured/skipped/failed Demo gallery rendering, repos questionnaire, Repos SSH-origin normalization, non-directory clone-target refusal, Agents-page binary PTY rendering plus operator-ward login polling, favicon/icon serving, Telegram setup/pairing, and workflow lifecycle preview/receipt/consent flows) and `web/test/system/*` (Capybara + Playwright: Board/Grid switching and saved preference, kanban cards and mobile containment, real Board-to-Archive-to-expired-task navigation, login gate, composer image attach both paths, eight-image/10 MB client bounds, hard-capped batch inspection, batched multipart transport, constant-memory non-decoding attachment chips, staged-File cleanup across true versus Turbo-permanent disconnects, successful response cleanup before permanent-node rendering, failed-submit retention, Turbo Stream live update, status-grid scroll and composer draft preservation across a live broadcast, Q&A round replacement plus typed-answer survival across morph refreshes, both approve outcomes, non-overlapping busy-frame polling, log-tail follow/pause/resume, node-preserving log-frame morph reloads, artifact open-state preservation across broadcast-triggered morphs with live content refresh, real workflow scaffolding, exact-permission managed install review, visible Demo media, and failed-capture banners). Focused model coverage also drives Board workflow grouping, Repository clone, and Task diff subprocesses through nonzero and timed-out outcomes, pinning unknown-stage visibility, negative-PID process-group termination, reaping, operator errors, partial-target removal, and tempfile cleanup. Integration assertions keep Status, Workflows, and Telegram navigation active when the response is rendered by a namespaced resource controller. CI runs these tests in the `web` job, installs the root bundle into `vendor/root-bundle`, passes that path as `GOLDEN_E2E_BUNDLE_PATH`, and explicitly runs `web/test/e2e/golden_path_e2e.rb`. The golden-path E2E pins `BUNDLE_GEMFILE`, points `BUNDLE_PATH` at the supplied root bundle, deletes inherited web-bundle deployment/config keys, and preflights the daemon spawn environment with `bundle exec ruby -Ilib bin/hive --version` before starting the foreground daemon, so a broken Bundler/Ruby env fails with the real stderr/stdout instead of a later browser timeout.
`web/test/test_helper.rb#create_task!` wraps real `Hive::Commands::New`
task creation. Generated task slugs use a 16-bit random suffix, so the helper
retries rare `SlugCollisionError` cases and identifies the created folder by
comparing inbox children before/after the command instead of relying on mtime
ordering. Playwright examples share a process but not project state:
`ApplicationSystemTestCase` stops the subscriber-owned feed, clears only the
throwaway sandbox's canonical `repos/` tree, clears its registry through the
locked atomic config updater, and resets workflow descriptor caches before each
example. This keeps later refresh assertions
independent of test order and prevents a synthetic fleet accumulated by prior
examples from dominating browser timing. Tests that mutate the filesystem and
expect a Cable refresh first wait for the browser's confirmed subscription.
Browser tests never retain a `.task-row` Capybara element across daemon-driven
Turbo morphs, because reconciliation can detach the row while
Playwright is preparing a click. The system test visits the route from the task
folder it just created; the golden-path E2E resolves the slug from one
current-DOM query and visits that stable route directly. The project-rail test
uses the same discipline for the broadcaster-replaced rail and composer:
button lookup/click and ordered-value reads each happen in one current-DOM
JavaScript turn, so Turbo cannot detach a saved node between lookup and action.
Status-stream browser coverage also pins cancelled-confirmation refresh
admission, changing-token one-request reconciliation, and pre-confirmation DOM
teardown through the real Action Cable connection command path. It additionally
pins teardown during a current-transport reconnect, bounded cleanup when no
confirmation callback ever arrives, retry after a real server-side startup
rejection, and reconnect after deferred adapter registration fails. Unit barriers
bound every wait and assert the exact shared scan count and first-poller lease
rollback rather than relying on scheduler timing.
Before submitting the
brainstorm answer, it waits for the daemon to classify the
`needs_input` row and for the current `brainstorm.md` mtime second to pass, so
the answer write is strictly newer than the daemon's edit-resume baseline even
on coarse CI filesystems. The production path also depends on
`hive status --json` preserving subsecond task mtimes; otherwise a newer answer
written in the same second as the baseline can be reported as older or equal.

The packaged hivebox image smoke lives at `packaging/docker/smoke.sh`: it
boots a fresh container on a random host port, polls Rails `/health`, requires
daemon-backed `/health?deep=1` to stay healthy across the supervisor's
ten-second fast-failure window, asserts the ownerless `/login` page is
claimable, verifies unauthenticated `/` is owner-gated with a 302, and probes
deep health once more. The
image's runtime Docker `HEALTHCHECK` uses the same deep endpoint, so a missing
runtime gem, crashlooping daemon, or stale/missing daemon pidfile fails the
publish smoke even when Rails is still serving.
`test/unit/packaging/verify_release_test.rb` executes the smoke against stubbed
Docker/curl commands to prove one transient deep-health success cannot pass,
and pins the libffi headers required to compile the explicit Fiddle dependency
before Hive is installed in the slim Ruby image.
`.github/workflows/release.yml` pushes amd64 and native arm64 content without
public tags, runs the smoke against each exact registry digest, and promotes
only those two proven digests into the versioned and `latest` multi-arch tags.
The native arm64 job runs on `ubuntu-24.04-arm`; a failed architecture smoke
therefore leaves no public release tag to pull. Commit `54fd3455` established
the native runner after proving hosted Apple Silicon runners cannot provide
the nested virtualization Colima needs. Current `.github/workflows/ci.yml` does not
build or smoke a local hivebox Docker image on push/PR; it covers the Rails web
tests, the golden-path browser E2E, and the Windows installer-script harness.
The Windows CI surface is
`packaging/docker/test-install-box.ps1`: real PowerShell
syntax, `$LASTEXITCODE` behavior, and failure-output capture with a stubbed
Docker CLI for missing-Docker diagnostics, happy-path pull/run argv including
the default `127.0.0.1:4567:4567` bind, and existing-container refusal. The
harness invokes `install-box.ps1` inside child `pwsh` and redirects all streams
to a temp file that the parent reads after exit, because `exit` inside the
installer tears down piped capture before `Out-String` flushes on failure paths.
Installer failures write their user-facing copy with `Write-Host` rather than
`Write-Error` so the file-backed capture sees the message before the child
process exits.
These tests do not exercise real GitHub, Claude, Codex, or Telegram provider
credentials inside a running box.

The live Telegram bot E2E wrapper lives at `test/e2e/tg/run_idea_e2e.sh` and is also opt-in because it uses a real Bot API test token plus a Telethon user session. In default text mode it drives `/idea <nonce>` through the project picker. With `TG_IDEA_MODE=voice`, the wrapper requires the voice fixture and `HIVE_WHISPER_API_KEY`, starts the bot from the current checkout, drives a new voice idea through transcript confirmation/project selection, seeds a temporary `2-brainstorm/<slug>/brainstorm.md` in the scratch project, then sends `/answer <slug>` and answers Q1 with the same voice note. Cleanup resets the scratch state repo to the captured baseline and removes temporary inbox/brainstorm folders.

`test/e2e/lib/hive_e2e_binary_test.rb` is the focused contract suite for the executable itself. It pins `list --json`, `clean --json`, leading JSON option normalization including `--json=true`, duplicate JSON boolean handling where a final false flag chooses prose, malformed `--json=1` / `--json=yes` rejection, error-envelope shapes, help/version handling, leading `--json --help run` / `--json -h run` command-help rendering, replay path validation, missing/non-executable/symlinked runs-root and replay artifact errors (`missing_repro` / `unusable_repro`, exit `78`), and the usage exit-code contract: unknown commands and missing required arguments exit `64` in both human and `--json` modes. Human usage errors are expected to print a `hive-e2e:`-prefixed prose message on stderr.

## Live agent skill resolution smoke

`test/smoke/live_agent_skill_resolution_smoke_test.rb` is excluded from the
offline suite. It requires `HIVE_LIVE_AGENT_SKILLS=1`, a real authenticated
agent binary, and optionally `HIVE_LIVE_AGENT=claude|codex|pi`. Each job copies
only that provider's credential artifact into a disposable config home,
installs `ce-brainstorm` through `hive setup-agents --yes`, reruns the shared
doctor inspector, invokes the provider headlessly, and requires structured
native skill/plugin activation metadata rather than model prose. Production
manifest mappings are separately pinned offline.

This older three-provider smoke proves package installation/resolution only. It
does not prove the canonical Hive operating policy or satisfy the release
gate.

## Exact-artifact Hive operating-skill verification

The release-readiness owner is the trusted aggregate produced before a tag by
`release-candidate.yml`. It requires no provider keys: one exact-SHA candidate
contains the gem, committed source, four-platform skill archive, and managed
web archive; blocking package/web/native/upgrade gates verify those bytes and
the aggregate binds them to its evidence digest. A later explicit tag makes
`release.yml` revalidate that Check/evidence/run/artifact chain and consume the
same gem/skill/web bytes without rebuilding them.
Focused managed-web unit coverage additionally distinguishes ordinary healthy
same-version bootstrap (no work) from explicit `hive web install --force`
(staged dependency/asset reprovision plus rollback-safe activation), pins that
an activation failure restores the previous bundle, and proves the command
forwards force intent into `Hive::Web::AppBundle.ensure!`. It also proves a
refresh restarts an unchanged running service exactly once, does not duplicate
the restart already performed by a unit upgrade, and advertises the mutation
scope in `hive help web`.

`test/smoke/live_hive_operating_skill_smoke_test.rb` is the four-platform
OpenClaw/Claude/Codex/Pi harness. It is disabled by default and skips with a
diagnostic unless `HIVE_LIVE_AGENT_SKILLS=1`, an exact candidate artifact
bundle, the selected native CLI, and its provider credential are present. With
`HIVE_RELEASE_GATE=1`, missing prerequisites are failures rather than skips.
This is an optional authenticated diagnostic and is not a release prerequisite.

The protected `live-agent-skills.yml` workflow can additionally:

1. validate a full SHA reachable from protected `main` and the workflow
   revision loaded from `refs/heads/main`;
2. build one gem, one source archive, and one deterministic four-platform skill
   archive from that candidate;
3. install each native CLI and exact candidate gem in a matrix job, exposing
   the private gem through a self-contained `GEM_HOME`/`GEM_PATH` wrapper that
   clears inherited Ruby/Bundler startup injection while keeping its protected
   environment credential scoped only to the proof step;
4. place the exact platform projection into a disposable 0700 home and require
   structured native discovery/activation: OpenClaw resolves the exact
   `skills info` path, Codex's model-visible prompt inventory names the exact
   `$hive` projection, Pi's RPC inventory exposes the exact `/skill:hive`
   command, and Claude's typed `system/init` event lists `hive` in both its
   loaded skills and `/hive` slash-command inventory (a generic file read is
   insufficient);
5. allow the agent to run only audited `hive status --operational --json` and
   one bounded `hive watch ... --json-lines`; the argv-auditing shim delegates
   both commands to the exact installed candidate binary against a real
   disposable Hive task, then rotates its marker so candidate code must produce
   the initial/transition/final records rather than receiving synthetic JSON;
6. scan unredacted stdout/stderr and retained evidence for credentials, retain
   no model prose, prove private-home cleanup, and upload run-attempt-specific
   seven-day structural evidence;
7. validate all four evidence rows, assemble the candidate/provenance-bound
   private proof, and create a `live-agent-skills` Check Run on the exact SHA.

The repository-owned selector and attestation verifier remain covered by
executable fixtures for optional diagnostic runs. They validate workflow/run
identity, all four matrix jobs, one unexpired artifact, and its downloaded
archive digest, but `release.yml` does not query or require that Check Run.

`bundle exec rake smoke` also contains older live Claude workflows and may
incur provider cost. Normal `rake test` remains local and network-free.
`bundle exec rake coverage` uses the same network-free machinery but is
normally owned by hosted CI. Forked custody processes that terminate through
`exit!` explicitly flush sparse, hit-only coverage results before exiting;
the parent retains the complete source inventory used by the 100% line gate.

## Live Claude tmux dogfood

The global `claude.mode: tmux` path was manually dogfooded on 2026-05-25 in a disposable git project with a temporary `HIVE_HOME` and private `HIVE_TMUX_SOCKET`. The run used Claude Code 2.1.133 and tmux 3.6a.

Run shape:

- `hive init .` in non-TTY mode rendered `claude.mode: tmux`.
- `hive doctor --json` reported `claude/tmux` present (`tmux 3.6`) and all configured stage/reviewer skills present.
- `hive new project "Dogfood..."`, then `hive brainstorm <slug> --project project --json`, launched real Claude through tmux and returned `marker_after: waiting`.
- After filling `A1`, `hive brainstorm <slug> --from 2-brainstorm --project project --json` returned `marker_after: complete`.
- `events.jsonl` recorded `round_waiting` then `round_complete`; `hive status --json` reported `marker: complete`, `action: ready_to_plan`, and `claude_pid: null`; both private tmux sockets were gone after cleanup.

That smoke predates the 2026-06-12 `claude.model` / `claude.effort`
argv pins, so it proves tmux-mode launch/cleanup but not the new
`--model default` or `--effort <level>` behavior against a live Claude
Code binary.

## Eval suite (`test/eval/`)

The Telegram bot eval harness is opt-in and separate from the default suite:

```bash
bundle exec rake test:eval
bin/hive-eval --scenario s1_status --no-judge --report /tmp/hive-eval.json
```

`test/eval/support/` provides an in-process fake Telegram transport, a programmable status watcher, child-supervisor and dispatch-request captures, a scenario DSL, typed-reason contract assertions, scripted/Codex personas, and a Codex prose judge. Scenario files live under `test/eval/scenarios/` and drive the real `Hive::Bot::Supervisor#process_update` / `#status_tick` entrypoints without changing production bot behavior. Queue-routable bot verbs are captured through the fake `DispatchRequestWriter`, and `Harness#dispatched_commands` lets scenarios assert command intent across both queued and child-spawned dispatch paths.

`bin/hive-eval` is a checkout-local OptionParser wrapper over `rake test:eval`. It accepts only `--scenario NAME`, `--report PATH`, and `--no-judge`; relative report and scenario-root paths resolve against the repository root, independent of the caller's cwd. Invalid options, missing option values, stray positional arguments, missing scenarios, and unsafe scenario names exit `64` before eval runs. Parser-error cleanup may clear only the default `tmp/hive-eval-report.json`; caller-provided report paths are preserved on usage and validation exits. After positional and scenario validation pass, the runner removes the selected report path immediately before invoking `rake test:eval` so valid runs cannot read stale JSON from a previous run. Unexpected positional-argument errors label the count as `argument` or `arguments`; `--scenario` resolves a basename under the scenario root after stripping an optional `_test` suffix. Slash and backslash path separators get a distinct usage error, and separator-free names still must match `[A-Za-z0-9_-]+` before being joined under `test/eval/scenarios/` or `HIVE_EVAL_SCENARIO_ROOT`. All-scenario runs clear inherited `TEST` and set `HIVE_EVAL_SCENARIOS_ONLY=1` so ambient test selection cannot execute support or unit files. The wrapper also owns `HIVE_EVAL_NO_JUDGE`: it passes `1` only when `--no-judge` is present and otherwise clears any inherited value so caller environment cannot silently disable judges. A missing/unspawnable Bundler command exits `127` with a direct diagnostic. Tests may point `HIVE_EVAL_SCENARIO_ROOT` at a temporary scenario directory for throwaway fixtures.

Successful eval runs write a `hive-eval-report` JSON document with per-scenario assertions/messages/log events, and scenario failures make the wrapper exit non-zero. `ReportStore.write!` neutralizes any symlink or hard link at the report path before writing (unlink, then open with `O_CREAT|O_EXCL|O_NOFOLLOW`) so the report always lands on a fresh regular file and a `--report` path pointing at a link never clobbers the link's target. `--no-judge` is the explicit structural-only mode; otherwise Codex judge/persona calls are real subprocess calls. Scenario `s3_noise` is now a passing daemon-enabled noise regression: ready-to-action rows should not become proactive Telegram alerts when the daemon owns dispatch, and the scenario still asserts no duplicate messages plus the proactive allowlist (`agent_blocked_question`, `fatal_error`). Reporter failure-path coverage no longer relies on a production scenario staying red; `test/eval/support/reporter_test.rb` creates a tmpdir-scoped intentional-failure scenario through `HIVE_EVAL_SCENARIO_ROOT`.

Successful `bin/hive-eval` exits require a per-invocation private report whose
scenario entries match the reporter contract and all report `status: pass`.
Rake dry-run spellings in inherited `RAKEOPT` are rejected before execution,
then `RAKEOPT` is cleared for the child. Only the validated private report is
atomically published to the requested path, preventing concurrent runs from
validating each other's output. Group/world-writable report parents require the
sticky bit, and cleanup warnings cannot replace the intended result status.

## Lint

`bundle exec rubocop` is the lint command. Config in `.rubocop.yml`:

- `TargetRubyVersion: 3.4`
- `Style/StringLiterals: double_quotes`
- `Style/FrozenStringLiteralComment: disabled`
- `Layout/LineLength: max 120`
- `Metrics/MethodLength: max 30`, `Metrics/AbcSize: max 35`, `Metrics/ClassLength: max 200`

Excludes `vendor/**/*`, `tmp/**/*`, `test/fixtures/**/*` (the shell-script fixtures are not Ruby), and `templates/builtins/bench/runtime/**/*`. The benchmark runtime is a synchronized snapshot from hive-bench, where its Ruby files are linted with that repository's canonical RuboCop configuration; Hive must not restyle the packaged copy independently.

Per the user's CLAUDE.md rule: never pass non-Ruby files to rubocop.

## Static Analysis

CI has dedicated `rubocop`, `brakeman`, and `bundler-audit` jobs in
`.github/workflows/ci.yml`. The Brakeman job runs:

```bash
bundle exec brakeman --gemfile web/Gemfile --force --no-pager --quiet --format github --ignore-config config/brakeman.ignore
```

The root scan deliberately reaches both Hive's Ruby libraries and the nested
Rails web application, so it does not use `--path web`. The explicit nested
Gemfile lets Brakeman identify the real Rails version even when its root-app
heuristic stops inferring Rails because the repository contains a top-level
`script/` directory without the legacy `script/rails` launcher. Without
`--gemfile web/Gemfile`, Brakeman 8.0.5 falls back to the non-Erubi template
parser and fails on frozen ERB output instead of completing the security scan.

`config/brakeman.ignore` is the root ignore file for scanner false positives.
Each entry carries a rationale for the trust boundary Brakeman cannot see,
such as argv-form subprocess calls, integer coercion before shell use, or
registry-laundered filesystem paths. Release-candidate artifact construction
and baseline materialization use discrete-argv `Open3.capture3` calls; their
candidate OIDs are validated and their remaining refs and paths are internal
or loaded from the reviewed, digest-pinned catalog, so the associated command
injection findings are recorded as scoped false positives. The old
task-log-path ignore from commit
`83f0a800` is no longer needed: `Tasks::LogsController#show` loads a `Task`
only after registered-project resolution, and moving the bounded path read to
`Task#latest_log` lets Brakeman see no controller file sink. `Task#diff` now
owns the similarly bounded process/tempfile read used by the diff resource,
while focused model coverage pins title/original-idea, canonical
`TaskAction::READY_COMMANDS` verb projection, workflow-specific dispatch, and
the failed/timed-out subprocess cleanup paths. Focused integration
coverage rejects unknown projects and valid-shaped unknown task slugs on the
log route. See [[commands/web]] for the task log-tail surface.

Brakeman still scans the packaged benchmark runtime even though RuboCop defers
its style ownership to hive-bench. Its profile probe, Codex judge, and sqlite
extractor findings are explicitly ignored because all three call
`Open3.capture3` with discrete argv elements; no interpolated value is passed
through a shell. The install-smoke ShellCheck job also scans the packaged shell
scripts, so shell fixes must be applied to both hive-bench and Hive's runtime
snapshot.

The hivebox task media route also carries a Brakeman file-access ignore. The
route constrains `:filename` to a single PNG/JPEG/GIF component, then
`Task#media_path` requires `File.basename` equality, repeats the extension
check, resolves the real task folder and media directory, refuses a
symlinked `media/` root, and streams only files whose realpath remains below
that media root. `web/test/integration/tasks_test.rb` covers inline streaming,
traversal/extension/missing-file refusal, and symlinked media-root refusal.

Commit `c4e2cab5` adds the current `hive bench submit` Brakeman ignore for
`gh pr create`: `Open3.capture3` is argv-form, and the resolved `9-done` slug
is interpolated only into PR title/body text. The paired source change splits
the extractor's `ruby -I` flag and harness path into separate argv elements.
See [[commands/bench-submit]] for the command surface.

## Hive web Golden-Path E2E

`web/test/e2e/golden_path_e2e.rb` (deliberately not `*_test.rb` — the
default suites skip it; run `cd web && bin/rails test
test/e2e/golden_path_e2e.rb`, ~35s): a real browser drives the full
mother-test path — claim-by-first-login through the REAL device-flow logic
against a stubbed GitHub HTTP seam, an idea composed in the UI, a REAL
`hive daemon` subprocess advancing brainstorm→plan→execute with the
stage-aware fake claude (`web/test/e2e/support/claude`, keyed on cwd
because a daemon launches every stage with the same binary), the Q&A
answered in the browser, ending at the network-free boundary "Ready to
open PR" with a real commit in a real worktree. Failure artifacts (daemon
event log, daemon stdout, daemon PID liveness, HIVE_HOME log inventory,
task files, agent logs) are printed or copied under `/tmp/golden-e2e-debug`.
The final browser wait targets that durable PR-gate result rather than the
transient `execute` badge: a fast daemon may complete execute between two
Turbo renders, while the real worktree commit proves the stage ran.
The first task-page navigation deliberately re-resolves the grid link through
brief row-lookup misses or Playwright "not attached to the DOM" click errors
because Turbo can replace the row while the daemon advances the task from
`1-inbox` to `2-brainstorm`.
The daemon is preflighted with the exact spawn env via `bin/hive --version`
before `Process.spawn`, so CI boot failures surface synchronously. In CI that
env uses `GOLDEN_E2E_BUNDLE_PATH` to force the daemon onto the root bundle
instead of the Rails app's `web/vendor` bundle. After the idea submit, the
test resolves the task slug from a single current-DOM query and visits the task
page directly, avoiding a saved `.task-row` element that Turbo may detach while
the daemon broadcasts grid replacements. Before submitting the brainstorm
answer, it waits for the daemon's `needs_input` classification and for the
current `brainstorm.md` mtime second to pass, avoiding equality with the
daemon's edit-resume baseline on coarse CI filesystems. The ordering gate
accepts either the legacy `child_exited` event or durable ownership's
`attempt_terminal` event before the classification, so both launch paths prove
the same answer window. `status_test.rb` pins
the matching production contract: JSON task `mtime` and `folder_mtime` keep
subsecond precision for the daemon's mtime-to-mtime comparison. The Telegram
leg lives in `test/e2e/tg` (real Bot API, secret-gated) and now asserts the
/start welcome ahead of the idea flow.

Open-PR and finalize pointer-entry tests exercise the shared
`Hive::Stages::Base.worktree_pointer_or_exit` policy. They pin status 1 and the
existing warnings for both a missing `worktree.yml` and a pointer whose
directory has disappeared.

## Web reliability and capture

Focused U5 coverage lives in
`test/unit/web/{status_feed,task_diff,task_target_resolver}_test.rb` and Rails
status/task/model tests. It pins single-flight/latest-good semantics, zero fleet
scans for task-local routes, bounded typed diff failures, and degraded mutation
gates. U6 coverage lives in
`test/unit/web/{source_bundle,browser_bundle,capture_runtime,task_capture}_test.rb`,
`test/unit/artifacts/capture_policy_test.rb`,
`test/unit/commands/web_test.rb`, artifacts-stage tests, and schema validation.
Those tests pin fail-closed classification when the owned worktree evidence is
missing or unreadable, refusal of non-empty unclaimed runtime roots, and
owner-receipt revalidation before cleanup, pinned npm/Chromium cache ownership,
publish-after-teardown task capture, and a production-Rails subprocess proving
the private capture server returns its isolated stylesheet through Propshaft
instead of recording an unstyled page.
The packaged bootstrap and real clean-worktree Playwright capture remain outer
proofs: the former archives committed `HEAD:web`, while the latter needs the
pinned browser binaries and retains task-local media plus its exact-SHA
manifest.

## Launch-path fixtures

`test/unit/launch_path_fixture_test.rb` pins the public Build and Content
walkthrough fixtures under `docs/fixtures/launch-paths/`. It requires both
paths to preserve their input and stage artifacts, marks every file as a
deterministic replay fixture, rejects provider-completion or measured-time
claims, and checks the published state words against the native web/status
source strings. The fixture suite is structural evidence only; clean live
provider replays and timing remain separate verification gates.

## Backlinks

- [[architecture]]
- [[modules/agent]]
- [[e2e]]
- [[gaps]]
