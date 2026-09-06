# Daily activity digest

Use this route when the operator asks what happened today, yesterday, or on a
persisted Hive day, including one project's activity, outstanding attention,
partial history, or late amendments. The canonical source is the persisted
global digest, not current status, logs, task-folder reconstruction, GitHub, or
PRDigest.

## Read-only routing

For the current persisted interval:

```bash
hive digest --json
```

For an explicit stored label or one project:

```bash
hive digest --date YYYY-MM-DD --json
hive digest --date YYYY-MM-DD --project PROJECT --json
```

Use these scenario routes exactly:

| Operator request | Read sequence |
| --- | --- |
| What happened today? | `hive digest --json` |
| What happened yesterday? | `hive digest --json`, then `hive digest --date PREVIOUS_DATE --json` using the returned `previous_date` |
| What happened in one project today? | `hive digest --project PROJECT --json` |
| Is a persisted day partial? | `hive digest --date YYYY-MM-DD --json` |
| Show a persisted day's late amendments. | `hive digest --date YYYY-MM-DD --json` |

None of these read sequences begins with operational status. They do not read
logs, refresh or send the digest, open a browser, invoke Telegram, or call the
pending-answer digest.

To answer "yesterday", first read the current digest and follow its
`previous_date`, then issue the explicit dated read. Never subtract a calendar
day from `local_date`: after a time-zone cutover the labels are monotonic record
identities and may differ from wall-clock dates.

Project filtering is a view over the same global `record_id`. It retains global
gaps and must not be described as a separate project-owned history.

## Interpret the contract

Check these dimensions independently before summarizing:

- `reader_status`: `ok`, `missing`, or `pruned`;
- `lifecycle`: `open`, `closed`, `missing`, or `pruned` in the public envelope;
- `completeness`: `complete`, `partial`, or `unknown` for absent history;
- `content`: `empty`, `non_empty`, or `unknown`;
- `stale`, `last_materialized_at`, `gaps`, and `coverage_started_at`; and
- `amendments`, including recovered gaps and late facts.

A complete `empty` day is an observed no-activity result. A partial record with
no known items is `unknown`, not empty. Say which scoped gaps constrain the
answer. `missing` before coverage means V1 has no backfill; `pruned` means a
tombstone exists and agents must not reconstruct the removed projection.

Use `previous_date` / `next_date` for adjacent-day navigation. Preserve the
returned `record_id`, `local_date`, persisted `time_zone`, and boundaries in the
report. When a project has been removed or replaced, its stored label can remain
historical and its old task URL may intentionally be absent.

## Native action handoff

Digest waiting items expose identity, stage/state, age, and at most a native
task URL. They never contain the question, answer, prompt, or opaque binding.
If the operator explicitly asks to answer, follow the native task link and
obtain a fresh inventory with:

```bash
hive answer TASK --project PROJECT --json
```

Then follow [brainstorm-answering.md](brainstorm-answering.md). Do not infer an
answer from digest prose or retain a stale binding.

## Prohibited substitutions and effects

- Never reconstruct a daily record from `hive status`, task folders, logs,
  GitHub, or PRDigest.
- Never invoke `hive digest refresh` unless the operator explicitly requests
  materialization or recovery; reads remain pure even when stale or missing.
- Never invoke `hive digest send`, Telegram, or a delivery retry while answering
  a read question.
- Never use `hive digest --open-web` in machine mode; consume `web_url` only as
  a human handoff.
- Never use the sendful `hive answer-digest` as a daily activity read.
- Never create a polling loop. A requested ongoing current-state watch belongs
  to [status-and-watch.md](status-and-watch.md), not this historical projection.
