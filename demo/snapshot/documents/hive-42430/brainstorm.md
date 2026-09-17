## Round 1
### Q1. Who is the primary user of this feature workspace, and what concrete task-page workflow is currently slow, confusing, or error-prone for them?
### A1.
The primary user is a Hive operator supervising durable autonomous work. Today they must correlate task artifacts, status JSON, logs, dependency tasks, provider/model attempts, and GitHub state to decide whether a task is trustworthy and what needs attention. The workspace should make that decision possible from one task page without hiding the filesystem-backed source of truth.

### Q2. Of repository provenance, active-agent sessions, the decision timeline, dependency/stacked-flow visualization, and publish/PR preview, which are required for the smallest coherent first release, and which may be deferred?
### A2.
The smallest coherent release includes active/current attempt identity and budget status, a unified decision/retry timeline, dependency/stack visualization, and read-only PR/publish preview. Repository/LLM Wiki provenance should ship at least as a compact summary with links to the underlying artifacts; richer context inspection may follow. Do not defer accurate unavailable/stale/conflict states, responsive accessibility, or API compatibility.

### Q3. What representative end-to-end scenario should the workspace make easy, from opening a task through deciding whether its context, execution, dependencies, and publication state are trustworthy?
### A3.
An operator opens a planning/executing task, verifies the repository HEAD and wiki/context revision used, sees the current provider/model/attempt and configured versus observed budget, reviews questions/approvals/retries in order, understands upstream/downstream stack state, inspects the bounded diff and PR/check preview, and can identify whether to wait, answer, approve, retry, or investigate using existing authorized actions.

### Q4. When the repository HEAD or LLM Wiki has changed since brainstorm, plan, or execute ran, which historical and current facts must remain visible, and what should the user see when provenance is missing, stale, partial, or contradictory?
### A4.
Keep the exact historical repository commit, wiki revision/index generation, selected context references, and capture time for each stage/attempt, alongside current HEAD/wiki freshness. Never rewrite historical provenance to the current state. Show explicit `current`, `stale`, `partial`, `missing`, or `conflicting` states with source links and timestamps; contradictions remain visible and the authoritative filesystem/task evidence wins according to existing projection rules.

### Q5. How should the workspace represent concurrent agents, retries, recovered attempts, and completed sessions, especially when provider/model identity or health data is unavailable or conflicts across artifacts?
### A5.
Show one clearly designated current attempt plus prior attempts grouped by stage and generation. For each, show role, provider, requested/actual model, effort, start/end, health/outcome, retry/recovery relationship, and budget/usage state when available. Concurrent agents appear separately rather than being collapsed. Missing identity is `unavailable`, not inferred; conflicting evidence is flagged with provenance, and completed/recovered attempts remain immutable audit history without double-counting usage.

### Q6. Which events are material enough for the unified timeline, how should noisy or repeated events be grouped, and what ordering, provenance, redaction, or correction behavior is required for ambiguous records?
### A6.
Include stage transitions, agent starts/ends, questions and answers, approvals/rejections, retries/recovery, relevant holds/limits, plan/context revisions, commits/pushes, PR/check/merge transitions, and operator actions. Group repeated heartbeats, identical transient failures, and noisy polling into summaries with expandable raw evidence. Order by authoritative event time with ingestion time as fallback; show source/provenance, apply existing redaction rules, and append corrections/supersession records rather than silently rewriting history.

### Q7. What dependency graph boundary should the stacked-flow view cover, and what must it communicate for partial graphs, missing tasks, cycles, blocked chains, base/head divergence, and tasks without PRs?
### A7.
Cover the connected dependency component around the current task: ancestors required for its base, descendants directly or transitively stacked on it, and their publication state, with a bounded/collapsible view for large graphs. Communicate missing/inaccessible tasks, partial data, cycles, blocked edges, expected versus actual base/head OIDs, divergence, and tasks without branches or PRs. The graph is explanatory and uses Hive's existing dependency/task state; it does not create a new roadmap model.

### Q8. Is the publish/PR area strictly a read-only preview, or may it expose existing authorized actions; in either case, what must happen when branch identity, commits, checks, or remote publication state are absent, stale, or failed?
### A8.
Start as a read-only preview, while linking or embedding only existing authorization-gated task actions already supported by Hive; do not invent a general PR client. Show repository/branch, expected and observed commits, push state, PR URL/status, checks, review/merge state, and freshness timestamps. Missing or stale identity must disable misleading actions and display the exact unavailable/failed/diverged condition with the existing recovery path where one is already authorized.

### Q9. Which existing task-page behaviors and JSON/API consumers are compatibility-critical, and what concrete desktop, mobile, keyboard, screen-reader, loading, and bounded-read acceptance examples must pass?
### A9.
Preserve current routes, task actions, artifact/log/diff behavior, websocket/live updates, JSON schema compatibility, and existing API consumers; additions should be additive or versioned. Acceptance includes representative desktop and narrow mobile layouts, keyboard-only traversal, logical focus and headings, screen-reader names/status announcements, non-color-only states, accessible graph/table alternative, skeleton/error/empty states, bounded artifact/log/diff reads, and no unbounded repository or GitHub fetches. Target WCAG 2.2 AA for new UI.

### Q10. What outcomes would prove this workspace is successful, and what explicit non-goals should prevent it from becoming a second task lifecycle, feature database, repository browser, agent console, or general-purpose PR client?
### A10.
Success means an operator can correctly identify current agent/model/budget, stale context, pending decisions, dependency blockers, and publication state from one page with materially fewer cross-tool lookups; automated tests should cover those judgments and compatibility contracts. Non-goals: a second lifecycle or database, repository browser, raw interactive agent console, general-purpose GitHub client, replacement for task artifacts/logs, exact billing ledger, or a new roadmap abstraction.
## Requirements

### Actor

- A Hive operator supervising durable autonomous work needs one trustworthy task workspace for deciding whether to wait, answer, approve, retry, or investigate, while retaining direct links to the filesystem-backed evidence.
- The workspace extends the existing task page and its authorized actions; it does not introduce a second lifecycle, feature database, roadmap, repository browser, interactive agent console, billing ledger, or general-purpose GitHub client.

### Flow

- On opening a task, the operator sees the historical repository HEAD and LLM Wiki/context snapshot used by each stage or attempt, including revision, freshness, selected references or query results, inclusion rationale, capture time, and links to source artifacts; current state is shown separately and never rewrites history.
- The current attempt is prominent, while concurrent and prior attempts remain separate immutable records grouped by stage and generation. Each record shows role, provider, requested and actual model, reasoning effort, stage/phase, start/end, attempt and retry/recovery identity, health/outcome, timeout, and live/completed state without inferring unavailable values.
- Budget is first-class and attributed by provider, model, attempt, and stage: show the configured per-stage or per-spawn guard, source and scope, observed usage, and honestly computable remaining headroom. Distinguish monetary/API budgets, subscription capacity, token or launch quotas, and timeouts; never present a subscription-backed `budget_usd` guard as an extra charge, and avoid double-counting historical attempts in current totals.
- A chronological timeline combines material stage transitions, agent starts/ends, questions and answers, approvals/rejections, retries/recovery, holds and limits, plan/context revisions, commits/pushes, PR/check/merge transitions, and operator actions. Order by authoritative event time with ingestion time as fallback; summarize repeated noise with expandable evidence and append corrections or supersessions instead of rewriting history.
- The dependency view covers the bounded, collapsible connected component around the task: required ancestors, transitive descendants stacked on it, blocked-by edges, expected and actual base/head OIDs, divergence, current task, and branch/PR publication state. It explains partial or inaccessible nodes, cycles, blocked chains, and tasks without branches or PRs using existing Hive dependency state.
- Beside the bounded diff, a read-only publish/PR preview shows repository, branch/base/head identity, expected and observed commits, commit summary, push state, PR title/body and URL/status, checks, review/merge state, publication state, and freshness. It may expose only existing authorization-gated Hive actions; stale, absent, failed, or divergent identity disables misleading actions and points to an existing recovery path when available.
- All panels use bounded, authorization-safe, filesystem-backed task-state and usage projections. Contract changes are additive or explicitly versioned, preserve current routes, task actions, artifacts/logs/diffs, live updates, recovery semantics, JSON compatibility, and existing API consumers, and expose `current`, `stale`, `partial`, `missing`, `conflicting`, `unavailable`, `estimated`, `exhausted`, and `retry-after` states where applicable.

### Acceptance examples

- From one page, an operator can correctly identify the current provider, actual model, attempt, stage, health, configured budget source/scope, observed usage, honest headroom, timeout or quota condition, and whether any value is unavailable, estimated, stale, exhausted, or awaiting retry.
- When HEAD or wiki/context changes after brainstorm, plan, or execute, the page preserves the exact captured commit and revision for each stage/attempt, shows current freshness separately, flags partial or conflicting evidence with provenance and timestamps, and follows existing projection precedence.
- For retries, recovery, and concurrent agents, the page shows distinct linked attempts and immutable outcomes, keeps live and completed states clear, and reports aggregate usage without counting the current attempt twice.
- For a blocked or divergent stack, the operator can trace ancestors and descendants, identify the blocking edge and expected-versus-actual base/head ordering, see missing/cyclic/partial graph conditions, and follow available task or PR links without creating new dependency state.
- On absent, stale, failed, or unpublished Git state, the preview states the exact condition, avoids fabricated PR/check information, disables misleading actions, and preserves bounded diff and artifact access.
- Representative desktop and narrow-mobile browser coverage demonstrates responsive layout, keyboard-only traversal, logical headings and focus, screen-reader names and status announcements, non-color-only state cues, an accessible graph/table alternative, and clear loading, skeleton, empty, degraded, and error states to WCAG 2.2 AA for new UI.
- Automated contract, model/controller/view, live-update, and browser tests cover the operator judgments above, bounded artifact/log/diff and external reads, redaction and authorization behavior, backward-compatible JSON/API behavior, and documentation of new versioned fields and degraded states.

<!-- COMPLETE -->
