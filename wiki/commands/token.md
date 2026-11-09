---
title: hive token
type: command
source: lib/hive/commands/token.rb, lib/hive/remote/token_store.rb, lib/hive/remote/authorization.rb, web/app/controllers/api/v1/base_controller.rb
created: 2026-11-07
updated: 2026-11-07
tags: [command, remote, authentication]
---

The server-local token boundary issues personal bearer credentials for the
versioned remote API. Its JSON contract is `hive-token.v1`. Public CLI
registration is paired with the consuming remote transport.

Public syntax is `hive token create --scopes read,create,act,answer --projects
PROJECT[,PROJECT]`, `hive token list`, and `hive token revoke PUBLIC_ID`.
`--name` and `--expires-at` are optional; use explicit `--all-projects` in place
of named grants. All three are server-local commands and require
`--context local` when a remote selection is active. No browser administration
UI or remote lifecycle handler is added. Deployment prerequisites and the
incident runbook are in [[remote-access]].

Scopes are independent: `read` inspects task content, `create` captures tasks,
`act` admits supported workflow work, and `answer` answers brainstorm questions
or approves a guarded transition. No scope authorizes setup, configuration,
module grants, deletion or releases. Installed workflow code runs with local
operator authority; scopes do not sandbox that code or the agent prompts
created from task text and answers.

Issuance requires a non-blank `web.github.owner` and explicit named projects or
an all-project grant. Named grants bind the registration identifier, canonical
state root and repository identity. Missing or changed registrations deny
access; unchanged re-registration preserves the grant.

Bearers have a public identifier and a 256-bit random secret. Only the secret's
SHA-256 digest is persisted. The registry is stored under state home's
`remote-access/` directory with mode 0700; its locked, atomic registry has mode
0600. The raw bearer is displayed once at issuance. List and revoke expose
public identifiers only. Expiry and revocation apply on every API request and
do not cancel work already accepted by the daemon.

The API accepts bearer authentication independently of browser sessions and
CSRF protection. It is unavailable while the owner is blank or the shared web
environment predicate enables loopback authentication bypass. Mutations also
require the serving installation's command-receipt extension. These conditions
have an identical safe HTTP 503 response and distinct audit outcome codes.
Local token administration reports the configured interlock state.

API audit entries use the existing logger and contain only token public ID,
authorized project, operation and outcome. The request boundary suppresses
ordinary request logging for API requests, including addresses, headers, query
values and bodies, and caps mutation JSON at 256 KiB before parsing.

The mutation API accepts only typed JSON fields, with an `Idempotency-Key`
header or `idempotency_key` body field on every POST. Supplying both with
different values is malformed input. Routes and independent admission scopes:

| Endpoint | Scope | Fields besides the key |
|---|---|---|
| `POST /api/v1/projects/:project/tasks` | `create` | `text`; optional `slug`, `body`, installed `workflow`, `depends_on`, `base` |
| `POST /api/v1/projects/:project/tasks/:task/actions` | `act` | `action_id`, `observation` |
| `POST /api/v1/projects/:project/tasks/:task/answers` | `answer` | opaque `handle`, literal `answer` |
| `POST /api/v1/projects/:project/tasks/:task/approvals` | `answer` | observed `stage`, `generation` |

Action effects that approve a transition also need `answer`. Canonical effects
that require native force remain local, even with every scope; the fixed API
guidance is `advance this task locally`. Caller paths, argv, classes,
environment, force/bypass flags and attachments are rejected. Explicit
project-qualified creation dependencies require that project's grant before
native dependency resolution. No route starts a daemon, provider or agent.
`depends_on` accepts one string or a nonempty flat list of at most 64 strings.

Scope and current project grants are checked before task or receipt lookup.
Responses use 400 for malformed input, 403 for missing scope, uniform 404 for
inaccessible resources, 409 for stale observations or key conflicts, 413 for
oversized input, 422 for domain rejection, and 503 for unavailable service.
Successful new captures return 201, short writes/replays return 200, and queued
workflow admissions return 202. Acknowledgements contain `operation_id`, bounded
`command_receipt` identity and task/admission facts, without paths, bindings,
task text or suggested commands. An idempotent retry returns the original
acknowledgement even after stage advancement.

`GET /api/v1/projects/:project/operations/:id` projects the existing durable
receipt in that project's namespace. Any currently valid token may inspect its
own operation within its current project grant; another principal needs `read`
or receives the same 404 as an unknown operation. Revocation and expiry apply
before lookup. The submitting principal is the full installation plus token
identity, so a replacement token cannot inherit old write-only access.

Operation data keeps the original `command_outcome` and `acknowledgement`
separate from linked worker `progress`. States include `accepted`, `queued`,
`running`, `succeeded`, `failed`, `unresolved`, `settled` and `result_expired`.
`result_available` describes the retained acknowledgement; `result_expired`
also reports missing retained workflow progress. Request IDs correlate through
existing dispatch contexts to durable attempts after one-hour transient result
cleanup. A queued admission remains queued while the daemon is stopped. The
existing receipt retention is 30 days; a pruned receipt has no lookup guarantee.
