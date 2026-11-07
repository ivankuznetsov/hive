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
