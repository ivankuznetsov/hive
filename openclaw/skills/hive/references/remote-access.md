# Remote Hive operation

A context selects an installation, never a local checkout. Inspect with
`hive context list` and `hive context show NAME --json`; use `--context NAME`
for one invocation or `hive context use NAME` for the saved default. Context
configuration is local client administration. An operator can add a context
with `hive context add NAME --url https://HOST --token-stdin`; credentials belong
on stdin and must not appear in arguments, URLs, output, or task artifacts.

Use the remote read surfaces:

```sh
hive --context nas status --project demo --json
hive --context nas status --project demo --cursor HANDLE --json
hive --context nas task TASK --project demo --json
hive --context nas task TASK --project demo --log --json
hive --context nas task TASK --project demo --artifacts --json
```

Status returns at most 100 tasks per page and may shrink to fit its serialized
byte cap. Follow `data.continuation` explicitly with `--cursor`, preserving the
project filter. A changed task generation, stage or membership invalidates the
cursor; refresh on a stale response. Transient marker, lock and action changes
alone do not invalidate it. Per-project `state: unavailable` means the project
could not be loaded, rather than an empty successful inventory. Remote status
rejects `--operational`; local operational snapshots require `--context local`.

Remote task content selectors also include `--diff` and `--artifact ID`.
Use only opaque IDs from the manifest. `--output DESTINATION` writes a result
to an explicitly selected client path. Server paths are never client paths.

Scope names are independent: `read`, `create`, `act`, and `answer`. Do not assume
a writer can read. Creation requires an already registered project and installed
workflow ID. Put the context override before free-text idea prose:

```sh
hive --context nas new demo --idempotency-key KEY --json -- Investigate the backlog
```

For a routine supported action, fetch a fresh task action descriptor, inspect
it, and submit its exact action ID and opaque observation with
`hive --context nas act ACTION_ID TASK --project demo --observation TOKEN --idempotency-key KEY --json`.
An action whose effect is approval requires both `act` and `answer`. Force,
destination overrides, administration, arbitrary commands, and local workflow
verbs cannot run through a remote context. A refusal is a refusal; do not try
another route or switch to local without the operator's intent to target it.

Read questions with `hive --context nas answer TASK --project demo --json`.
Choose the returned slot's `handle`, then send the literal answer on stdin to
`hive --context nas answer TASK --project demo --binding HANDLE --idempotency-key KEY --json`.
Native folder bindings remain on the server. An answer-only token needs a
handle supplied by an authorized reader. Refresh a stale handle; an unknown
or foreign handle returns not found. Read handles have bounded retention and
may expire under registry pressure.

Approval uses `hive --context nas approve TASK --project demo --from STAGE --generation GENERATION --idempotency-key KEY --json`.
Use the full stage and approval generation from fresh task detail. A reader may
omit these and let the CLI resolve them; an answer-only token must supply both.
Before submission, stderr prints the resolved stage, generation and key for
replay. Keep these exact inputs if the response is lost and the task advances.

Every mutation prints and flushes its context, installation, authority, target
and retry key to stderr. JSON stdout remains one document. A disconnect means
unknown submission outcome. Replay identical input with the same key against
the same installation; a new key could duplicate the effect. Recover the
acknowledgement, then query
`hive --context nas operation OPERATION_ID --project demo --json`.
An acknowledgement proves durable admission; queued, running, succeeded,
failed, unresolved and expired operation states describe later progress.
Refused admission is never successful acceptance. Revoking a token blocks
future calls but does not cancel already accepted daemon work.
