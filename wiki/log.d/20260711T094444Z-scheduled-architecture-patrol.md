# 2026-07-11 — Scheduled architecture patrol

- Fresh terminal and web initialization now recommend enabling post-merge
  architecture discovery by default, while auto-fixing and issue filing remain
  independent, explicit, default-off consent gates.
- Added immutable merge manifests, durable v2 job/action ledgers, feature-level
  retry checkpoints, semantic-family deduplication, fenced dead-owner recovery,
  large-result file transport, and fair daemon scheduling alongside ordinary
  patrol. The catch-up checkpoint is now schema v2 and binds registration,
  exact host, repository, and default branch.
- Discovery and documentation mapping are language- and project-neutral.
  Source grouping now recognizes common ecosystems, unfamiliar text-source
  extensions, shebang scripts, build/infrastructure files, and independent
  manifest slices; source-only import edges drive leverage without counting
  tests, docs, assets, fixture manifests, or arbitrary mapper chunks as
  coupling. Mapper failures now surface bounded incomplete-measurement
  diagnostics and force affected theses into report-only status instead of
  masquerading as genuine zero leverage.
  Automatic fixes stay isolated and fail closed unless public-contract,
  boundary, validation, dependency, patch-cap, and secret checks can prove the
  change safe; deterministic non-fixable findings can route to deduplicated
  issues when that separate gate is enabled.
- Proposal leverage now defaults to a `0.25` automatic-action floor, reviewer
  output obeys one strict run-wide thesis budget, and every cited file, line,
  and snippet is verified against root-confined checkout bytes. Configured
  `refactor_patrol.commands.public_contract` checks run for every relevant
  source/public-surface fix in addition to built-in ecosystem guards. Ruby
  visibility is scoped per parsed class/module, and architecture-specific
  review budgets take precedence over ordinary patrol defaults. Extensionless
  script changes are detected from current or pinned-base shebang bytes and
  require configured contract certification before automatic publication.
- Existing issues reconcile from a complete exact-host open/closed inventory:
  v2 action markers win first, while only strictly shaped markerless historical
  bodies can join a semantic family. Malformed or pairwise-incompatible legacy
  candidates fail closed instead of suppressing a new finding.
- PR and issue publication now persist creation intents, bind recovery to the
  source host/repository and exact remote branch state, re-check current policy,
  claim generation, and unique repository ownership immediately before each
  request, reconcile ambiguous attempts before retrying, and require successful
  OPEN/MERGED patrol publications to enter `6-review` without ever merging them
  automatically. Refactor pushes reuse one validated origin URL with exact
  absence/OID leases; multiple push URLs fail closed. Canonical action and
  semantic-family ids include the source host, and fixes use the repository-global
  `hive-refactor/<canonical-action-id>` branch across jobs and registration
  handoffs.
- Terminal PR/issue/handoff proof is archived immutably under global state;
  the canonical-action catalog is a disposable projection. Exact proof can be
  materialized across registrations without rerunning adapters and survives
  catalog loss, owner deregistration, or owner-path removal, while corrupt or
  conflicting archives block. Dry-run reads this state without writing either
  archive or catalog.
- Full publication authority now requires the target's exact live
  registration. Enabled duplicate owners, disabled registrations with pending
  remote continuation evidence, missing registration, and unresolved
  config/identity/continuation state all block visibly. Scheduler config
  failures are durably recorded as `project_config_unavailable`, including a
  failure between candidate selection and reservation.
- Newly created PRs are re-read from the exact host/repository and must match
  URL/number, OPEN non-draft state, head repository/branch/OID, and base before
  a separately fenced `6-review` handoff. Exact-host merge-detail and GraphQL
  intake validate returned PR identity before advancing catch-up state.
- Expanded unit, integration, schema, scheduler, supervisor, and fake-GitHub
  coverage for mixed fix/issue/suppression lifecycles, explicit terminal-job
  replay, dry-run consent/ownership parity and non-mutation, stale claim
  fencing, crash recovery, and language-neutral safety behavior.
