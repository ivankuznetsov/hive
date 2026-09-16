# Daily changes digest

Use this route for the operator's readable summary of recent merged changes.
Hive uses PRDigest to collect PR descriptions and relevant diffs, generates one
text document with its configured agent, and saves it for Web, CLI and Telegram.
The independent PRDigest product continues to work without Hive.

## Read the saved document

```bash
hive digest --json
hive digest --date YYYY-MM-DD --json
```

The default selects a current preview if present, otherwise the most recent
saved document. Inspect `local_date`; do not assume that default means today.
Automatic generation normally writes yesterday's digest. For a requested date,
use an explicit calendar date in the configured timezone. `previous_date` and
`next_date` navigate saved documents, not necessarily adjacent calendar days.

Read `document` as the human-facing result. It describes concrete changes and
links them to source PRs. `items` are supporting references, not a substitute
workflow-event report. A document covers its complete recorded repository scope;
legacy project-filter arguments do not generate separate documents. To discuss
one project, quote the relevant section while keeping the original date/scope.

Check `reader_status` first: `ok`, `missing`, or `pruned`. A missing document does
not mean historical GitHub changes are unavailable. A pruned document must not
be reconstructed. `content: empty` means collection found no merged PRs, not
that the project's other work stopped. An open document is a preview; failed
refreshes leave the last saved text intact.

## Explicit mutations

Only when requested by the operator:

```bash
hive digest refresh --json
hive digest refresh --date YYYY-MM-DD --json
hive digest send --date YYYY-MM-DD --json
```

Refresh without a date generates yesterday's document. Older dates can query
GitHub evidence from before local setup; today can be previewed. Sending uses
the saved closed document and existing Telegram settings. Short documents are
sent as text; longer ones are complete UTF-8 text attachments. Never send or
retry delivery merely to answer a read question.

Reads never call an agent, GitHub, PRDigest, refresh, or Telegram. Do not replace
a missing document with a workflow-event dump, status scan, or log reconstruction.
`hive answer-digest` is the unrelated pending-question delivery command.
For current tasks needing action use the task/status routes, not digest prose.

Reading or operating a digest does not authorize a release, version choice,
publication, or deployment; these require explicit operator direction.
