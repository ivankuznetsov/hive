---
title: Hive::Prdigest
type: module
source: lib/hive/prdigest.rb
---

# `Hive::Prdigest`

`Hive::Prdigest` is the complete Hive-side boundary for merged-PR digests. It is
an adapter, not a second digest engine.

## Public surface

| Component | Responsibility |
|---|---|
| `Hive::Prdigest.run(date:, dry_run:, repos:, **options)` | Convenience entry point that constructs `Runner` and returns its result. |
| `Hive::Prdigest::Runner` | Resolves registry scope, credentials, executable, private YAML, array argv, child process, and result validation. |
| `Hive::Prdigest::Registry` | Converts every registered project to a strict `github.com/owner/name`, deduplicates case-insensitively, and enforces filter subset. |
| `Hive::Prdigest::Result` | Holds the parsed PRDigest payload, exact exit, repository scope, and argv. |
| `Hive::Prdigest::InvocationError` | Carries a nonzero PRDigest payload and preserves its exact exit status through Hive's top-level rescue. |
| `Hive::Prdigest.failure_payload` | Produces the small PRDigest-compatible envelope used only when Hive fails before a child result exists. |

There is no live `Hive::Digest` namespace. This also removes its collision with
Ruby's stdlib `Digest`.

## Trust boundaries

The adapter accepts repository identities only from Hive's persisted registry
or the registered checkout's current Git origin. A requested `--repo` must be a
subset of that set. It never performs organization discovery or accepts an
arbitrary repository from command input.

The temporary config is owner-only, fsynced before execution, and automatically
removed. It contains chat/repository identifiers and token environment names,
but never token values. `Open3.capture3` receives an argv array, so repository
names and config paths do not cross a shell parser.

The child must return JSON with `schema=prdigest-result`,
`schema_version=1`, a string status, and an object-or-null error. A zero exit
must agree with `success`/`dry_run`; contradictory or malformed output is a Hive
internal error. Hive does not reinterpret PRDigest's delivery decision.

## Scheduling helpers

`Hive::LondonDate` exists only so the daemon and a date-less manual invocation
select the correct completed London calendar day. It does not calculate GitHub
query windows; PRDigest owns those. `Hive::LocalDateWindow` is the separate
host-local helper retained for the unrelated pending-answer digest.

## Removed implementation

The former collector, repository evidence model, agent changelog generator,
stats aggregator, MarkdownV2 renderer, sender, delivery checkpoint store,
digest-specific `Hive::Gh` REST methods, prompt template, and Hive result schemas
were deleted together. Keeping any of them live would create policy drift and
make future delivery fixes land in two places.

See [[commands/digest]], [[modules/daemon]], [[modules/config]], and
[[dependencies]].
