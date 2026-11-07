---
title: Remote CLI access and incident response
type: guide
source: lib/hive/remote/, lib/hive/connection_contexts.rb, lib/hive/commands/token.rb, lib/hive/commands/daemon.rb, lib/hive/commands/web.rb, web/app/controllers/api/v1/
created: 2026-11-07
updated: 2026-11-07
tags: [remote, cli, authentication, operations]
---

One native Hive CLI can address a local installation or a named remote
installation. Remote access is opt-in: existing installations keep the implicit
`local` context until the operator issues a server token and adds a client
context. A context selects an installation, never a checkout path.

## Prepare the serving installation

The supported topology is loopback-only `hive web` behind an operator-managed
TLS reverse proxy or tunnel. Provisioning the proxy, TLS certificates and rate
limiting belongs to the operator. Before exposing it:

1. Configure a non-blank `web.github.owner` on the server. Hosted hivedev C15
   workspaces must provision that owner at workspace creation. An ownerless
   browser installation can be claimed; creating an API token cannot authorize
   or repair that exposure.
2. Set `web.local_loopback: false` and restart the serving web process. The
   canonical `HIVE_WEB_LOCAL_LOOPBACK` setting must be false; literal `"0"` is
   false. When the canonical value is unset, the deprecated
   `HIVEBOX_LOCAL_LOOPBACK` alias still applies.
3. Forward only `/api/v1` and its descendants to loopback web. Refuse every
   other browser path at the proxy, including login, claim and administration
   paths. Preserve the bearer header without recording it, query credentials,
   request bodies or secrets in proxy diagnostics. Configure proxy rate
   limiting; Hive adds no API throttle or API 429 response.
4. Install the server's command-receipt extension using the existing
   [[commands/receipt]] procedure. Install and run the server daemon through
   [[commands/daemon]]. Accepted workflow work waits for that daemon; an HTTP
   acknowledgement does not prove execution started.

Before selecting a remote client context on a server with older managed service
definitions, re-render each installed service with its existing force-install
verb: `hive --context local daemon install --force`,
`hive --context local web install --force`,
`hive --context local bot install --force`, or
`hive --context local babysit install --force`. Generated definitions explicitly
select the local installation. Existing drift protection preserves older bare
argv without `--force`; this feature does not migrate installed units itself.

The server API refuses every request with the same safe 503 response when the
owner is blank or loopback authentication bypass is active. Mutations and
mutation replays receive that identical response when command receipts are
absent. Audit outcome codes distinguish these conditions locally. Token
creation and listing show the current configured interlock state.

Token issuance does not change `Commands::Web#enforce_bind_policy!`. A separately
authorized non-loopback bind also avoids loopback bypass, but the supported
remote recipe remains loopback web behind the restricted TLS proxy. Browser
GitHub-owner authentication and CSRF rules remain in force independently of
bearer authentication. A proxy rejection may use its own status or body before
a request reaches Hive.

## Issue a token and connect

On the server, issue the smallest suitable grant:

```sh
hive token create --context local --name laptop \
  --scopes read,create,act,answer --projects demo
hive token list --context local --json
```

Use `--all-projects` explicitly instead of `--projects` for an installation-wide
grant. Optional `--expires-at` takes a future ISO 8601 timestamp. The raw bearer
is displayed once. Transfer it through a secure operator-controlled channel,
then supply it on stdin when adding the client context:

```sh
hive context add nas --url https://hive.example.net --token-stdin
hive context show nas --json
hive context use nas
hive context list
```

Never put the token in an argument or URL. HTTPS certificate verification stays
enabled and the client never follows redirects with credentials. Context
metadata and separate credentials live under the client configuration home in
owner-only, locked, atomically replaced files. Newer unknown file schemas
require a Hive upgrade; failures never fall back to the local installation.
Adding, showing or selecting a remote context verifies fresh metadata and its
pinned installation identity. Failed verification leaves the selection intact.

Before every remote mutation, the CLI refreshes authority, verifies the pinned
installation and prints and flushes the target, context, installation, scopes,
project limits and retry key to stderr. JSON stdout remains one document. Local
mutations announce unrestricted local-operator authority. Context administration
always identifies the local client configuration as its target.

## Authority and supported operations

Scopes are independent; a write scope does not imply `read`.

| Grant | Permitted effect |
| --- | --- |
| Any valid token | Own context metadata and own submitted-operation lookup in a currently authorized project |
| `read` | Authorized status, task details, questions, bounded logs/diffs/artifacts, and other-principal operation lookup |
| `create` | Capture tasks in an already registered project using installed workflows |
| `act` | Admit the closed supported workflow action or retry with a fresh observation |
| `answer` | Write one bound brainstorm answer or approve an existing guarded transition |

An `act` transition whose canonical effect is approval also requires `answer`.
The explicit approval endpoint requires `answer`. Remote requests cannot use
force or bypass flags, including a transition that would derive force on the
server. Such a transition must be advanced locally. The worker revalidates the
stage, generation and authorized effect before execution.

Named project grants bind the registered name, registration ID, canonical state
root and repository identity. Removal or a changed fingerprint denies access.
Unchanged re-registration preserves the grant; removal is not revocation.
Status counts and dependency detail cover the authorized subset only.

Tokens cannot register projects, change configuration, install or grant modules,
delete/drop/forget/prune tasks, execute arbitrary argv or shell commands, upload
attachments, publish releases, or map remote checkout paths to client paths.
Installed workflow packages are trusted local-operator code. Task text and
answers become prompts for agents running with full local operator authority
inside the authorized project's checkout. A `create` or `answer` grant therefore
carries that local-operator blast radius; token scopes do not sandbox workflow
internals or the agent.

```sh
hive status --context nas --project demo --json
hive --context nas new demo --json -- Investigate the backlog
hive task TASK --project demo --context nas --json
hive answer TASK --project demo --context nas --json
hive operation OPERATION_ID --project demo --context nas --json
```

Place `--context` before the command or before `new` idea prose; a literal
`--context` inside that prose stays part of the idea. Remote status returns at
most 100 task rows and a byte-bounded page. Pass `data.continuation` back with
`hive status --context nas --cursor HANDLE --project demo --json`, retaining
the same project filter. Membership, stage, workflow and task-generation
changes invalidate continuation; the task generation comes from persistent
projection identity rather than a live worker lease. Transient marker, action and live-lock changes
do not. Missing or failed project loads expose `state: unavailable` with an
unknown task count. Remote `--operational` is explicitly unsupported; use the
remote status DTO or select `--context local` for that local view.

Question inventories return opaque handles, not native server folder bindings.
Pass the selected handle as `hive answer ... --binding HANDLE` and put the
literal answer on stdin. An answer-only token needs a handle obtained by an
authorized reader; an act-only token similarly needs its action observation.
Approval can supply `--from STAGE --generation GENERATION` explicitly for an
answer-only token. No read scope is silently added.

The private handle registry retains at most 4096 entries and 8 MiB. New handles
authenticate their original kind and scope so eviction reports known-stale 409
for that scope, while random or foreign handles remain 404. Refresh inventories
after eviction. Legacy unsigned handles retain their existing records until
eviction but cannot be authenticated after those records expire. Registry locks
use nonblocking acquisition with a one-second deadline. Client credential and
lock files reject symlinks; credential files must be current-operator-owned and
private. Authentication caches the installation identity per database object and
process without a request-time SQLite integrity diagnosis or ProcessGuard lease.

Remote `hive task` also supports mutually exclusive `--log`, `--diff`,
`--artifacts` and `--artifact ID` selectors. `--output DESTINATION` writes an
explicitly requested result to that client destination. An artifact ID is an
opaque resource identity, never a remote or client filesystem path. The three
new artifact/diff selectors require a remote context; locally use the existing
`hive task --json` artifact panel. The local `--log`/`--json` incompatibility
remains unchanged.

Local filesystem and administration commands fail while a remote context is
selected. Use `--context local` explicitly to operate on the local installation:

```sh
hive run TASK --project demo --context local
```

Daemon-owned work executes against the serving installation even if its
operator has saved a remote client context. Native attempt wrappers and workers
explicitly select `local` before dispatch. Current managed service definitions
and native daemon/babysitter re-exec paths also retain that local target.

Remote status/task/mutation JSON uses `hive-remote.v1` with explicit semantic DTOs
and source schema/version metadata where applicable. It does not promise the
full local command payload. Context, token and operation commands own
`hive-context.v1`, `hive-token.v1` and `hive-operation.v1` respectively. API
compatibility follows the advertised `/api/v1` base path; optional added fields
are tolerated. Retired or unknown paths return typed `unsupported_version` with
the currently served base paths.

## Lost responses and operation recovery

Every mutation requires an idempotency key. The CLI generates a random key when
one is not supplied and displays it before submission. If the response is lost,
the outcome is unknown: repeat the identical input against the same installation
with the same `--idempotency-key`. Do not create a new key to retry the same
effect. Once the acknowledgement is recovered, query its durable operation ID.

For approval, stderr also prints the resolved `--from`, `--generation` and
`--idempotency-key` before submission. Replay those exact values even if the
task has advanced; resolving a fresh generation changes the request. A refused
recovery admission records a failed receipt rather than successful acceptance.

A same-key/input replay returns the original acknowledgement after the task
advances. Changed input conflicts. Two distinct tokens reusing one key in the
same project receive 409 without receipt or result disclosure. This conflict is
a key-existence oracle. Caller-supplied keys must have high entropy. Revocation
does not release claimed keys during receipt retention.

Receipts have the existing 30-day retention contract, longer than the one-hour
dispatch-result table. Operation lookup distinguishes original admission from
later task/attempt progress, including queued, running, succeeded, failed and
unresolved states. Settled payloads or expired transport results are explicit.
A disabled/dead daemon can leave honest queued work. Neither disconnection nor
revocation cancels work already durably accepted. After receipt retention and
eligible pruning there is no indefinite operation-history guarantee.

## Incident response

1. For ongoing or uncontained ingress, stop managed web with
   `hive web stop --context local` on the server; stop a foreground web process
   through its owning terminal/service. This removes API and browser
   availability. It does not guarantee cancellation of daemon work.
2. Inspect existing API audit entries for the token public ID, project,
   operation and outcome. No source address, bearer, body or authorization
   header is retained in those entries. List tokens and revoke suspect public
   IDs locally:

   ```sh
   hive token list --context local --json
   hive token revoke PUBLIC_ID --context local --json
   ```

   There is no global token-disable switch. Enumerating and revoking individual
   tokens has an accepted operational cost. Revocation/expiry blocks future
   calls, including replays and own-operation lookup, without cancelling
   accepted work. Revoke before entering a runtime-wide maintenance pause.
3. Correlate accepted work in the existing receipt ledger using
   `principal = installation:INSTALLATION_ID:token:PUBLIC_ID` and
   `principal_source = api_token`. `command_dispatch_contexts` links receipt IDs
   to request IDs; attempts retain the request ID after transient dispatch
   cleanup. These are existing forensic fields, not a new log or token table.
4. `hive daemon queue list --context local --json` and
   `hive daemon queue show REQUEST_ID --context local --json` inspect pending
   dispatch work. They do not enumerate all historical operations for a token
   or cancel them. Queue pruning removes eligible expired work; remote accepted
   work does not gain a generic ten-minute expiry.
5. If an installation-wide pause is appropriate, use the existing
   `hive daemon quiesce --context local --json` procedure in
   [[commands/daemon]]. Only a verified `paused: true` result proves its stated
   owned-process/admission boundary. Refusals and timeouts are not proof that
   execution stopped. Keep any returned resume obligation and use
   `hive daemon resume --context local` only when recovery is ready. Queued
   requests remain accepted and may execute after resume. `hive daemon stop`
   stops the daemon under its existing lifecycle rules and is not selective
   cancellation of a token's work.

There is no supported existing local CLI verb to enumerate and cancel every
accepted operation belonging to one token. Historical correlation requires local
ledger investigation, and selective cancellation remains a limitation recorded
in [[gaps]]. Do not interpret token revocation, queue inspection, web shutdown or
a daemon stop as that missing capability.

Automated local fixtures exercise separate client/server installations, real
transport and deterministic workers. Live NAS/Hivebox deployment, a production
TLS proxy, and manual network captures require a later authorized deployment;
their absence is a verification limitation, not evidence of a successful rollout.
