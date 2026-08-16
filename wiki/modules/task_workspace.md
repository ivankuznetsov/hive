---
title: Task workspace projection
type: module
source: lib/hive/task_workspace.rb, lib/hive/task_workspace/, lib/hive/context_provenance.rb, lib/hive/task_activity.rb, schemas/hive-task-workspace.v1.json, schemas/hive-task-workspace.v2.json, schemas/hive-context-receipt.v1.json, lib/hive/commands/task.rb, web/app/controllers/tasks/, web/app/views/tasks/
created: 2026-08-12
updated: 2026-08-16
tags: [task, web, projection, semantic, result, usage, provenance, attempts, timeline, dependencies, publication]
---

**TLDR**: `Hive::TaskWorkspace::Builder` turns one already-resolved task into
two bounded read models. Semantic `hive-task-workspace` v2 is the normal Web
and native-agent contract: canonical headline/action, workflow result and
applicability, primary/supporting artifacts, exactly attributed usage with an
API-equivalent estimate, and an attempt-correlated diagnostic-log reference.
Strict v1 remains the authenticated audit/mutation compatibility document with
attempts, provenance, resources, and timeline panels. Neither version replaces
`hive-status` v7, scans the fleet, performs provider/pricing network requests,
or creates a new action protocol.

## Boundary and route

`Tasks::BaseController` resolves exactly one registered project and slug
through `Hive::Web::TaskTargetResolver`. It passes that native task, its
already-projected status row, the broadcaster's existing dependency context,
and injected bounded readers to `Hive::TaskWorkspace::Builder`.

The authenticated routes keep version choice explicit:

```text
GET /tasks/:project/:slug            # HTML composed from semantic v2; v1 is private mutation state
GET /tasks/:project/:slug.json       # explicit strict v1 audit compatibility document
GET /tasks/:project/:slug/workspace  # semantic v2 JSON
GET /tasks/:project/:slug/timeline   # signed older/raw v1 audit cursor page
```

Native agents read the same semantic projection without starting or scraping
Rails:

```bash
hive task TARGET --project NAME --json
```

All three are authenticated by the ordinary Hive Web gate. `source=archive`
uses the existing targeted archive resolver and remains read-only. No raw
mutation command, observation token, capability, prompt, argv, credential, or
absolute host path appears in the workspace schema. Agents continue to obtain
executable guarded actions from `hive status --operational --json` and execute
them with `hive act`; the Web document contains only a sanitized action label,
state, enabled flag, and explanation.

The strict `hive-status` v7 contract is unchanged. Workspace detail is kept in
its own schema so fleet status, the TUI correspondence contract, and existing
automation do not acquire task-detail fields or new read costs.

## Semantic v2 document

V2 answers the operator's task-local questions without publishing the raw
audit chronology. Its closed top-level fields are:

```text
task · status · headline · action · result · applicability · usage · evidence · diagnostic
```

`result` is derived from the normalized [[modules/workflows]] result contract,
never a workflow-ID branch. A declared primary artifact wins when it exists;
the current stage artifact is the in-progress fallback. A completed task whose
declared deliverable is absent carries a specific warning. The six applicability
booleans decide whether worktree, diff, publication, media, dependency, and
supporting-artifact evidence is meaningful; actual safe evidence can make a
section applicable even when a legacy declaration omitted the capability.

`usage` aggregates every session in the bounded durable attempt inventory once
by exact session ID, including failed attempts and retries. It separates
harness, evidenced actual provider/model, and `api`, `subscription`, `mixed`,
or `unknown` billing route. `complete`, `partial`, `pending`, and `unavailable`
remain distinct. API-equivalent USD is a local rate-card estimate with coverage
and missing dimensions, never an invoice or a claim that subscription use cost
zero. Provider-reported cost is deliberately absent from v2.

`diagnostic` is `not_applicable` for normal tasks. A genuine red/recovery state
can carry one bounded summary and the current attempt receipt's safe
`log_reference`; the log route binds the request to that reference digest.
Newest-file mtime is only the older unqualified log compatibility behavior and
does not select the semantic diagnostic. Raw log content is never embedded in
v2.

Semantic snapshots are closed-schema, canonical JSON. Decimal estimates become
exact decimal strings. When the document reaches its 2 MiB budget, the builder
removes supporting contents, then usage groups, then primary content while
retaining identities and explicit truncation. Absolute paths, executable
commands/tokens, prompts, credentials, secrets, and provider-reported cost are
rejected recursively.

## Audit v1 document and evidence states

The v1 top-level document contains exact task identity, generation time, status
freshness, normalized operator state, one decision posture, and seven panel
envelopes. Operator state owns bounded open-question bindings, recovery
lifecycle/action facts, and its compatibility diagnostic summary:

```text
provenance · attempts · resources · timeline · dependencies · publication · artifacts
```

Every panel has `state`, `records`, `diagnostics`, and `truncated`. The closed
state vocabulary is `current`, `stale`, `partial`, `missing`, `conflicting`,
`unavailable`, `estimated`, `exhausted`, and `retry-after`. Field records add a
symbolic source, safe task-relative evidence reference, observation time,
quality label, retained conflicts, and truncation flag.

Answer readiness is intentionally narrower than execution-action readiness. A
fresh status observation plus at least one exact task-local opaque question
binding establishes the `answer` posture even when the bounded task projection,
attempt, or resource panels are partial or missing. Every answer write
revalidates that binding through `Hive::Commands::Answer`, so a replaced round,
changed question, or moved task still fails closed. Approve, Retry, Run, and
other execution-dependent controls continue to require current projection,
attempt, and resource evidence; archived or stale-status task pages remain
read-only.

Source precedence is deterministic: canonical task projection and task journal
own lifecycle identity; attempt records own attempt lineage; controller and
agent receipts own captured context; runtime receipts own actual session/model
facts; `UsageDb` owns attributed usage; dependency snapshots own scheduling
edges; strict worktree/local Git observations own local publication facts; the
credential-scoped cache owns remote GitHub observations. A lower-precedence
conflict is retained instead of silently overwritten.

`TaskWorkspace.panel` isolates each projector. A malformed journal, attempt,
context receipt, dependency row, worktree pointer, artifact, cache entry, or
Git result becomes a panel diagnostic; it cannot turn the task route into a
500 or hide unrelated questions, actions, artifacts, diff, or log.

## Immutable provenance

`hive-context-receipt` v1 has two deliberately different qualities:

- `controller_launch` / `observed_at_launch` captures repository HEAD,
  normalized repository identity, and bounded Wiki identity after the durable
  attempt exists and before worker handoff.
- `agent_selection` / `agent_asserted_used` is an optional, attempt-bound report
  of selected project-relative references, bounded query/result labels, and a
  rationale. It is an agent assertion, never proof that the model consumed the
  context.

The agent writes only the candidate
`context-receipts/<attempt-id>.json.next`. The controller descriptor-opens,
validates allowlisted repository/Wiki field types as well as
binding/schema/containment/size, rejects absolute host paths in every receipt
string, redacts, and publishes with filesystem no-replace semantics. Promotion
removes the candidate only after the immutable receipt exists; a retry of an
already-promoted receipt reconciles any missing selection activity event.
Promoted context, projection-checkpoint, activity-operation, and journal
receipts are protected throughout agent custody. Current repository/Wiki
identity is observed separately and may mark the historical receipt stale.
Legacy tasks without receipts stay missing or partial; the projector never
reconstructs selection from current files, prompts, argv, prose, logs, or
timestamps.

## Attempts, sessions, resources, and semantic usage

Exactly one attempt can be current: the ID bound by `TaskProjection.identity`.
Workspace history starts from task-local bindings and follows only exact
predecessor IDs with `Attempts::Store#fetch`; it never scans the global attempt
store. Multiple live but unbound attempts are a conflict, not multiple current
attempts.

Each actual child spawn has its own stable session/correlation ID under the
attempt. Start/finish observations retain role, requested provider/model/effort,
provider-reported actual model when available, health, outcome, timestamps,
timeout, guards, and usage. Missing runtime facts remain unavailable.

The session start append must succeed before provider execution. Terminal
session observations use replayable activity-operation receipts, so a provider
that completed while the final append failed is reconciled immediately or at
the next launch rather than remaining projected as live. Provider-native
`status: timeout` results and explicit timeout flags share the same timed-out
outcome. For stages with
artifact custody, `ArtifactFirewall::AgentCustody` then encloses only the
untrusted provider call and managed-output materialization. Validation and
restoration finish before context promotion and the terminal session receipt.
If restoration cannot establish a safe task path, context promotion and the
terminal session write are suppressed. The journal stays protected from
agent-authored bytes; controller telemetry is not mistaken for tampering.

Resource records keep different meanings separate:

- monetary API caps;
- subscription-backed budget-equivalent guards;
- token limits;
- launch/account/provider quotas; and
- wall-clock timeouts.

Each guard retains unit, scope, source, enforcement, billing semantics,
configured value, observed value, reset/retry time, and state. Headroom is
computed only when configured and observed values have a trustworthy matching
unit and session scope. Tokens are never converted to cost, absent usage is
never rendered as zero, and a subscription-backed `budget_usd` guard is not
described as billed spend.

`UsageDb` schema v4 keeps nullable attempt/session/generation/source columns,
field-availability flags, actual provider/model identity, launch-bound billing
route/evidence, and token inclusion semantics. A unique partial index for
non-null session IDs makes exact session updates idempotent without changing
attempt/generation ownership. Conflicting route or inclusion evidence refuses
the update. Legacy rows remain explicitly unattributed and are never joined to
an attempt by time.

## Audit timeline

`Hive::TaskActivity` is the sole append/idempotency facade for material task
activity. It binds each event to task, stage, attempt, and generation and
accepts only the closed `TaskJournal::ACTIVITY_KINDS` vocabulary. Mutation
paths may persist a precondition/expected-result operation receipt before the
domain change, then complete it with a result fingerprint. Bounded
reconciliation appends the missing event once when commitment is provable;
ambiguous outcomes become explicit `activity_gap` records.

Operation receipts survive retries, but reconciliation first verifies their
historical task, stage, numeric input epoch, ownership generation, and attempt
ID against the durable attempt store. A proven-uncommitted historical receipt
is aborted immutably; the successor attempt receives a distinct `:retry:N`
operation ID. Activity receipts describe work inside an already-selected input
generation and therefore never advance that generation by themselves.

`TaskWorkspace::Timeline` merges authoritative task-journal records with
bounded fail-soft `events.jsonl` observations. Journal/controller occurrence
time orders authoritative events. Provider/GitHub occurrence time orders an
external observation only when it is within five minutes of ingestion;
otherwise the external clock is display-only and ingestion time orders it.
Correlation/operation identity deduplicates presentation while retaining all
source references, and task-journal evidence wins cross-source duplicates.

Material events and operational noise have separate count/byte budgets. A raw
row cap is applied only after all material rows in the bounded byte window are
retained. Material cursors use the same physical source-window coordinates as
the readers and keep their occurrence boundary until every selected item from
that window has been returned; an older cursor therefore cannot skip unread or
late-ingested material. Event-stream fields are normalized to the closed
timeline schema before emission. Noise
with the same normalized identity is grouped only within 60 seconds. Signed,
opaque, task-bound cursors expose older material pages and at most 20 raw group
members. Material cursors retain bounded source-byte boundaries, so pagination
can seek earlier journal and event windows instead of filtering only the newest
suffix. Byte-budget omissions also issue an older cursor, while raw-group
cursors retain only the stable group identity and stay within their own decode
limit. A cursor cannot select a path, change a limit, or be replayed against
another task. Corrections append `supersedes_event_id`; history is never
rewritten.

## Dependency component

The dependency panel does not create graph state. It reuses the bounded
`DependencyAdmission::Context` already derived from status rows, builds a
reverse index, and walks only the target's connected ancestors and transitive
descendants. Scalar `depends_on` direction and admission state remain
authoritative.

Same-repository edges may display strict worktree base/head evidence as a
stacked Git relationship. Cross-project edges are labelled scheduling-only.
Each selected connected task receives its own bounded local publication
observation under the component's single two-second deadline, so ancestor and
descendant branch, base, head, and PR absence are not inferred from the root.
Numeric dependency targets use the same project/task-ID index as slug targets
instead of scanning every node per edge. Missing/inaccessible nodes, blocked
edges, cycles,
divergent expected versus observed OIDs, and every cap produce explicit partial
placeholders. Selection applies node/edge/depth/deadline limits before iterative
cycle analysis. A rooted spanning forest renders each node once;
additional/back/cyclic edges are cross-references. The semantic node/edge table
is always the complete bounded representation and remains authoritative when
the visual layer is ignored.

## Publication and artifacts

The publication panel is advisory and read-only. Local facts come from the
strict owned `worktree.yml`, bounded argv-form Git observations including
untracked files, an independently observed current base ref, at most 50 commit
summaries, and bounded `pr.md`. Page, JSON, Turbo morph, and publication GET
reads never call GitHub or run `git fetch`; the publication frame is morph-owned
so those cheap local facts refresh with the task. An explicit remote refresh
may replace a malformed cache entry while retaining the ordinary fail-soft
cache read boundary.

Remote state enters only through authenticated, CSRF-protected
`POST /tasks/:project/:slug/publication`. The controller validates the exact
registered repository, PR number, and expected head, performs at most one
allowlisted GitHub read, and writes a normalized/redacted advisory cache under:

```text
Hive::Paths.data_home/task-workspace/publication/<credential-hmac>/<project-fingerprint>/
```

Directories are owner-only `0700`; entries and locks are `0600`. Keys bind the
credential principal, project registration, canonical repository/PR, and
expected head. Reads distinguish cold, fresh, stale, failed, rate-limited,
expired, deleted, merged, and divergent observations. A failed refresh may
retain an older successful observation with both states visible. Refresh is
single-flight, has one ten-second total request deadline, and is limited by both
the local interval and a later GitHub `Retry-After` deadline.

Artifacts use descriptor-based no-follow reads over known workflow files, with
per-file and aggregate limits, binary/encoding detection, redaction, and stable
descriptor checks. Markdown still passes through the existing escape and
sanitization pipeline. The normal task page promotes the semantic primary
result to its own full-width work-product panel and keeps supporting artifacts
collapsed below it. A post-sanitization DOM pass adds deterministic,
collision-safe IDs to headings; an outline appears only at four or more `h2`
sections. Prose keeps a centered 82-character measure, generous
leading, and stepped headings. Direct code and wide tables scroll inside the
panel instead of widening the page at mobile widths or 400% zoom.

## Default limits

| Area | Default |
|---|---|
| Serialized workspace | 2 MiB |
| Artifacts | 512 KiB each; 2 MiB / 20 files total |
| Projection/journal | 512 KiB checkpoint; 1 MiB / 2,000-event suffix |
| Attempts | 100 task bindings; 32 predecessor fetches; 512 KiB |
| Timeline | 200 material; 100 noise groups; 512 KiB; 20 raw members |
| Dependency component | 32 projects; 10,000 rows; 100 nodes; 200 edges; depth 20; 4 MiB; 2 s |
| Local Git | 50 commits; 512 KiB; 10 s |
| GitHub | 100 checks; 64 KiB text; 256 KiB response; 10 s |
| Publication cache | 256 KiB entry; 32 MiB/principal; fresh 2 min; stale 24 h |

Every limit diagnostic names the exhausted cap and observed amount. A valid
task-projection checkpoint stores the projection plus bounded head/tail prefix
anchors and permits only bounded suffix validation and replay in a Web request;
it never stores, hashes, or replays the complete prefix on that request path.
The authoritative `TaskActivity` append boundary refreshes this optimization
after a durable write; refresh failure never revokes the successful activity,
but leaves Web mutations safely degraded until a later append or lifecycle
rebuild repairs the checkpoint. An exactly current checkpoint has an ordinary
empty suffix. Missing, changed,
torn, or over-limit checkpoint evidence degrades the workspace instead of
moving a full journal rebuild into HTTP.

## Decision and Web interaction

The decision posture is a read-only explanation over canonical facts:

1. unanswered required question -> `answer`;
2. passable marker -> `approve`;
3. enabled canonical recovery -> `retry`;
4. live attempt, scheduled retry, authorized hold, or daemon-owned dispatch ->
   `wait`;
5. stale/conflicting/unavailable evidence or an unhandled state ->
   `investigate`.

The existing `_primary_actions` forms remain the only controls. Every mutation
re-resolves and revalidates current state at its existing boundary, every
`source=archive` mutation is rejected by the shared task-controller boundary,
and all rendered task mutation controls fail closed whenever the workspace
status or current attempt/resource evidence is partial, stale, truncated,
conflicting, unavailable, or lacks the exact current attempt. Questions,
recovery lifecycle/action state, and diagnostic summary are normalized into
the same snapshot consumed by JSON and task HTML.

The v1 schema continues to define closed records for attempts, resources,
timeline entries, dependency nodes/edges, publication facts, and artifacts.
Normal HTML instead renders semantic v2 in this order: headline and guarded
actions, concise usage, primary work product, genuine diagnostic if any, then
only applicable supporting/change evidence. Raw attempt cards, provenance
receipts, `agent_start`/`agent_end`, session lifecycle, stage chronology, and
the newest-log tail are absent from the normal page; their v1/timeline/log
audit sources remain available.

Stable DOM identities and `data-workspace-disclosure-key` values let the
task-workspace Stimulus controller preserve focus, selection, scroll, usage,
supporting-artifact, change-evidence, and diagnostic-log disclosure state
across Turbo morphs. The correlated log frame loads only when its diagnostic
disclosure opens. Only changed semantic headline/action/result/usage material
enters the polite live region. Tables scroll inside named regions, identifiers
wrap, and layout reflows to one column without removing decisive state or
controls.

## Tests

- `test/unit/task_workspace/` pins v1/v2 schemas, bounded readers, semantic
  result/applicability/usage/diagnostic composition, provenance,
  attempts/resources, timeline, dependency, and publication/cache.
- `test/integration/task_command_test.rb` pins native semantic v2 output and
  the absence of absolute project paths.
- `test/unit/context_provenance_test.rb`, `task_activity_test.rb`,
  `task_projection_store_test.rb`, and `usage_db_test.rb` pin capture and
  persistence boundaries.
- `web/test/integration/tasks_test.rb` pins authenticated v1 compatibility,
  v2 workspace/HTML parity, workflow-aware primary/applicability behavior,
  exact log-reference selection, raw-lifecycle omission, and existing task
  actions.
- `web/test/system/task_workspace_test.rb` covers the semantic result/usage
  hierarchy, long-document anchors/outline, disclosure persistence, keyboard
  use, desktop/mobile reflow, and actual Chromium 400% zoom containment.

## Backlinks

- [[architecture]] · [[commands/web]] · [[modules/events]] · [[modules/attempts]]
- [[token-usage]] · [[modules/task_dependencies]] · [[modules/task_action]]
- [[testing]] · [[gaps]]
