---
title: Task workspace projection
type: module
source: lib/hive/task_workspace.rb, lib/hive/task_workspace/, lib/hive/context_provenance.rb, lib/hive/task_activity.rb, schemas/hive-task-workspace.v1.json, schemas/hive-context-receipt.v1.json, web/app/controllers/tasks/, web/app/views/tasks/
created: 2026-08-12
updated: 2026-08-14
tags: [task, web, projection, provenance, attempts, timeline, dependencies, publication]
---

**TLDR**: `Hive::TaskWorkspace::Builder` turns one already-resolved task into
the bounded, read-only `hive-task-workspace` v1 document used by both the task
HTML and authenticated JSON on the existing task route. The projection makes
missing, stale, partial, conflicting, and unavailable evidence explicit. It
does not replace `hive-status` v7, own task lifecycle state, scan the fleet,
contact GitHub, or create a second action protocol.

## Boundary and route

`Tasks::BaseController` resolves exactly one registered project and slug
through `Hive::Web::TaskTargetResolver`. It passes that native task, its
already-projected status row, the broadcaster's existing dependency context,
and injected bounded readers to `Hive::TaskWorkspace::Builder`.

The existing route is content negotiated:

```text
GET /tasks/:project/:slug          # HTML workspace
GET /tasks/:project/:slug.json     # hive-task-workspace v1
GET /tasks/:project/:slug/timeline # signed older/raw cursor page
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

## Document shape and evidence states

The top-level document contains exact task identity, generation time, status
freshness, normalized operator state, one decision posture, and seven panel
envelopes. Operator state owns the bounded open-question bindings, recovery
lifecycle/action facts, and diagnostic summary used by both HTML and JSON:

```text
provenance · attempts · resources · timeline · dependencies · publication · artifacts
```

Every panel has `state`, `records`, `diagnostics`, and `truncated`. The closed
state vocabulary is `current`, `stale`, `partial`, `missing`, `conflicting`,
`unavailable`, `estimated`, `exhausted`, and `retry-after`. Field records add a
symbolic source, safe task-relative evidence reference, observation time,
quality label, retained conflicts, and truncation flag.

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

## Attempts, sessions, and resources

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

`UsageDb` schema v2 adds nullable attempt/session/generation/source columns and
a unique partial index for non-null session IDs. Exact session upserts are
idempotent and cannot change attempt/generation ownership. Legacy rows remain
queryable as explicitly unattributed and are never joined to an attempt by
time.

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
sanitization pipeline. Rendered Markdown uses a centered 82-character prose
measure, full-size body type with generous leading, and visibly stepped section
headings so long plans and reports remain scannable. Direct code blocks and wide
tables can use the wider document panel on desktop; they keep their intrinsic
layout but scroll inside the panel instead of widening the task page at narrow
viewports. Diff and log keep their existing independent bounded readers.

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

The versioned workspace schema defines closed, typed records for attempts,
resources, timeline entries, dependency nodes/edges, publication facts, and
artifacts rather than accepting arbitrary panel mappings. The task page renders
the decision summary before lower evidence, then
attempt/resource, provenance, timeline, dependency, change/publication,
artifact/media, and log panels. Stable DOM identities and the task-workspace
Stimulus controller preserve focus, exact selection range, scroll, and
disclosure choices across pushed morphs and cancel queued scroll restoration
when disconnected. Diff and log frames are permanent
owners; cheap local publication facts remain morph-owned so branch, head, push,
and dirty state update with the task. Timeline drill-down uses its own
task-stable permanent frame and links back to the current timeline, so status
morphs cannot discard an operator's inspection. Only a changed
decision/status/resource signature enters the polite live
region. Permanent frame identities include project and task identity, and the
diff live region contains only its concise state summary rather than patch
content. Tables scroll inside the page, identifiers wrap, and the layout
reflows to one column at narrow widths without removing decisive state or
controls.

## Tests

- `test/unit/task_workspace/` pins bounded readers, schema, provenance,
  attempts/resources, timeline, dependency, publication/cache, and composition.
- `test/unit/context_provenance_test.rb`, `task_activity_test.rb`,
  `task_projection_store_test.rb`, and `usage_db_test.rb` pin capture and
  persistence boundaries.
- `web/test/integration/tasks_test.rb` pins authentication, HTML/JSON parity,
  per-panel degradation, cursor and publication refresh boundaries, and old
  task/action routes.
- `web/test/system/task_workspace_test.rb` covers wide/desktop/375 reflow and
  actual Chromium 400% device-scale emulation at 320 effective CSS pixels,
  keyboard use, target sizing, semantic dependency fallback, permanent-frame
  isolation, exact selection preservation, and material-only announcements.

## Backlinks

- [[architecture]] · [[commands/web]] · [[modules/events]] · [[modules/attempts]]
- [[token-usage]] · [[modules/task_dependencies]] · [[modules/task_action]]
- [[testing]] · [[gaps]]
