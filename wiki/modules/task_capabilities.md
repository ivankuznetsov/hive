---
title: Task capability contracts
type: module
source: lib/hive/task_capabilities/definition.rb, lib/hive/task_capabilities/catalog.rb, lib/hive/task_capabilities/policy.rb, lib/hive/task_capabilities/plan.rb, lib/hive/task_capabilities/store.rb, lib/hive/task_capabilities/resolver.rb, lib/hive/task_capabilities/approval.rb, lib/hive/task_capabilities/admission.rb, lib/hive/task_capabilities/actor_runner.rb, lib/hive/task_capabilities/result.rb, lib/hive/task_capabilities/result_store.rb, lib/hive/task_capabilities/verification.rb, lib/hive/task_capabilities/gate.rb, lib/hive/task_capabilities/revision.rb, lib/hive/commands/task_capabilities.rb, schemas/hive-task-capabilities.v1.json
created: 2026-11-03
updated: 2026-11-03
tags: [module, workflow, capabilities, policy]
---

Task capabilities attach guidance or independent verification to stages that
already exist. They are separate from `Workflow::Result.capabilities` (result
presentation facilities) and AgentProfile's runtime tool vocabulary. Coding
keeps its nine stages.

`task_capabilities.enabled` defaults to `true`. New coding captures atomically install
a resolved initial execution plan: Automatic QA selects behavior verification;
UI remains a recommendation unless pinned policy selects it; security needs an
explicit selection and approval. Existing tasks without adoption metadata and
other workflows retain their previous behavior.

Capability configuration belongs in the project's `.hive-state/config.yml`.
It is not inherited from the global registered-projects file.

## Definition and catalog

`Workflow#task_capabilities` holds frozen descriptor definitions. Authored YAML
uses a top-level `task_capabilities` array. Each definition has a stable `id`,
`kind: guidance|verification`, and nonempty `stages` list using existing stage
names. Optional fields are `skill` or `instruction`, `actor`, `permissions`,
`targets`, `budget_usd`, `timeout_sec`, `checks`, `depends_on`, `conflicts`,
`before`, and `after`. Instructions must reference readable files; packaged
instructions stay inside the package. Serialized instruction identity uses its
source-relative path and content digest, so moving an immutable package from
staging to its selected generation does not change capability bindings. Actors
pin `profile`, `provider`, and
`model`, with optional `effort` supported by that profile.

Checks have stable IDs, `kind: behavior|source_review|dependency_review`, a
nonempty behavior `claim`, optional `command` and `provider`, and optional
same-definition `depends_on` check IDs. Duplicate IDs, unknown stage/check
references, dependency cycles, impossible ordering, and conflicts with required
dependencies reject configuration. Selection validates dependencies and
conflicts before ordering attachments within each existing stage.
Coding verification attachments run within review; UI guidance attaches to
both plan and execute. Configuring those names cannot change their kinds or
move verification to another stage.

Selected guidance currently has consumers in coding's bespoke `plan` and
`execute` runners. Other stage names, and same-named descriptor stages that
dispatch a generic agent or council, produce a durable dispatch blocker rather
than silently dropping the attachment. Stage names alone do not establish a
compatible consumer.

The project `task_capabilities.catalog` is coding's custom-definition authoring
surface. `Catalog` supplies unconfigured examples for `qa`, `ui`, and `security`;
project definitions with those IDs supply their actual bindings. These examples
invent no installed skill, usable check, or approved provider. For authored
workflows, descriptor definitions are authoritative: a project catalog entry
with the same ID is an attributed error, never an override.
Project catalog configuration is scoped to built-in coding; managed workflows
declare their additions in their descriptors, whose definitions enter the
managed configuration snapshot.

A fourth verifier uses the same definition contract:

```yaml
task_capabilities:
  enabled: false
  catalog:
    - id: links
      kind: verification
      stages: [review]
      permissions: read-only
      checks:
        - id: local-links
          kind: behavior
          claim: Local documentation links resolve
          command: ruby script/check-links.rb
```

## Policy and approval envelope

`task_capabilities.policy.required` lists hard-required capability IDs.
`auto_select` contains UI rules with `capability: ui` and a nonempty `signals`
array. A signal has `type` and `value`: `task_label` matches an exact label,
`task_text` matches a case-insensitive literal, and `repository_path` and
`changed_path` match path globs. Matches retain the signal and matched value as
provenance. The vocabulary executes no scripts. There is no project QA waiver
or standing QA exception setting.

`task_capabilities.approvals` maps stable references to exact envelopes:
`capability`, `actor`, `permissions`, `targets`, `budget_usd`, and `timeout_sec`.
Targets are exact task-relative references, never arbitrary URLs or paths
outside task custody. Permissions use the runtime's explicit tools, deny,
directories, commands, domains, and credentials fields. Configuration validates
the exact profile through `RuntimePolicy` admission; currently only Claude's
legacy policy adapter can enforce this bounded-command envelope. A `scoped`
preset with `bash: true` is an unbounded shell and cannot serve as a bounded
approval. External scanning domains and automatic credential injection reject.
Only isolated local targets are admitted.

An actor's `provider` is its runtime's semantic provider (for example,
`anthropic` for Claude). `provider_account` names a configured account and
`launch_binding` pins its symbolic session binding. Approvals for configured
accounts require both fields; an inferred default account cannot reuse an
approval which omitted that account. Native legacy approvals explicitly
normalize the binding to `default`. Changing an approved account's adapter,
model availability or launch binding blocks its route.

## Guidance at plan and execute

The plan and execute prompts include ordered selected guidance from the accepted
execution plan, with its version and digest. They never re-resolve selections
from current configuration. Before each consuming launch, Hive verifies the
profile fingerprint and installed skill path, invocation and content digest.
Missing or changed skills block with a restore-or-revise action. Pinned
instruction attachments use the immutable content snapshot and verify its
digest, so deleting the authoring file does not rewrite task history.

A shared primary spawn can consume an attachment only when its profile,
semantic provider, concrete model and requested effort match the pinned actor.
The semantic provider comes from the runtime's existing execution-identity
contract. A provider-native default used in that comparison is pinned in the
launch arguments. The primary spawn must also have enforceable spending and
time limits within the attachment's envelope and no broader permission scope.
Unbounded stage budgets, unsupported native budget enforcement, narrower
task-target scopes and distinct actors require a bounded specialist invocation;
putting a restriction in the prompt does not establish enforcement.

Distinct actors and narrower envelopes run through `ActorRunner` within the
existing durable attempt. Direct runs without that parent receive a visible
`--durable` recovery. Each launch rechecks the current accepted binding,
profile fingerprint, skill identity, exact route and accepted approval where
required. The child retains its own provider, model, effort, account and
launch binding even when the outer attempt has explicit routing. A successful
process without matching observed provider/model identity cannot pass.

The specialist contributes at most 8,192 bytes to the existing plan or execute
prompt. The primary executor keeps its identity. The shared session reserves
each child cap from a supplied finite stage budget and deadline and clamps the
primary launch to what remains. Settled provider spending releases only the
unused reservation, once. Missing spending after a real launch consumes the
full cap; a proven prelaunch denial releases its reservation. This is the
caller's stage envelope, not a new monetary field on the durable attempt.
Every child still needs native budget enforcement when the parent is uncapped.

The parent retains task/fleet reservations, usage and cancellation. A separate
spawn ID correlates the child result and its single parent-bound usage session.
Live child account occupancy sits in the parent's diagnostics and participates
in the same SQL account-capacity check as outer admission. It creates no new
attempt or task lease and does not advance the parent's lifecycle lease version.
Parent signals reach all live children; process identity checks fence teardown,
and parent context cleanup waits for launchers to finish and children to be reaped.

The current specialist policy supports Claude with the required policy settings
(version 2.1.285 or newer), read-only file access, and one existing task-owned
target directory. An omitted target uses the task directory. A broad guidance
`yolo` envelope is narrowed to read-only specialist access. Unsupported scoped
presets, multiple targets, outside/symlink targets and unenforceable adapters
block visibly.

Bounded Bash uses a non-preset permissions map compiled by `RuntimePolicy`.
Its actual Claude hook validates the original command before returning an
`updatedInput` command wrapped in the existing `ProjectCommandSandbox`.
That strict wrapper clears inherited environment, mounts the target read-only,
exposes system runtime files under `/usr`, and has no network. Commands needing
other runtime installations or declared network domains are unsupported. The
model's API transport stays outside this command namespace. The native Claude
sandbox remains required with unsandboxed retries disabled; nesting failures
remain failures. Ordinary managed-policy compilation retains its prior behavior.

Accepted `policy.catalog_bindings` retains nonsecret capability templates,
including inherited scope/resources, route, runtime and available skill identity,
even when a capability is off. Later routine proposals must compare against those
immutable templates. Missing skills or routes make an unselected template
unavailable without blocking its recommendation or unrelated capture.

Admission checks the compiler's real permission validators without creating
files or requiring an installed command or live provider. Configuration alone
does not prove enforcement by a launched runtime; execution must compile the
same exact envelope and preserve its scope.

Managed configuration snapshots include descriptor capability definitions in
their digest and preserve them through actor mapping. Binding drift rejects
application. Existing snapshots with no capability key remain readable. Package
permission disclosure includes capability actors conservatively; a bounded
Bash capability discloses broad risk rather than claiming the coarse registry
summary enforces its commands.

## Immutable execution plans and controller custody

`TaskMeta` strictly validates the optional `task_capabilities` adoption map:
schema version 1, `adopted: true`, initial plan version 1 and its SHA-256 digest.
Malformed or partial adoption is an error. Absence on an existing task never
creates a plan or enables new defaults. Adopted captures explicitly pin the
coding workflow even when it was the project default at creation.

The executable plan is separate from human `plan.md`. Canonical JSON versions
live under `execution-plans/<digest>.json`; result and approval blobs use
`capability-results/` and `capability-approvals/`. Plans record task identity,
source/configuration/catalog digests, definitions, explicit inputs, choices,
bindings, policy, approvals, waivers, recommendations and blockers. Referenced
instruction content is embedded with its digest, so history is readable after
the source file disappears. Operator text is redacted before immutable writes;
executable targets must remain validated non-secret task-relative references.

Only `execution-plan-current.json` selects the active version.
`capability-accepted.jsonl` records controller acceptance in a digest-linked,
logically append-only chain. Both fixed names are protected anchors even when
absent before a spawn. Content-addressed directory entries do not establish
authority: every accepted plan, result and approval is rehashed on every read,
and every referenced approval must be chained. Missing, altered or unaccepted
state blocks; it cannot fall back to legacy behavior. Reading a plan must also
preserve its exact accepted canonical digest, including after redactor changes.

`Store#activate` acquires the existing task lease and fences the directory
observation, stable task identity and expected current version. It writes blobs
and accepts their digests before atomically changing the pointer. A crash before
pointer publication leaves the prior version active and permits an exact retry.
The initial approval batch is accepted together with the initial plan before
pointer publication. Approval content binds task identity and its envelope
independently of the final plan digest, avoiding a circular digest reference;
result content binds both task identity and execution-plan digest.

Legacy reads make no writes. Capture commit failures remove the complete
candidate, including its adoption metadata and execution-plan files. Agent
proposal files outside the anchors remain proposals until controller validation
and acceptance. Generic stage spawns without an existing custody manifest gain
capability-anchor and metadata custody for adopted tasks while retaining ownership of their
ordinary stage document.
Missing or non-directory task roots cannot be read as legacy tasks, and fixed
controller anchors without adoption metadata are rejected.

Managed updates preserve existing plan versions. A selected capability's
definition or inherited stage actor/model/instruction/scope change blocks an
active retained task before repinning. Every blocking task is named with the
required recovery: finish, archive or cancel it before the update can activate,
then prepare the update again. Completed and terminal archived tasks retain
history without blocking a fresh update. Package cleanup retains generations
and configuration snapshots referenced by any accepted plan history. These
historical assets do not authorize execution of an unselected managed generation.

## Selection and capture

`hive new --capability ID=automatic|on|off` accepts repeated named choices.
`--preview` returns the effective choices, reasons, signals, recommendations,
ordered bindings and blockers without writing or launching anything; `--json`
works for preview without an idempotency key. A preview digest includes all
selection inputs and the configuration identity. Capture rejects stale previews.
Adoption is enabled for new coding tasks. Switching it off changes only future
captures; already pinned gates remain enforced.

Automatic QA resolves On. Configured CI or browser behavior checks can supply its
verification plan. Empty, review-only and unavailable verification plans block
all dispatch. Explicit `qa=off` needs `--qa-waiver-reason TEXT` and repeatable
`--qa-waiver-check CHECK_ID`, covering every planned check, or one `all` value.
The durable state says `waived`; the next task still defaults QA On. Hard policy
requirements reject conflicting choices.

UI Automatic recommends guidance unless a configured finite-signal policy selects
it within the existing stage envelope. Selected UI requires an installed named
compatible skill, exact actor identity and pinned skill fingerprint. Security
Automatic never executes. Explicit security On uses
`--capability-approval security=REFERENCE` for an operator-written exact actor,
tools, local target references and budget/timeout envelope. A missing or excessive
approval prevents dispatch. An approved unavailable security route blocks
finalization only; restore the approved route or archive/cancel the task.

Feature-enabled coding creation, keyed or unkeyed, writes resolved version one
and its accepted task-bound approval blobs in the same capture transaction.
Blocked captures remain visible for correction. Keyed replay reads the original
accepted plan before consulting changed policy or preview freshness. The first
successful adopted capture commits one project notice explaining prerequisites,
real behavior checks and the separate per-task QA exception requirement.

Controller admission checks accepted blockers at durable dispatch, direct run,
stage entry and agent spawn. Reads do not re-resolve current project policy.
Operator authorization operations are rejected when Hive can resolve the caller
as an active attempt, including nested CLI calls carrying the controller's
denial-only parent attempt reference. This guard is not a sandbox or proof of
humanity: same-user callers can evade attempt context, and yolo permissions or
web loopback access do not establish strongly authenticated human authority.

Capture rollback retains original directory observation and a process-local
registration ticket. It removes only this capture's new, never-dispatched runtime
subject after its lease is released and every task reference is absent. Changed,
leased or referenced subjects remain intact for repair. This also applies when
initial plan activation fails before pointer publication.

Display-name generation also checks stored admission and wraps its direct model
runtime in the shared fixed-anchor custody. The controller applies the final
name only after inference passes custody; blocked captures do not schedule naming.

Approval subset checks retain every approved denial and use the runtime policy's
validated command-prefix matching, including narrower literal commands beneath
an approved trailing wildcard. Automatic UI selection normalizes permission
presets and permits provable grant/directory narrowing; unknown widening blocks.
A forbidden QA exception is displayed as blocked with its requested reason,
without recording an accepted waiver.

## Independent verification results

`Verification.new(task:, cfg:, worktree_path:, context:, session: nil,
budget_usd: nil, timeout_sec: nil).run!(existing_results: {})` evaluates review
attachments through the same command/actor adapter for built-in and configured
capabilities. Check dependencies order checks within the attachment; this is not
a workflow scheduler. Review supplies its remaining wall-clock deadline and one
shared actor session. A supplied finite budget is shared across every check;
without one, parent money is explicitly uncapped and each actor still requires
an enforceable child cap. Checks never create their own Attempts or usage rows.
Adopted direct review requires `hive run ... --durable` before any check effects.

Capture pins each check's command/provider, timeouts, output bound, environment mode,
and relevant actor route/profile/model, permissions, targets and resource caps.
Browser checks pin their own concrete actor and installed browser skill; an
enabled browser setting alone does not establish a usable route. Retry uses the
accepted snapshot and verifies route/skill identity instead of replacing it from
live configuration. Custom legacy browser output templates require an explicit
verification check rather than inferred requirements. Executable references reject secret-shaped arguments before
redaction; operator reasons and captured output are redacted before persistence.

`Verification.environment(plan: plan)` returns the verification environment
identity: Ruby engine/version/platform and executable digest, resolved PATH
executables used directly by planned commands, and digests of PATH, locale,
timezone and Hive state locations. New command checks run with a fixed system
PATH, UTC and UTF-8 locale, with inherited Rails, Node and Bundler variables
removed. They retain only the denial-only parent attempt reference for nested
operator guards. CLI, Rails and daemon callers therefore evaluate the same
environment. Older accepted plans retain their original strict environment
contract. Relative source
commands are bound by the evaluated commit. Project checks remain responsible
for their own dependencies and meaningful assertions. The controller proves a
clean Git worktree and unchanged revision/environment before and after checks;
a successful command against dirty or changed code is not current evidence.

Each immutable `Result` has schema version 1 and these identities: stable task,
execution-plan digest, capability/check IDs, real parent attempt ID, actor spawn
ID when applicable, evaluated Git SHA, check-configuration digest and environment
digest. It also retains check kind/claim/runner, state, applicability, evidence,
findings and reason. States are `pending`, `running`, `passed`, `failed`,
`blocked`, `not-applicable`, and `stale`. Missing runners, invalid proposals,
timeouts and cancellation are blocked observations; a completed nonzero command
is failed. Findings are `{id, severity, summary, details}` with stable IDs and
actionable text, associated with the enclosing capability/check/result identity.

Command evidence stores evaluated SHA, actual exit status, redacted bounded
output and its digest. Actor reports are JSON proposals with exact supplied
identity, state, applicability, evidence, findings and reason. The controller
validates their schema and hash-checked OutcomeEvidence proof for exactly that
check and SHA. It retains proof bytes before releasing the source snapshot.
Actors read an exact detached commit materialized into their single approved
task-relative target; existing unregistered directories and symlink/outside
targets cannot substitute for it. Runtime restrictions remain the ActorRunner
restrictions above, with no fallback or credential injection.

Browser warnings/skips and unbound `status: passed` JSON cannot qualify. The
optional `BrowserTest::Result#verification` metadata must be a controller
`TaskCapabilities::Result` with matching status and spawn correlation, and still
passes normal identity/evidence validation. Document or terminal outcome proof
can qualify; screenshots and recordings are optional. A missing optional visual
capture is recorded in the reason when other usable proof exists. Missing or
tampered required proof blocks. Zero reviewer findings, skipped CI, an empty
checklist, source-review-only checks and an all-N/A checklist never pass QA.
Individual N/A needs a reason and proof. A whole-QA exception remains `waived`,
with expanded current check IDs/fingerprints, the requested scope and explicit
whole-gate scope when there were no planned checks. It does not waive future
checks.

`ResultStore#accept` validates the accepted plan/check and proof before appending
through `Store#accept_blob`. `Store#blobs(kind)` lists only accepted-chain
references. `ResultStore#history` strictly validates every check result and
retained proof; neither directories nor proposal blobs establish authority.
`ResultStore#current(binding:, check:, plan:, sha:, environment:)` returns state,
result digest and retained result, or pending when absent; identity changes make
it stale. Successful reuse across plan versions requires the same revision,
check configuration, prerequisite identity, actor/scope and environment.
`ResultStore#aggregate(plan:, sha:, environment:)` returns
`state`, `execution_plan_digest`, `evaluated_sha`, `capabilities`, and flattened
`checks`. Waivers stay distinct from passed checks. This aggregate is read state,
not transition authority.

Review returns this aggregate as `:capability_verification`. Its adopted
`REVIEW_COMPLETE` retry path evaluates missing/stale checks instead of permanently
short-circuiting; legacy tasks retain the old shortcut and browser soft warning.
Existing local CI can supply the same typed contract only after clean before/after
Git observations and full pinned command/timeout/output/environment matches.
An early legacy CI terminal failure still records its CI marker/report before
this clean verification boundary; the separate gate/rework consumer must explain
those pending independent checks using the terminal CI evidence.
The finalization consumer must validate the aggregate independently and preserve
blocked/unrun checks when recording separate terminal closure dispositions.

## Finalization gates and terminal custody

`TaskCapabilities::Gate` is separate from forceable execute conditions. It reads
strict current adoption/plan/result state, the clean local SHA and pinned check
environment; missing, replaced, corrupt or unaccepted state cannot authorize a
transition. QA needs at least one passing behavior check. An operator QA Off
exception remains `waived`; hard-required QA cannot waive. Other configured
verification capabilities use the same evaluator.

Review checks the gate at exit. Capability findings retain check/finding/result
identities in `reviews/capabilities-NN.md` and enter the existing triage/fix loop.
A fix changes the SHA and reruns checks; exhausted pass/time limits stay blocked.
Scope expansion and risk disposition require an operator. Review shares one
verification session and wall-clock deadline across its passes; no aggregate
monetary attempt budget is invented. Approved actor caps remain per spawn.

Forward admission beyond review checks the gate before force handling and again
under the task lease. Finalize checks before its agent, pushes and readiness,
including summary retries and code committed by its clean-exit backstop. The
pre-stage rebase publication hook also checks adopted finalize tasks. Local and
hosted PR heads are compared exactly; capability equivalence never relaxes an
exact remote push lease.

Verification stores the complete ordered patch IDs, binary task-delta digest,
base commit/tree and relevant base blobs. A SHA-only rewrite may reuse passing
proof only when the complete delta, base tree, check/actor/scope and environment
are identical. Accepted equivalence receipts retain old/new SHAs and both
identities. Any base byte change is conservatively relevant because arbitrary
checks have no declared narrower input set; rerun review after such changes.

Unavailable approved security routes are rechecked even with historic passing
results. Initial unavailable-route plans preserve the exact approved actor tuple
instead of inventing billing metadata. Restoration must match provider,
profile/model/effort, account and launch binding, plus the runtime fingerprint, installed executable path/bytes
and accepted approval envelope. Observed route/billing metadata is retained with
the correlated result. Initially available routes retain full equality. The
initial unavailable blocker is historical context; restoring the exact route
and producing admissible checks can clear the gate without changing the plan.

`ResultStore` validates explicit `terminal`, `equivalence` and
`finding-disposition` records separately from check observations. Finding-scoped
risk acceptance projects a scoped `waived` disposition with finding references
and can cover actual current failed security findings only; it
cannot cover unrun/unavailable checks or bypass current route availability.
Check history preserves the original failed observation.

Already-merged Finalize, operator closure and merge-watcher reconciliation record
`Closed out-of-band — gate not evaluated`, linked to the PR or exact closure
receipt. Cancellation records `Cancelled — gate not evaluated`. Neither changes
blocked/unrun checks into passed or waived. A validated closure receipt may
retire directly into the terminal archive through the guarded archive protocol;
its receipt digest is revalidated under the move lease. Terminal reporting may
finish with that exact accepted closure link, while active-stage admission stays
enforced. Missing worktrees never hide the retained terminal annotation.

`capability_gate_observed` journal activities carry bounded state, check-result
digests and plan/SHA identity; projection selects only the current task and
commit generation. `capability_terminal` activities retain terminal custody.
Full command output and evidence remain task detail data, outside fleet facts.
Operator recovery uses the shared execution-plan revision service.

`Gate#read_state` is explicitly a read model. Controlled checks use the same
verification environment across CLI, Rails and daemon processes; executable
identity changes still stale their evidence. Historical plans use their pinned
read environment and require their strict original environment for execution.
Only `Gate#enforce!` authorizes advancement. A Rails integration fixture creates
a real task, runs a durable check and approves it under different creator,
executor and reader environments.

## Task workspace and web controls

`Projection` reads accepted plan versions, results and proposals for both
`hive task` and Rails task detail. It retains choices, selection reasons, ordered
attachments, exact actors/models, skill digests, versions, waivers, applicability
and evidence references. Raw command output stays in the immutable result store.
The gate digest, including terminal closure, participates in the workspace's
material refresh signature. Reads never resolve from new project policy.

The permanent composer has labelled native Automatic/On/Off radio groups below
its toolbar. A project change fetches a fresh preview. QA Off reveals reason and
affected-check inputs; security On reveals the exact-approval picker. Preview
blockers use a polite live region and disable submission. Targeted refreshes
preserve text, attachments, radio choices, focus and disclosure state. Stale
previews reject inline and retain the draft.

Task detail leads with the gate, blockers and shared shell-escaped recovery
commands. Pending capability proposals have separate Accept/Reject controls,
disabled with visible reasons for live attempts or stale identities. Corrections,
QA waivers and finding risk acceptance use the same revision service as CLI,
with existing login and CSRF protection. Attempt-context authority rejection is
server-side; controls are not an authorization boundary. All eight result states
have distinct text labels. Out-of-band closure preserves unrun/blocked checks
and links its separate closure annotation to a receipt.

The stored base context includes the observed target ref/tree as well as the
incorporated merge base. Target tree changes stale checks even while task HEAD
is unchanged. Authoritative gate enforcement refreshes the existing origin base
through the controller's ordinary fetch path; a failed refresh blocks. Therefore
`--no-rebase` suppresses rewriting, not base freshness. Review reruns checks at
the final task SHA and records the new observed base context; this introduces no
merge-testing scheduler. Reader projections make no network requests.
The retained task dependency base takes precedence over the configured default
branch; otherwise the controller uses the existing origin default. Git reads
and refreshes use the exact branch ref, so an ambiguous tag cannot supply base
identity. Local repositories without origin retain their exact local base ref.

## CLI

`hive task-capabilities` is a top-level command for one task:

```bash
hive task-capabilities show TARGET [--project NAME] [--json]
hive task-capabilities propose TARGET --identity JSON --plan-version N --sha SHA [OPTIONS]
hive task-capabilities accept TARGET --identity JSON --plan-version N --sha SHA --proposal DIGEST
hive task-capabilities reject TARGET --identity JSON --plan-version N --sha SHA --proposal DIGEST --reason TEXT
hive task-capabilities waive TARGET --identity JSON --plan-version N --sha SHA --reason TEXT --checks all
hive task-capabilities risk-accept TARGET --identity JSON --plan-version N --sha SHA --result DIGEST --findings ID... --reason TEXT
```

Use `show` first. Its `expected` object supplies the exact task identity, active
plan version and Git SHA required by mutations. `TARGET` uses the shared task
resolver; `--project NAME` disambiguates registered tasks. A legacy task has no
execution plan and is never adopted by inspection. Retained terminal history
remains readable after worktree cleanup: `expected` is null and
`mutation_unavailable` explains why the task is read-only or Git is unavailable.

## Options

All `hive task-capabilities` actions accept `--project NAME` and `--json`.

| Option | Meaning |
|---|---|
| `--identity JSON` | Task identity from `show.expected.expected_identity`. |
| `--plan-version N` | Expected active execution-plan version. |
| `--sha SHA` | Expected implementation Git revision. |
| `--select ID=automatic\|on\|off ...` | Named selections for `propose`. |
| `--verification-plan JSON` | Verifier IDs mapped to declared check arrays. |
| `--capability-approval ID=REFERENCE ...` | Approval references in the pinned policy. |
| `--task-approval ID=REFERENCE ...` | Propose an exact task-specific approval under a task-local reference. |
| `--proposal DIGEST` | Exact proposal to accept or reject. |
| `--reason TEXT` | Human waiver, rejection or finding-disposition reason. |
| `--checks ID...` | Every current QA check ID, or `all`, for a waiver. |
| `--result DIGEST` | Accepted failed security result for `risk-accept`. |
| `--findings ID...` | Actual finding IDs covered by that disposition. |

Array options take space-separated values. Creation uses the separate repeatable
`hive new --capability` and `--qa-waiver-check` flags described above.

## Behavior

`hive task-capabilities propose` writes an inert, content-addressed proposal
outside the protected anchors. `accept`, `reject`, `waive` and `risk-accept`
reject resolvable attempt context before writing. They acquire the task lease,
require no live owning attempt, and compare task identity, plan version and Git
revision again. Exact retries recover interrupted activation without publishing
a second version. Earlier plans, decisions and evidence remain readable.

Revisions use embedded catalog/instruction/runtime/skill snapshots and captured
stage permissions and resource limits. Current project settings or a candidate
generation cannot expand that authority. An operator can declare QA checks
within the captured command scope. Changed checks and their dependents become
stale; unchanged checks may retain evidence. Routine UI additions already
covered by pinned policy can activate at a safe boundary. Required guidance
reruns stay visible; selecting an attachment does not prove it ran. Every active
security addition requires explicit operator acceptance, even with reusable
project approval.

When no reusable project approval exists, `propose --task-approval
security=task-owner` prepares an approval for the already captured security
actor, tools, local targets, budget and timeout. The proposal exposes that exact
envelope and its digest for human inspection before `accept` publishes a
task-bound operator approval. It cannot authorize a new route or broader scope
from current project settings. Proposal creation alone grants no authority.

`waive` creates an audited QA Off plan with a reason and current affected checks.
`all` expands at that version, including an explicitly empty checklist; it grants
no exception for future checks. Hard-required QA refuses. `risk-accept` names
actual failed security findings. It cannot waive an unrun/unavailable check,
remove selected security, authorize a fallback, or permit finalization while the
approved route is unavailable. Restore that route or archive/cancel without
finalization. Stage approval and `--force` supply no capability waiver authority.

## Examples

A human starts with `hive task-capabilities show example --project demo --json`.
To record a permitted exception, substitute the current identity/version/SHA
from `show` below and supply the actual task-specific reason:

```bash
hive task-capabilities waive example --project demo \
  --identity '{"id":"TASK_ID","slug":"example","workflow":"coding"}' \
  --plan-version 1 --sha COMMIT_SHA \
  --reason 'I accept the missing automated check for this task after checking it manually' \
  --checks all
```

To configure verification instead, `hive task-capabilities propose` accepts, for
example, `--verification-plan '{"qa":[{"id":"tests","kind":"behavior","claim":"Repository tests demonstrate the changed behavior","command":"bundle exec rake test"}]}'`
when that command is within the captured stage authority. Inspect the proposal,
then accept its digest with the same freshness arguments. A project config edit
alone neither updates this task nor waives the next task's QA gate.

## JSON schema

`hive task-capabilities --json` uses `hive-task-capabilities` schema version 1,
registered at `schemas/hive-task-capabilities.v1.json`. Success contains
`schema`, `schema_version`, `ok: true`, `action` and `data`. `show` data includes
the persisted plan, history, proposals, freshness arguments and required guidance
stages. Mutation data identifies the proposal, decision or accepted version.
Without `--json`, success prints readable JSON data. Neither mode re-resolves
choices from current project policy.

## Output exceptions

`hive task-capabilities --json` emits the shared `ok: false` error envelope for
typed errors, preserving a nonzero exit and stderr diagnostic. Invalid
selections, stale identity/version/SHA, a live owning attempt and missing
operator authority have distinct reasons. Corrupt accepted state fails closed.
A blocked or rejected mutation never reports a passing gate or implies security
work ran.

## Serialization fallback

`hive task-capabilities` has no prose or success-shaped JSON serialization
fallback. `JSON::GeneratorError` propagates if an envelope cannot be encoded.
Operator text is redacted before proposal, decision, plan or journal publication.
Executable targets must be non-secret references, never redacted substitutions.

## Exit codes

For `hive task-capabilities`, exit 0 means inspection or the requested operation
completed. Exit 64 covers usage, invalid selections, stale revision fences,
running-attempt boundaries and attempt-context refusal. Exit 75 covers concurrent
lease/version conflicts, 78 invalid configuration, 70 an unexpected internal
error, and 1 other stored-state or operational failures. Read the typed JSON
reason before retrying. An accepted QA exception remains `waived`; an accepted
proposal still needs current verification before finalization.
