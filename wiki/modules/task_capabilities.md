---
title: Task capability contracts
type: module
source: lib/hive/task_capabilities/definition.rb, lib/hive/task_capabilities/catalog.rb, lib/hive/task_capabilities/policy.rb, lib/hive/task_capabilities/plan.rb, lib/hive/task_capabilities/store.rb, lib/hive/task_capabilities/resolver.rb, lib/hive/task_capabilities/approval.rb, lib/hive/task_capabilities/admission.rb
created: 2026-11-03
updated: 2026-11-03
tags: [module, workflow, capabilities, policy]
---

Task capabilities attach guidance or independent verification to stages that
already exist. They are separate from `Workflow::Result.capabilities` (result
presentation facilities) and AgentProfile's runtime tool vocabulary. Coding
keeps its nine stages.

`task_capabilities.enabled` defaults to `false`. When explicitly enabled for
the lower-level shared capture service, new coding captures atomically install
an all-Automatic initial execution plan. Existing tasks and other workflows
retain their previous behavior. Selection, actors, gates, and recovery must be
integrated before adoption is enabled by default; this persistence substrate
does not authorize security work or waive QA.

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

An outer attempt's explicit provider-account route is not automatically a
capability route. Until a separately pinned specialist route can prove that
account and launch binding, this case remains an explicit blocker. Guidance
does not authorize a fallback or widen the primary stage's authority.

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
Adoption remains disabled by default until review gates and recovery are complete.

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
