---
title: Task capability contracts
type: module
source: lib/hive/task_capabilities/definition.rb, lib/hive/task_capabilities/catalog.rb, lib/hive/task_capabilities/policy.rb, lib/hive/task_capabilities/plan.rb, lib/hive/task_capabilities/store.rb
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
