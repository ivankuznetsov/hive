## Round 1
### Q1. Should the v1 abstraction be a generalized installable module contract beneath honeycombs and patrols, a workflow-module contract used only by patrols for now, or a parallel patrol-package system—and what compatibility constraint makes that choice decisive?
### A1.

Extend the existing Honeycomb package lifecycle, catalog, validation, managed
store, and lock machinery with module hooks, schedules, event bindings,
configuration, and enabled state. Patrol and Architecture Patrol become
first-party packages on that existing foundation. Do not create either a
parallel patrol-package system or a second generalized module platform. The
decisive compatibility constraint is that existing
honeycomb manifests, catalog entries, installations, and install commands must
continue working without republishing or manual migration.

### Q2. Which installation scopes must v1 support (user-wide, project-local, or both), and when both contain the same module, which scope owns the selected version, configuration, and enabled state?
### A2.

Support project-local installation only in v1. Packages come from the shared
Honeycomb catalog, but each project independently installs, configures,
enables, pins, updates, and removes a module. This avoids user-wide versus
project-local precedence, version shadowing, inherited permissions, and
ambiguous enablement. A future bulk command may apply the same module operation
to several registered projects, but it must still produce independent
project-local installations. User-wide installation may be added later if a
demonstrated need justifies the additional resolution model.

### Q3. What is the minimum named event vocabulary that must work at launch, beyond scheduled triggers, and which events must be proven specifically for Patrol and Architecture Patrol?
### A3.

Launch with the named events `task.completed` and `pull_request.merged`, in
addition to scheduled triggers. Module bootstrap/setup occurs during the
installation transaction rather than through a separate `project.registered`
event. Every event carries a
stable project identity, occurrence time, source identity, and idempotency key.
Patrol must prove both scheduled launch and `task.completed` launch;
Architecture Patrol must prove both scheduled launch and
`pull_request.merged` launch. Do not add wildcard matching or a broader GitHub
event catalog in v1.

### Q4. After installation, should a module and each of its hooks default to disabled until explicitly enabled, preserve an existing patrol's active state during migration, or follow another enablement rule?
### A4.

Installation is the configuration and enablement transaction. The install
preview must show every hook, schedule, event binding, permission, and proposed
enabled state; the user selects or accepts those states during installation.
After explicit confirmation, Hive atomically installs the module and activates
the selected hooks, with no separate enable command required. Non-interactive
installation must provide the choices explicitly and fail rather than assume.
Migration preserves each existing Patrol and Architecture Patrol active state.
Updates preserve current hook states, and newly introduced hooks require
explicit approval before activation.

### Q5. What trust boundary should v1 enforce for remote modules: first-party/catalog sources only, arbitrary sources with explicit approval and checksum pinning, or signed publishers—and which permissions must always require separate consent?
### A5.

V1 installs only first-party or reviewed catalog modules. Pin every version to
an immutable source commit and verify its manifest digest; do not accept
arbitrary Git URLs or unreviewed local packages. Installation previews all
permissions before activation. Repository writes, GitHub mutations, secret
access, external command execution, new network hosts, and wildcard filesystem
or network access always require separate explicit consent. An update that
expands permissions requires renewed consent, while unchanged permissions do
not. Patrol and Architecture Patrol follow the same policy despite being
first-party.

### Q6. Which existing Patrol and Architecture Patrol commands, configuration keys, schedules, state, and observable outputs form the mandatory compatibility surface, and how long must deprecated aliases remain supported?
### A6.

Preserve `hive patrol` and `hive refactor-patrol` as forwarding aliases with
their current flags, exit codes, JSON schemas, and human outcomes. Automatically
migrate `patrol.*` and `refactor_patrol.*` settings, including schedules,
modes, reviewers, limits, include/exclude rules, and enabled state. Preserve
dismissals, checkpoints, deduplication history, retry and budget state,
artifacts, and in-flight recovery data so migration cannot repeat completed
work or reopen equivalent PRs. Keep deprecated commands and config keys through
the remaining 0.x releases and remove them only at Hive 1.0, after warnings
provide exact replacements.

Hive Web is part of the mandatory surface. Add a Modules page listing every
module installed in the selected project and its version, provenance, enabled
state, hooks, schedules, event bindings, permissions, and effective settings.
Secret values must remain redacted; show only binding names and whether each is
configured. Web settings changes must use the same preview, validation,
permission-consent, and atomic activation contract as CLI installation/update.

### Q7. What evidence is sufficient to declare parity and retire each bespoke patrol mechanism: fixture equivalence, migration dogfood over a defined period, fallback/rollback proof, or another explicit gate?
### A7.

Require fixture-level equivalence for commands, configuration, scheduling,
decisions, JSON, artifacts, and failure behavior, plus migration tests using
realistic existing Patrol and Architecture Patrol state. Shadow-dogfood both
modules on real projects for at least seven days and at least ten trigger
decisions per module. Only one implementation may mutate during shadowing; the
other records its proposed decision. Require zero unexplained differences,
duplicate jobs, repeated findings, or duplicate PRs. Prove rollback restores
the prior implementation and state without losing checkpoints. Retire bespoke
code only after every gate passes and the migration report is reviewed. Ship
the module foundation and shadow mode first; retire bespoke code in a separate
cleanup PR after the live parity window completes.

### Q8. If install, update, migration, enablement, or hook execution fails partway through, what must be rolled back automatically and which prior checkpoints, artifacts, lock data, or diagnostics must remain available?
### A8.

Separate immutable installation generations from persistent runtime state.
Keep only the active generation and one previous generation; checkpoints,
deduplication history, attempts, and artifacts live outside them and are never
rolled back by installation changes. Build and validate a candidate, atomically
switch the active pointer, and switch it back if the activation health check
fails. Delete the failed executable candidate and retain only a redacted
diagnostic summary. A hook failure records a failed attempt and uses Hive's
existing bounded retry policy; it never rolls back the installed module.

### Q9. What must `inspect/status`, `doctor`, and dry-run show for an operator to explain a module run end to end—for example resolved version/provenance, effective config, next trigger, last attempt, deduplication decision, permissions, artifacts, and failure reason?
### A9.

`inspect/status` must show the active version, source commit, manifest digest,
enabled hooks, schedules, event bindings, redacted effective settings,
permissions, next trigger, latest attempt, retry state, artifacts, and failure
reason. Each run explains why it launched or was skipped, including trigger,
event ID, deduplication result, concurrency decision, and linked workflow task.
`doctor` validates the active generation, digest, configuration, secret
bindings, scheduler/event registration, permissions, and runtime prerequisites.
Dry-run shows whether a trigger would match, what would block it, and which
workflow/configuration would run. CLI JSON and Hive Web share one status model.
Never expose secret values, raw environment data, or unsafe stderr.

### Q10. Besides green local and hosted CI, what concrete acceptance scenarios must the PR demonstrate for both first-party modules across fresh install, existing-user migration, scheduled launch, event launch, update, disable/re-enable, and uninstall?
### A10.

For both Patrol and Architecture Patrol, prove that a fresh project-local
install configures and enables selected hooks atomically and that Hive Web
matches CLI settings/status. Migrate realistic existing configuration and
runtime state without duplicate work. Prove scheduled and required event
launches, replay deduplication, and single-run concurrency. Prove successful
updates preserve state, failed updates restore the previous generation, and
permission expansion requires renewed approval. Disabling must stop new
launches; re-enabling must not replay old events. Uninstall must stop future
launches while preserving historical tasks/artifacts and a non-executable
workflow tombstone containing the stable workflow identity and minimal
descriptor/policy snapshot needed to render those tasks. Deprecated commands
must still forward correctly. The first reviewed PR delivers the foundation,
first-party packages, compatibility forwarding, and shadow mode without
retiring bespoke code. A later cleanup PR proves the completed live parity
gate and performs retirement. Both require green local and hosted CI and must
be non-draft and merge-ready, but neither is merged automatically.

## Requirements

### Actors

- Project operators install, configure, consent to permissions, update, inspect, enable or disable, diagnose, and uninstall modules independently for each Hive project through CLI or Hive Web.
- Module authors package workflows, stages, hooks, schedules, event bindings, configuration, permissions, templates, provenance, and documentation through the extended Honeycomb package contract; existing honeycombs remain compatible.
- Hive validates reviewed catalog packages, activates immutable project-local generations, dispatches hooks through existing workflow machinery, and preserves runtime history independently of installed generations.
- Existing Patrol and Architecture Patrol users retain current behavior, state, outputs, and entry points while the first-party modules are migrated and parity is proven.

### Flow

- Discover only first-party or reviewed modules through the shared Honeycomb catalog; install an immutable source commit with a verified manifest digest and project-local version lock.
- Preview all hooks, schedules, event bindings, settings, permissions, and proposed enabled states; require explicit non-interactive choices and separate consent for repository writes, GitHub mutations, secrets, external commands, new network hosts, and wildcard access.
- Validate a candidate generation deterministically, atomically activate the selected configuration, retain the previous generation for rollback, and keep checkpoints, deduplication history, attempts, retry or budget state, and artifacts outside generation rollback.
- Launch module workflows through existing scheduler, event, attempt, lock, retry, and artifact machinery for schedules plus `task.completed` and `pull_request.merged`; installation owns bootstrap/setup, while stable event identity and idempotency keys explain and prevent duplicate or concurrent work.
- Preserve current hook states on update, require consent before activating new hooks or expanded permissions, stop new launches while disabled, avoid replaying old events on re-enable, and preserve historical tasks, artifacts, and a non-executable workflow tombstone after uninstall.
- Expose one redacted status model in CLI and Hive Web covering version and provenance, effective settings, permissions, hooks, next trigger, latest attempt, retries, artifacts, failure reason, and every launch or skip decision; provide doctor and dry-run diagnostics without secrets, raw environment data, or unsafe stderr.
- Automatically migrate `patrol.*` and `refactor_patrol.*` configuration plus schedules, dismissals, checkpoints, deduplication, attempts, artifacts, and in-flight recovery state; retain `hive patrol` and `hive refactor-patrol` forwarding aliases with compatible flags, exit codes, JSON, and human outcomes until Hive 1.0.
- Deliver migration in two steps. First ship the Honeycomb lifecycle extensions, both first-party packages, and non-mutating shadow mode while leaving bespoke patrol machinery authoritative. After at least seven days and ten trigger decisions per module prove parity, retire bespoke machinery in a separate reviewed cleanup PR.

### Acceptance examples

- A fresh project installs either module from the catalog, previews and explicitly approves its settings and permissions, atomically enables selected hooks, and shows matching redacted CLI and Hive Web status.
- Patrol runs from both its schedule and `task.completed`; Architecture Patrol runs from both its schedule and `pull_request.merged`; installation performs module bootstrap behavior.
- Replaying an event does not create a second job, simultaneous matching triggers produce at most one permitted run, and status explains the trigger, event ID, deduplication result, concurrency decision, and linked workflow task.
- A realistic existing installation migrates without changed decisions, repeated completed work, reopened equivalent PRs, lost checkpoints, or changed command and output contracts.
- A successful update preserves runtime state and current hook enablement; a failed activation restores the prior generation; a permission expansion or new hook remains inactive until separately approved.
- Disabling blocks new launches, re-enabling does not replay historical events, and uninstalling removes future dispatch while retaining historical tasks, artifacts, and the non-executable workflow tombstone required to render them.
- The foundation PR proves fixture equivalence for commands, configuration, schedules, decisions, JSON, artifacts, and failure behavior while leaving bespoke code authoritative. Before the cleanup PR retires it, shadow dogfood runs for at least seven days and ten trigger decisions per module with zero unexplained differences, duplicate jobs, repeated findings, or duplicate PRs.
- End-to-end tests cover fresh install, migration, schedule and event launch, replay deduplication, concurrency, update and rollback, permission renewal, disable and re-enable, uninstall, deprecated aliases, doctor, and dry-run for both first-party modules.
- Each delivery is a reviewed, non-draft, merge-ready PR with green local and hosted CI; unrelated dirty wiki files remain untouched, and neither PR is merged or placed on auto-merge automatically.

<!-- COMPLETE -->
