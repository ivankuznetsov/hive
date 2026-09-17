---
pr_url: https://github.com/ivankuznetsov/screenote/pull/37
pr_number: 37
---

## Summary

The Screenote CLI now authenticates with OAuth bearer tokens instead of project-scoped API keys, while the REST v1 API keeps accepting API keys for existing callers. CI and agents can authenticate deterministically with a pre-provisioned token (`--token`, `SCREENOTE_TOKEN`, or config `token`) that never triggers a prompt or a browser. Developers can run `screenote login` for an interactive OAuth flow, and `screenote logout` to clear stored credentials.

Because the Go CLI branch was never merged, CLI-facing API-key auth is removed cleanly — there is no `--api-key`, `SCREENOTE_API_KEY`, or config `api_key`, and no hidden fallback. Server-side API-key support for REST and MCP is untouched.

### What changed

| Surface | Change |
|---|---|
| CLI credentials | Bearer-token contract with precedence `--token` > `SCREENOTE_TOKEN` > config `token` > stored login credential. Missing token → JSON stderr `missing_token`, exit `2`. |
| `screenote login` / `logout` | OAuth metadata discovery, dynamic client registration, PKCE, loopback redirect, token exchange, and `0600` credential storage. Logout is idempotent and leaves `token`/`base_url`/`project` config alone. |
| Stored-credential refresh | Only the stored-login path refreshes on expiry (when a refresh token exists). Explicit token sources never refresh and always win. |
| Project selection | Project-scoped commands require an explicit `--project` / `SCREENOTE_PROJECT` / config `project`; no inference via `project list`. Missing project → JSON `missing_project`, exit `2`. |
| REST v1 auth | `Api::BaseController` accepts Doorkeeper OAuth bearer tokens *and* API keys via a shared `Api::BearerAuthenticator`. Invalid/expired/revoked/missing bearer → 401 JSON `unauthorized`. |
| REST v1 authorization | OAuth requests validate the user's membership in the selected project and enforce `mcp_read` (reads) / `mcp_write` (writes) scopes. API-key requests keep their existing project-key scoping. |

### Auth model

- **Ordinary commands** never open a browser or prompt. Explicit token first; stored login credential only as a fallback.
- **User-global commands**: `project list`, `config`, `login`, `logout`.
- **Project-scoped commands**: `page list`, `screenshot list`, `screenshot create`, `annotation list`, `annotation get`, `comment add`.
- **Exit codes**: invalid/expired token → auth code `3`; missing project → usage/config code `2`. JSON stdout and machine-readable JSON stderr preserved.

This PR also brings in the draft Go CLI it builds on, so the diff includes the CLI packages (`cmd/screenote`, `internal/cli`, `internal/config`, `internal/screenote`) alongside the auth changes.

## Test plan

- `go test ./...` passes for the CLI, including token precedence, project-requirement, PKCE/login callback, refresh, and logout coverage.
- The REST v1 controller suite passes (59 runs, 173 assertions), covering API-key compatibility, OAuth acceptance, scope enforcement, project-membership checks, and the `Api::BearerAuthenticator` precedence contract.
- `bin/rubocop` (0 offenses) and `brakeman -q` (no warnings).
- Full `bin/rails test` was run but fails only on a pre-existing environment issue (missing `libvips.so.42`) unrelated to this change.

## Review summary

Two full review passes were completed with all findings resolved or auto-fixed; no High-severity defects and no missing plan-required behavior in either pass.

- **Authorization** verified correct on every axis: no cross-project IDOR (scoped queries re-filter by the validated project), scopes enforced per action (no implicit `mcp_write` → `mcp_read` grant), and API-key server behavior preserved.
- **Reliability fixes applied**: non-blocking login callback send with bounded shutdown timeout, `signal.NotifyContext` wiring so an abandoned `login` cancels cleanly, a default HTTP client timeout, closed upload pipe, and token refresh threaded through the cobra command context.
- **Performance**: OAuth `project list` N+1 COUNT replaced with a single grouped count.
- **Test rigor**: added direct `Api::BearerAuthenticator` coverage, an unknown-token 401 case, write-scope non-member rejection, the exit-3 refresh-failure path, and a role-mapping assertion for `project list`.

All R1–R12 plan requirements are implemented. Final verdict across reviewers: ready to merge.

## Linked task

Hive task `replace-screenote-cli-api-key-260708-545b` — OAuth-first Screenote CLI authentication.

<!-- COMPLETE pr_url=https://github.com/ivankuznetsov/screenote/pull/37 is_draft=false -->
