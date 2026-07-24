---
title: Hive::Digest
type: module
source: lib/hive/digest.rb, lib/hive/digest/, templates/digest_prompt.md.erb
created: 2026-06-14
updated: 2026-07-24
tags: [digest, github, telegram, module]
---

**TLDR**: `Hive::Digest` is one fail-closed pipeline for a complete daily
GitHub PR changelist. It resolves registered repositories, collects every PR
merged in a Europe/London day with required body/diff/file evidence, validates
an exhaustive generated changelog, computes honest optional statistics,
renders MarkdownV2, and dry-runs or sends through Telegram. It has no edge to
Hive task, stage, completion, ship-time, matcher, or pairing state.

## API Map

| API | Purpose |
|---|---|
| `Hive::Digest.run(date: nil, dry_run: false, repos: [], cfg: nil, clock: -> { Time.now }, resolver: nil, collector: nil, generator: nil, stats: nil, renderer: Renderer, sender: nil)` | Canonical orchestration. Returns `Result(status:, date:, dry_run:, resolved_repository_count:, collected_repository_count:, projects:, pr_count:, stats:, warnings:, message:, delivery:)`. Raises before rendering/sending on zero scope, total collection failure, or invalid generated coverage. |
| `Digest::RepoResolver#resolve(repos:)` | Resolves configured registered projects to `RepositoryTarget` values that retain project path, canonical repository, and GitHub host. Applies case-insensitive `--repo` filters and returns discovery warnings. |
| `Digest::LondonWindow` | Owns digest-only Europe/London default date, parsing, membership, and UTC bounds using `tzinfo`. `Digest::Window` remains separate for AnswerDigest's host-local contract. |
| `Digest::Collector#for_date(date, targets:)` | Collects repository metadata and complete qualifying PR body/raw-diff/file evidence into repository-atomic `CollectionReport` outcomes. |
| `Digest::ChangelogGenerator#generate(repositories, date:)` | Builds private evidence chunks, runs one bounded agent, validates the fact ledger and exact project/PR/material-fact coverage, redacts generated text, and returns `Changelog`. |
| `Digest::Stats#for_repositories(repositories)` | Produces per-repository and overall `Aggregate` values with independently optional additions, deletions, and commits plus incomplete-statistics warnings. |
| `Digest::Renderer.render(changelog:, date:, stats:, warnings:)` | Produces deterministic MarkdownV2 project sections, PR links/bullets, warnings, and divider/middle-dot statistics. |
| `Digest::Sender#preflight!` / `#deliver(text, dry_run:, digest_date:)` | Validates Telegram credentials before paid generation, or returns a credential-free dry-run. Real sends persist one stable redacted payload and exact MarkdownV2-safe chunks per date, then resume at the durable next-unsent chunk. |
| `Digest::DeliveryCheckpointStore` | Owns the owner-private, atomically written `<state_home>/digest-deliveries/YYYY-MM-DD.json` delivery transaction, including payload checksum, exact chunks, next-unsent cursor, completion, and a parked permanent failure. |

## Data And Outcome Model

`RepositoryTarget` binds a registered project name/path to a validated
`owner/name` and explicit GitHub host. `RepositoryCollection` contains metadata
and every qualifying `PullRequest` for one successfully collected repository.
`CollectionReport` keeps successful repositories, failures, and warnings
separate, so an empty successful query cannot be confused with an outage.

`PullRequest` always has number, URL, title, merge timestamp, redacted body,
redacted raw diff, and complete file identities. Additions, deletions, and
commits are independently optional. `Warning` carries a stable kind/message
and optional repository, PR number, and metric list for both human and JSON
output.

`Result#status` is only:

- `:empty` when at least one repository succeeded and the represented PR count
  is zero;
- `:sent` when at least one PR is represented (including a dry-run preview).

There is no `failed_notice`. Failure to establish complete collection or
generated coverage raises and sends nothing, allowing the daemon to retry the
date.

## Pipeline

```text
registered project Git origins
  -> RepoResolver (targets + discovery warnings)
  -> LondonWindow (exact UTC bounds for one London date)
  -> Collector (repository metadata + complete PR body/diff/files)
  -> ChangelogGenerator (evidence IDs -> fact ledger -> project/PR bullets)
  -> Stats (known totals + explicit incomplete warnings)
  -> Renderer (deterministic MarkdownV2)
  -> Sender (dry-run or durable Telegram chunk transaction)
```

Resolution fails closed when no registered GitHub target survives. Collection
is atomic per repository. Total repository failure raises `CollectionError`;
partial failure keeps the complete successful repositories and warnings. A
successful all-empty report skips `ChangelogGenerator` but still passes through
statistics, rendering, and delivery.

Real sends load the environment file, collect GitHub evidence, then call
`Sender#preflight!` before launching the paid generator. This preserves the
ability to report GitHub collection errors without Telegram config while still
avoiding agent spend when the recipient or token is missing. Dry-run bypasses
Telegram credential lookup entirely.

## GitHub Evidence Contract

`Hive::Gh.digest_merged_pr_candidates` paginates
`repos/{owner}/{repo}/pulls?state=closed&sort=updated&direction=desc&per_page=100`
through explicit-host `gh api` calls. It validates monotonic `updated_at`,
de-duplicates repository/PR identity, and stops only after an empty page or a
page whose remaining rows all predate the London window. Because live
page-number traversal can shift while a PR is updated, Hive accepts only two
consecutive identical complete snapshots and fails closed when bounded retries
cannot reach stability. Filtering by validated `merged_at` happens afterward;
ordinary closed-but-unmerged rows are excluded.

Each qualifying PR is hydrated through:

- `digest_pr_detail` for canonical body, merge identity, changed-file count,
  and optional metrics;
- `digest_pr_diff_to_file` with `Accept: application/vnd.github.diff`, streaming
  stdout directly into a private file;
- paginated `digest_pr_files` for authoritative file identities.

The collector rejects transport/JSON errors, inconsistent identities or merge
times, incomplete pagination, changed-file mismatches, a missing nonempty diff,
scratch/checksum/redaction failures, and fixed evidence-ceiling breaches. It
decodes Git C-quoted paths and validates unquoted paths with spaces against the
authoritative files response. Remaining per-PR, per-repository, and per-digest
byte budgets are passed into the streaming `gh` capture so oversized stdout is
terminated before full materialization. One bad qualifying PR fails its
repository instead of disappearing from the changelist.

Scratch directories and files use modes 0700/0600. Raw body/diff bytes exist
only long enough to construct and verify redacted file-backed evidence, then
are removed. Redacted body/diff handles stream through validation and chunk
materialization without aggregate JSON/string copies. `Digest.run` removes the
entire per-collection scratch run on success and every failure path.

## Generation And Trust Boundaries

The private manifest uses `host/owner/name` for internal repository identity
and gives every body section and diff hunk/file marker a host-qualified stable
evidence ID outside nonce-fenced untrusted repository text. One agent
invocation must return:

1. facts covering every evidence ID exactly once, each classified as material
   or accompanied by a concrete no-user-facing-change rationale;
2. exactly one significance sentence per repository and one row per PR;
3. one or more concrete bullets per PR, collectively citing every material
   fact for that PR. All-no-user-facing-change PRs cite their rationale facts;
   a zero-evidence PR uses one no-user-facing-change fact with no evidence IDs.

Validation accepts model row reordering but rejects identity drift, duplicates,
unknowns, omissions, blanks, title repetition, zero bullets, uncovered
evidence, and uncovered material facts. Failures retain only safe run/log
breadcrumbs. Successful diagnostics retain a redacted ledger and checksums,
not raw evidence, prompt payloads, or provider stream output. Secret-shaped
model fact IDs are replaced with local canonical IDs and all bullet references
are rewritten before retention. The production agent runs under a
private-directory-only Claude runtime policy with isolated settings, MCP, and
child environment and without shell or network tools. Its policy/settings live
in a controller-owned sibling outside the writable agent directory. After each
run Hive deletes that writable directory in full, including unknown files the
agent created; a successful run retains only controller-written `ledger.json`.
A configured provider that cannot enforce this boundary fails closed.

`Hive::SecretPatterns` scans repository metadata/body/diff before agent
provider egress and scans generated significance/bullets before rendering.
Recognized values become typed placeholders, and warnings contain pattern
counts/kinds without snippets. Unsafe or unverifiable redaction fails the
repository or generation. Immediately before a real Telegram send, `Sender`
runs and verifies a second `SecretPatterns` pass over rendered text; dry-run
keeps its text local.

## Statistics And Rendering

For each metric, `MetricTotal` records the measured subtotal, known contributor
count, and total contributor count. The value is absent exactly when no
contributor is known. A known subset is `partial?`; measured zero remains zero.
The same rules apply per project and overall, with a scoped warning for each PR
and missing metric.

The renderer owns all deterministic evidence: order, repository headings,
project/PR counts, PR numbers and links, warnings, and metric labels. Generated
text supplies only project significance and bullets and is always escaped as
untrusted MarkdownV2 text. Long plain-text lines are split on grapheme-safe
boundaries before Telegram performs message chunking. The Telegram adapter
then scans MarkdownV2 escapes, links, bold/italic/underline/strike/spoiler,
inline code, preformatted blocks, custom emoji labels, and blockquote markers,
choosing only a boundary at which every entity is closed. Every resulting
message is therefore independently parseable and no escape or entity is
hard-cut. An entity that cannot fit within Telegram's 4096-character limit
fails before any API call. The footer retains:

```text
──────────
Lines +A/-D · PRs P · Commits C
```

Partial known values carry `(partial)`. Entirely unknown metrics are omitted;
an empty digest shows only `PRs 0`.

## Delivery Transaction

Before the first real Telegram call, `Sender` performs its final secret
redaction, computes the exact MarkdownV2-aware chunks, and atomically persists
the stable payload and `next_chunk: 0` under
`<state_home>/digest-deliveries/YYYY-MM-DD.json`. The directory and files are
owner-only (0700/0600), and one per-date lock serializes concurrent attempts.
After each accepted Telegram response, the sender atomically advances
`next_chunk`. A safe process retry loads that same payload and sends only the
remaining suffix; newly generated prose cannot replace it, and chunks already
recorded as accepted are not replayed. A completed checkpoint also makes a
retry a no-op, covering a crash after complete delivery but before the daemon
advances its date cursor.

Telegram HTTP 400 `can't parse entities` responses are treated as
deterministic. For the one failed chunk, Hive makes one bounded retry using a
locally converted equivalent HTML representation. If Telegram accepts it,
delivery advances normally. If Telegram rejects the fallback as malformed, or
the locally rendered MarkdownV2 cannot be safely split, the checkpoint records
a permanent failure and the command exits nonzero. Every send first persists an
`in_flight` unit. A structured Telegram rejection clears that marker and can
retry safely from the same next-unsent chunk; an unknown transport outcome or
a post-send checkpoint failure leaves it parked so Hive cannot blindly replay
a message Telegram may already have accepted. Failure logs retain
`accepted_chunks`, `total_chunks`, and `failed_chunk`, with fallback outcome
fields when applicable.

## JSON And Daemon Contract

`Hive::Commands::Digest` serializes only `hive-digest` v2. Project and PR rows
mirror the rendered changelist; unknown numeric properties are omitted.
`schemas/hive-digest.v1.json` is retained only as immutable history, and the
former merged-PR schema/registry identity has been removed.

`Hive::Daemon::DigestScheduler` uses `LondonWindow`, persists
`last_digested_date`, and emits the canonical bare command
`hive digest --date D --json`. Exit 0 advances empty, full, and honest partial
success. Retryable total-collection, generation, pre-send cursor-write, or
definitively rejected Telegram failure leaves the day owed under bounded
60/300/900-second backoff. A typed permanent or ambiguous delivery/checkpoint
error leaves the cursor unchanged but persists `blocked_date` and its error
details, preventing deterministic redispatch or a blind replay until an
operator remediates that date. First run, oldest-first catch-up, cap, one global
slot, SIGHUP reconfiguration, dry-run pseudo-child completion, and the
3600-second child timeout are unchanged.

## Tests

- `test/unit/digest/london_window_test.rb` and `repo_resolver_test.rb`
- `test/unit/gh_digest_test.rb`, `digest/collector_test.rb`, and
  `digest/stats_test.rb`
- `test/unit/digest/changelog_generator_test.rb`
- `test/unit/digest/run_test.rb`, `renderer_test.rb`, `sender_test.rb`, and
  `delivery_checkpoint_store_test.rb`
- `test/unit/commands/digest_test.rb`, schema/CLI integration tests, and
  `test/unit/daemon/digest_scheduler_test.rb`

## Backlinks

- [[commands/digest]]
- [[commands]]
- [[commands/daemon]]
- [[modules/config]]
- [[modules/daemon]]
- [[modules/gh]]
- [[modules/secret_patterns]]
