---
title: hive connect/disconnect screenote
type: command
source: lib/hive/cli.rb, lib/hive/commands/connect.rb, lib/hive/commands/disconnect.rb, lib/hive/screenote/
created: 2026-06-22
updated: 2026-07-18
tags: [command, screenote, oauth, mcp]
---

**TLDR**: `hive connect screenote` is the operator-facing OAuth 2.1 setup flow
for Screenote MCP uploads. It discovers Screenote OAuth/MCP metadata, uses a
loopback auth-code + PKCE flow, lists Screenote projects through MCP, prompts for
a default `project_id`, and stores the resulting credential at
`~/.config/hive/screenote.json` (or `HIVE_HOME/screenote.json`) with mode `0600`.
`hive disconnect screenote` revokes the stored token when possible and clears the
credential. The `7-artifacts` stage then injects Screenote MCP only for connected
Claude-backed runs; missing/expired credentials are fail-soft. See
[[stages/artifacts]].

## Synopsis

```bash
hive connect screenote [--base-url URL] [--json]
hive disconnect screenote [--json]
```

`screenote` is currently the only supported service name. Other service names
raise `Hive::ConfigError`.

If Thor rejects a missing `SERVICE` before the command runs
(`hive connect --json` or `hive disconnect --json`), `bin/hive` emits the same
schema-less Screenote failure family on stdout: `ok:false`,
`service:"screenote"`, `error_kind:"usage"`, exit 64, and the Thor usage
message.

## Connect Behavior

1. Resolve `screenote.base_url` from global config, `HIVE_SCREENOTE_BASE_URL`, or
   `--base-url`; the default is `https://screenote.ai`.
2. Discover `/.well-known/oauth-authorization-server` and
   `/.well-known/oauth-protected-resource`. The protected-resource `resource`
   field is persisted as the MCP endpoint; it is not hard-coded.
3. Start a one-shot loopback callback server on `127.0.0.1:0` and use that
   redirect URI for dynamic client registration unless an existing stored
   `client_id` can be reused.
4. Build the authorize URL with `response_type=code`, PKCE S256, state, and
   scope `mcp_read mcp_write`. Hive opens the URL in a browser when possible and
   prints it as a fallback.
5. Exchange the returned code for an OAuth bearer. Refresh tokens are stored if
   returned, but automatic refresh is intentionally deferred.
6. Call Screenote MCP `list_projects` with the new bearer and prompt the operator
   to pick a default project. There is no silent default because OAuth MCP tool
   calls require `project_id`.
7. Persist `access_token`, `expires_at`, `token_type`, `scope`, `client_id`,
   `issuer`, `mcp_resource`, `base_url`, `project_id`, and optional
   `refresh_token` through `Hive::Screenote::CredentialStore`.

`CredentialStore` uses the shared non-mutating `Hive::StringifyKeys` transform
before its JSON round trip, so nested credential metadata follows the same
string-key contract as durable journal and condition payloads.

Under `--json`, connect streams newline-delimited JSON: first an `authorize`
line (`ok`, `service`, `stage: "authorize"`, `authorize_url`, `browser_opened`)
emitted before the flow blocks on the loopback callback — the fallback URL when
the browser cannot auto-open — then a success document containing `ok`,
`service`, `base_url`, `issuer`, `client_id`, `project_id`, and
`credential_path`. Error handling uses the normal `Hive::Error` /
`Hive::ConfigError` CLI path.

## Disconnect Behavior

`hive disconnect screenote` loads the stored credential, rediscovers Screenote
metadata from the stored `base_url`, attempts token revocation through the
metadata `revocation_endpoint`, then clears `screenote.json`. Missing credentials
are treated as an idempotent no-op; a present-but-corrupt file is still cleared.
Revocation failures (including an unreachable endpoint) are warned about but do
not prevent local credential removal. Under `--json`, the envelope carries
`disconnected`, `revoked`, and — when `revoked` is false — a `reason`
(`no_token`, `unreadable_credential`, or the revoke error) so automation can
tell the cases apart.

## Runtime Use

Connected credentials are not placed in YAML config and are not exposed through
environment variables. For Claude-backed `7-artifacts`, hive writes an ephemeral
strict MCP config under `Hive::Paths.cache_home`, points Claude at it with
`--mcp-config` / `--strict-mcp-config`, and adds the Screenote MCP tools to
`--allowedTools`. The prompt supplies the selected project id and instructs the
agent to call `create_screenshot_upload`, PUT local PNG/JPEG bytes to the signed
upload URL, and write the resulting `screenote_url` into
`media/manifest.json`.

If the credential is missing, expired, incomplete, invalid, or lacks a default
project, no MCP server is injected. The artifacts prompt records that Screenote
is unavailable and tells the agent to keep local media plus
`screenote_skipped_reason` entries.

## Backlinks

- [[cli]] · [[commands]]
- [[modules/config]] · [[stages/artifacts]]
