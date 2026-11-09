---
title: hive context
type: command
source: lib/hive/commands/context.rb, lib/hive/connection_contexts.rb, lib/hive/remote/client.rb, lib/hive/remote/dispatcher.rb
created: 2026-11-07
updated: 2026-11-07
tags: [command, remote, context]
---

`hive context` manages this client's installation targets without requiring a
local runtime database or discovering a project. An unconfigured client uses
`local`; `--context NAME` overrides the saved selection for one invocation.

```sh
hive context add nas --url https://hive.example --token-stdin
hive context list
hive context show nas --json
hive context use nas
hive --context local version
```

Add reads a single bearer from bounded stdin. Literal token options and extra
arguments are rejected with fixed diagnostics that do not echo their values.
The URL must use HTTPS without user information, query parameters or fragments.
TLS certificate and hostname verification remain enabled; redirects are refused.

Add, show, and use fetch `/api/v1/context` to verify the installation ID and API
version and display the current token's public ID, independent scopes, project
limits and expiry. Failed or offline verification leaves the saved selection
unchanged. A changed installation ID requires verifying the server and adding
the context again. A retired API reports validated served base paths and
compatible-version guidance.

Versioned metadata and a separate credential file live under
`Hive::Paths.config_home/connections`. Atomic locked writes enforce directory
mode 0700 and file mode 0600. Displays omit the credential reference and bearer.
An unknown newer configuration version fails with upgrade guidance.

Context administration always changes local client configuration, including
when a remote context is selected. Add/use announce that local target on
stderr. JSON output is one `hive-context.v1` document, including usage errors.
Task mutations refresh remote authority before submission; see [[cli]] and
[[remote-access]] for the supported command and deployment boundaries.
