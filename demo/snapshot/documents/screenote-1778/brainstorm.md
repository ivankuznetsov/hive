# Brainstorm: replace-screenote-cli-api-key-260708-545b

Replace the Screenote Go CLI's API-key authentication with OAuth-first authentication.

## Context (from repo scan, for grounding — correct anything wrong in your answers)

- **CLI**: Go CLI in draft PR #36 (not merged). Auth today: `--api-key` flag > `SCREENOTE_API_KEY` env > `api_key` in `~/.config/screenote/config.toml`. Client already sends `Authorization: Bearer <token>`. Commands: `project list`, `page list`, `screenshot list/create`, `annotation list/get`, `comment add`, `config`.
- **Backend**: Rails 8, Doorkeeper OAuth 2.1 provider. Supports **authorization_code + PKCE only** (no device-code or client-credentials grant), refresh tokens enabled, 1-year access tokens, dynamic client registration (RFC 7591, localhost redirect URIs), scopes `mcp_read`/`mcp_write`.
- **REST API v1** (`Api::BaseController`) today validates **API keys only** (`sk_proj_*`, project-scoped). The MCP layer already dual-validates API keys AND Doorkeeper OAuth access tokens — but OAuth tokens there are **user-scoped, not project-scoped**.
- **Projects**: API keys belong to exactly one project. OAuth/user credentials map to a user who has many projects via memberships — so a project must be chosen explicitly.

## Round 1

### Q1. This is an OAuth-first *product decision*. For the CLI's primary, deterministic auth path (agents/CI, non-interactive), which credential contract do you want? The backend only offers authorization_code+PKCE (no client_credentials/device grant), so a headless machine cannot self-mint a token from a secret alone — it must be given one that a human/CI obtained earlier.
Options:
  (a) **Pre-provisioned OAuth access token** supplied via env/flag/config (e.g. `SCREENOTE_TOKEN` / `--token`); CLI just sends it as a bearer. Simplest, fully deterministic, no refresh in the hot path. (recommended)
  (b) **Stored credential file** written by an interactive `login` (access + refresh token), CLI auto-refreshes when expired.
  (c) **Both**: token env/flag for CI, credential file for developer machines, with a defined precedence.
### A1.
Use option (c): both.

Screenote already has OAuth 2.1 with PKCE, dynamic client registration, metadata endpoints, refresh tokens, and MCP OAuth-token validation. The CLI should reuse that existing OAuth infrastructure rather than inventing a new auth system.

Primary deterministic path for agents/CI: pre-provisioned OAuth bearer token supplied by flag/env/config. Hot-path commands must not open browsers or prompt.

Developer path: stored OAuth credentials created by an explicit interactive `screenote login` command using authorization_code + PKCE loopback. The CLI may refresh tokens automatically when a refresh token is present. This login flow is explicit, never hidden inside ordinary commands.

### Q2. What should the new flag / env var / config key be named for the OAuth bearer credential, and do we keep any `token`-vs-`api_key` distinction? (e.g. `--token` + `SCREENOTE_TOKEN` + `token` config, replacing `--api-key`/`SCREENOTE_API_KEY`/`api_key` entirely.) Any naming preference, or use the recommended `SCREENOTE_TOKEN` / `--token`?
### A2.
Use `--token`, `SCREENOTE_TOKEN`, and `token` in config for OAuth bearer/access tokens.

Remove the CLI-facing `--api-key`, `SCREENOTE_API_KEY`, and `api_key` contract. The CLI auth field should be generic/OAuth-oriented; do not keep an API-key-shaped name for OAuth tokens.

For stored login credentials, use a separate config section/file structure that can hold `access_token`, `refresh_token`, expiry, client id, and issuer/base URL without printing secrets by default.

### Q3. Since the CLI PR is not merged, should `--api-key`, `SCREENOTE_API_KEY`, and `api_key` config be **removed entirely** (clean cut, no deprecation shims), or kept as a hidden/deprecated fallback? Recommended: remove entirely.
### A3.
Remove API-key CLI auth entirely. No hidden/deprecated fallback in the CLI, because PR #36 is not merged yet and we can make a clean cut.

API keys may still exist server-side for existing API/MCP callers, but the Go CLI should not document, test, or expose API-key authentication as its primary contract.

### Q4. Project selection: OAuth credentials are user-scoped and a user can have many projects. In **non-interactive** mode, when no project is resolvable via `--project` / `SCREENOTE_PROJECT` / config, what is the correct behavior for a command that needs project scope?
Options:
  (a) **Hard error** with machine-readable JSON on stderr + stable exit code, listing that project is required (no prompt, no guessing). (recommended)
  (b) Auto-select if the user has exactly one project; else error.
  (c) Fall back to a server-side "default project" concept (does not exist today — would need backend work).
### A4.
Use option (a): hard error.

In non-interactive mode, commands requiring project scope must fail with machine-readable JSON on stderr and a stable usage/config/auth-style exit code when no project can be resolved from `--project`, `SCREENOTE_PROJECT`, or config. No prompt, no guessing, no auto-selecting a single project.

### Q5. Which commands actually **require** a project scope vs. which are user-global? e.g. `project list` should list all of the user's projects (user-scoped); `page list`, `screenshot *`, `annotation *`, `comment add` presumably need a project. Confirm the split, and confirm `--project` is ignored/rejected for user-global commands.
### A5.
User-global:
- `project list`
- `config`
- `login`
- `logout`

Project-scoped:
- `page list`
- `screenshot list`
- `screenshot create`
- `annotation list`
- `annotation get`
- `comment add`

For project-scoped commands, require explicit project selection via `--project`, `SCREENOTE_PROJECT`, or config when using OAuth. For user-global commands, `--project` should be ignored only where harmless or rejected if it would imply filtering that the command does not support; prefer clear JSON usage errors over surprising behavior.

### Q6. Backend change: `Api::BaseController` must accept Doorkeeper OAuth bearer tokens (the MCP layer already does this). Two sub-questions:
  (a) Should REST v1 **also keep accepting API keys** server-side (so API keys still work for non-CLI callers / MCP), and only the *CLI* stops using them? Recommended: yes — keep server-side API-key support, change only the CLI contract.
  (b) When authenticating via OAuth, project scope comes from the request (`--project` → header/param). What scopes should REST require — reuse `mcp_read`/`mcp_write`, or introduce REST-specific scopes? Recommended: reuse `mcp_read`/`mcp_write`.
### A6.
Yes to both recommendations.

(a) Keep server-side API-key support for existing non-CLI callers and MCP compatibility. Change the CLI contract, not the entire platform auth model.

(b) REST v1 should accept Doorkeeper OAuth bearer tokens by reusing/extracting the existing MCP OAuth validation path where possible. Reuse `mcp_read` and `mcp_write` scopes for now rather than introducing REST-specific scopes. Read commands require `mcp_read`; write commands require `mcp_write`.

OAuth REST requests must validate that the authenticated user has access to the requested project. API-key REST requests may continue using project-key scoping.

### Q7. Interactive login: do you want a `screenote login` command in **this** change (authorization_code + PKCE loopback via localhost redirect, opens browser, stores tokens), or is it out of scope for now (primary contract = pre-provisioned token only, login deferred)? If in scope, should `logout` and token-refresh-on-expiry also be included?
### A7.
Include `screenote login` in this change if it can reuse the existing OAuth metadata, dynamic client registration, authorization_code + PKCE, localhost redirect, and refresh-token support without new server grants.

Also include:
- `screenote logout` to remove stored credentials.
- Refresh-on-expiry when stored credentials include a refresh token.

Do not add device-code grant, client-credentials grant, OS keyring integration, or any hidden browser prompt during ordinary commands. If login proves too large during planning, split it into a follow-up but keep pre-provisioned `SCREENOTE_TOKEN` support in this task.

### Q8. Acceptance & non-goals. Please confirm the acceptance contract to preserve, and flag anything missing:
  - JSON on stdout, machine-readable JSON errors on stderr, stable exit codes, **zero hidden prompts** in non-interactive mode.
  - New/changed exit code(s) for auth failures (401/invalid token) and missing-project — do you want distinct codes or reuse existing auth-error code?
  - Explicitly **out of scope**: OS keyring integration, device-code grant, client-credentials grant, server-side default-project concept — unless you say otherwise.
### A8.
Confirmed.

Preserve:
- JSON stdout by default.
- Machine-readable JSON errors on stderr.
- Stable exit codes.
- Zero hidden prompts in non-interactive commands.
- Agent/CI deterministic token path via `--token` / `SCREENOTE_TOKEN` / config.
- Explicit project selection for OAuth project-scoped commands.

Use existing auth-error exit code for invalid/expired token. Use usage/config exit code for missing required project selection.

Out of scope:
- OS keyring integration.
- Device-code grant.
- Client-credentials grant.
- Server-side default-project concept.
- Removing server-side API-key support for existing callers.

Acceptance:
- CLI no longer exposes `--api-key`, `SCREENOTE_API_KEY`, or `api_key` as its auth contract.
- REST v1 accepts OAuth bearer tokens for CLI commands using existing Doorkeeper tokens and scopes.
- OAuth user/project authorization is enforced.
- Docs/tests are updated from API-key examples to OAuth token/login examples.

<!-- COMPLETE -->
