# Plan: OAuth-first Screenote CLI authentication

## Overview

Replace the draft Go CLI's API-key-facing authentication contract with OAuth-first authentication while keeping server-side API-key support for existing REST/MCP callers.

The work spans two surfaces:

- The Go CLI from draft branch `add-a-go-cli-for-260708-edec`, currently under `cmd/screenote`, `internal/cli`, `internal/config`, and `internal/screenote`.
- Rails REST API v1, currently authenticated by `Api::BaseController` using project-scoped `ApiKey` records, while MCP already validates both API keys and Doorkeeper OAuth bearer tokens in `config/initializers/fast_mcp.rb`.

Primary decision: the CLI supports both deterministic pre-provisioned OAuth bearer tokens (`--token`, `SCREENOTE_TOKEN`, config `token`) and explicit interactive developer login (`screenote login`) using the existing Doorkeeper authorization_code + PKCE + loopback redirect flow. Ordinary commands must never open browsers or prompt.

No follow-up questions remain from the brainstorm. If implementation discovers that full browser login is too large to land safely with the token contract, split `login`/`logout`/refresh into a follow-up, but still complete the pre-provisioned token path and REST OAuth acceptance.

## Requirements Trace

- R1: CLI auth becomes OAuth-first, with `--token`, `SCREENOTE_TOKEN`, and config `token` replacing `--api-key`, `SCREENOTE_API_KEY`, and `api_key`.
- R2: The CLI must support CI/agent deterministic auth through a pre-provisioned bearer token without prompts, browser launches, or hot-path refresh requirements.
- R3: The CLI should include explicit `screenote login` using OAuth metadata, dynamic client registration, PKCE, localhost redirect, token exchange, credential persistence, `logout`, and refresh-on-expiry when stored credentials include a refresh token.
- R4: CLI-facing API-key auth is removed entirely because the Go CLI PR is not merged; no hidden fallback, docs, or tests for CLI API-key auth.
- R5: REST v1 keeps accepting API keys server-side for existing callers while also accepting Doorkeeper OAuth bearer tokens.
- R6: REST v1 OAuth authorization reuses `mcp_read` and `mcp_write` scopes. Read commands require `mcp_read`; write commands require `mcp_write`.
- R7: OAuth REST requests must validate that the authenticated user has access to the explicitly selected project.
- R8: OAuth project-scoped CLI commands require project selection through `--project`, `SCREENOTE_PROJECT`, or config. Missing project in non-interactive commands is a JSON stderr usage/config error.
- R9: User-global commands are `project list`, `config`, `login`, and `logout`. Project-scoped commands are `page list`, `screenshot list`, `screenshot create`, `annotation list`, `annotation get`, and `comment add`.
- R10: Preserve JSON stdout, machine-readable JSON stderr, stable exit codes, and zero hidden prompts in non-interactive commands.
- R11: Invalid/expired tokens use the existing auth-error exit code. Missing project uses the existing usage/config exit code.
- R12: Out of scope: OS keyring integration, device-code grant, client-credentials grant, server-side default project, and removing server-side API-key support.

## Scope Boundaries

In scope:

- Rename the CLI credential contract from API-key terminology to token terminology.
- Add CLI token resolution precedence: flag > env > config token > stored login credential, with stored credential refresh only when the stored credential path is used.
- Add explicit `login` and `logout` commands if implementable without new backend grants.
- Add REST OAuth bearer validation to `Api::BaseController` and project membership checks for OAuth requests.
- Update CLI and Rails tests for token precedence, project requirement behavior, auth errors, REST OAuth acceptance, scope enforcement, and API-key compatibility.
- Update README/wiki/docs that describe CLI auth examples.

Out of scope:

- Device-code grant, client-credentials grant, OS keyring storage, server-side default project, automatic single-project selection, hidden browser prompts in ordinary commands, and removal of API keys from the web UI/MCP/server APIs.
- Changing the OAuth server grants beyond using existing Doorkeeper metadata, DCR, PKCE, refresh tokens, and scopes.
- Reworking MCP auth semantics except extracting reusable validation code if needed for REST.

Important dependency:

- The Go CLI files are not present on the checked-out main tree, but they exist on branch `add-a-go-cli-for-260708-edec`. Implementation should be performed on top of, or after merging/rebasing, that draft CLI branch so the file paths below exist.

## Implementation Units

### 1. CLI credential contract and config resolution

Goal:

- Replace CLI API-key naming with OAuth token naming and define deterministic precedence for bearer credentials.

Files:

- `cmd/screenote/main.go`
- `internal/cli/root.go`
- `internal/cli/config.go`
- `internal/cli/errors.go`
- `internal/config/config.go`
- `internal/config/config_test.go`
- `internal/cli/root_test.go`
- `internal/cli/commands_test.go`

Approach:

- Replace persistent `--api-key` with `--token`.
- Replace `Values.APIKey`, `Sources.APIKey`, JSON/TOML `api_key`, and env `SCREENOTE_API_KEY` with `Token`, `token`, and `SCREENOTE_TOKEN`.
- Update `a.client()` errors from `missing_api_key` to `missing_token`, with copy that names `--token`, `SCREENOTE_TOKEN`, and config `token`.
- Remove any code/tests/docs that accept `api_key` as a CLI config input. Since the CLI PR is unmerged, do not provide compatibility shims.
- Keep `base_url` and `project` precedence unchanged.
- Ensure `screenote config` never prints stored login secrets by default. If the current config command prints resolved config, it may include only the explicit top-level `token` source/value behavior already expected for CI, but stored OAuth credentials should be summarized or omitted.

Test scenarios:

- Flag token overrides env token and config token.
- Env `SCREENOTE_TOKEN` overrides config token.
- Config `token` is used when no flag/env token exists.
- `SCREENOTE_API_KEY`, `--api-key`, and `api_key` are rejected/ignored according to the clean-cut contract: unknown flag for `--api-key`, no env/config fallback for legacy names.
- Missing token emits JSON stderr with code `missing_token` and exit code `2`.
- `screenote config` output uses `token`/`sources.token`, not `api_key`/`sources.api_key`.

Verification:

- Go unit tests in `internal/config/config_test.go`, `internal/cli/root_test.go`, and `internal/cli/commands_test.go`.
- Manual smoke in implementation stage: run a read-only command against a test HTTP server and assert `Authorization: Bearer <token>` is sent.

### 2. CLI HTTP client token semantics

Goal:

- Make the HTTP client credential generic bearer-token based, independent of API-key naming.

Files:

- `internal/screenote/client.go`
- `internal/screenote/client_test.go`
- `internal/screenote/types.go`

Approach:

- Rename `apiKey` fields/parameters to `token` or `bearerToken`.
- Preserve the existing wire format: `Authorization: Bearer <token>`.
- Keep HTTP status mapping stable: 401/403 map to auth exit code through `screenote.Error`.
- Avoid token introspection or token-type branching in the client; REST server decides whether a bearer is API key or OAuth token.

Test scenarios:

- Client sends `Authorization: <redacted-credential>`.
- Empty token does not set the Authorization header when constructing lower-level tests, while CLI command validation still prevents missing token before ordinary requests.
- 401/403 server responses produce code `unauthorized` or server-provided code and auth exit behavior.

Verification:

- Go tests in `internal/screenote/client_test.go`.

### 3. CLI project selection rules

Goal:

- Require explicit project selection for OAuth project-scoped commands and prevent API-key-era project inference.

Files:

- `internal/cli/root.go`
- `internal/cli/page.go`
- `internal/cli/screenshot.go`
- `internal/cli/annotation.go`
- `internal/cli/comment.go`
- `internal/cli/project.go`
- `internal/cli/commands_test.go`
- `internal/screenote/client.go`

Approach:

- Change `projectID` so it only returns `resolved.Project` and never calls `project list` to infer a project.
- When a project-scoped command lacks project, return usage error code `missing_project` with exit code `2`.
- Keep `project list` user-global and callable with only an OAuth token.
- Prefer rejecting `--project` for user-global commands if the flag would imply unsupported filtering. If persistent flags make command-specific rejection awkward, document and test that it is ignored only for harmless global commands.
- Ensure project ID is sent in route params for project-routed endpoints, and for endpoints without project in the current URL shape add a project identifier as a request parameter/header only if the server unit below adopts that compatibility path.

Test scenarios:

- `page list`, `screenshot list`, `screenshot create`, `annotation list`, `annotation get`, and `comment add` fail with JSON `missing_project` when no project is configured.
- No project-scoped command calls `GET /api/v1/projects` as an inference fallback.
- `project list`, `config`, `login`, and `logout` do not require project.
- Project from flag/env/config is honored in the existing precedence order.

Verification:

- Go command tests in `internal/cli/commands_test.go`.

### 4. CLI interactive OAuth login, logout, and stored credential refresh

Goal:

- Add explicit developer login using existing OAuth infrastructure, plus logout and refresh-on-expiry for stored credentials.

Files:

- `internal/cli/root.go`
- `internal/cli/login.go` (new)
- `internal/cli/logout.go` (new, or combined with `login.go`)
- `internal/cli/login_test.go` (new)
- `internal/config/config.go`
- `internal/config/config_test.go`
- `internal/screenote/oauth.go` (new)
- `internal/screenote/oauth_test.go` (new)
- `go.mod`

Approach:

- Discover OAuth endpoints from `/.well-known/oauth-authorization-server` and protected resource metadata as needed.
- Dynamically register a public localhost client through `POST /oauth/register`.
- Generate PKCE verifier/challenge and a CSRF `state`.
- Start a localhost callback listener on an available loopback port, open the browser for `authorization_code` flow, validate `state`, exchange the code for tokens, and persist stored credentials.
- Store login credentials separately from the top-level CI token contract, for example a dedicated TOML section containing `access_token`, `refresh_token`, `expires_at`, `client_id`, `issuer`/`base_url`, and registration metadata. Do not add OS keyring integration.
- During ordinary commands, use explicit flag/env/config `token` first. Only if no explicit token exists should the CLI load stored credentials, refresh them if expired and a refresh token exists, save the refreshed credential, and send the resulting access token.
- Ordinary commands must fail cleanly instead of launching login if stored credentials are absent or unrefreshable.
- `logout` removes stored login credentials without touching explicit config `token`, `base_url`, or `project` unless the user explicitly invokes existing config commands for those.

Test scenarios:

- Login builds authorization URL with PKCE challenge, requested scopes `mcp_read mcp_write`, registered localhost redirect URI, and state.
- Callback rejects missing/mismatched state.
- Token exchange stores access token, refresh token, expiry, client id, and base URL.
- Stored expired credentials refresh before command execution; refreshed values are persisted.
- Explicit `--token`/`SCREENOTE_TOKEN`/config `token` takes precedence over stored credentials and does not refresh.
- Failed refresh returns JSON auth error and exit code `3`, with no browser prompt.
- `logout` removes stored credentials and is idempotent.

Verification:

- Go unit tests with `httptest.Server` for metadata, DCR, authorize callback, token exchange, refresh, and logout behavior.
- Manual implementation-stage smoke against local Rails OAuth only after automated tests pass.

### 5. REST v1 dual bearer authentication

Goal:

- Keep API-key auth working while allowing REST v1 requests authenticated by Doorkeeper OAuth access tokens.

Files:

- `app/controllers/api/base_controller.rb`
- `config/initializers/fast_mcp.rb` or a new shared auth object such as `app/services/api/bearer_authenticator.rb`
- `test/controllers/api/v1/projects_controller_test.rb`
- `test/controllers/api/v1/pages_controller_test.rb`
- `test/controllers/api/v1/screenshots_controller_test.rb`
- `test/controllers/api/v1/annotations_controller_test.rb`
- `test/controllers/api/v1/annotation_comments_controller_test.rb`
- `test/support/oauth_test_helper.rb`

Approach:

- Extract the reusable parts of MCP OAuth bearer validation if practical, or implement equivalent validation in a small shared service:
  - lookup `Doorkeeper::AccessToken.by_token(token)`,
  - reject missing, revoked, or expired tokens,
  - load the resource owner user,
  - expose token scopes.
- Preserve API-key validation for `sk_proj_*` and existing API keys. API-key requests keep `current_api_key` and project-key scoping.
- Add auth mode readers such as `current_user`, `current_oauth_token`, and `oauth_authenticated?` while keeping `current_api_key` for API-key callers.
- Return the existing JSON error shape with code `unauthorized` for missing/invalid/expired bearer credentials.
- Avoid changing unauthenticated upload-token endpoint behavior in `app/controllers/api/screenshot_uploads_controller.rb`; it is tokenized by signed upload URL and not part of bearer auth.

Test scenarios:

- Existing API-key tests continue to pass for all REST v1 endpoints.
- OAuth token with valid user and required scope authenticates REST v1.
- Revoked/expired/unknown OAuth token returns 401 JSON `unauthorized`.
- Missing bearer token returns 401 JSON `unauthorized`.
- API-key `last_used_at` behavior is preserved for API-key requests and not applied to OAuth tokens.

Verification:

- Rails controller tests for API-key compatibility and OAuth acceptance.

### 6. REST v1 OAuth project authorization and scopes

Goal:

- Enforce explicit project membership and `mcp_read`/`mcp_write` scope requirements for OAuth REST calls.

Files:

- `app/controllers/api/base_controller.rb`
- `app/controllers/api/v1/projects_controller.rb`
- `app/controllers/api/v1/pages_controller.rb`
- `app/controllers/api/v1/screenshots_controller.rb`
- `app/controllers/api/v1/annotations_controller.rb`
- `app/controllers/api/v1/annotation_comments_controller.rb`
- `app/services/api/v1/project_scope.rb`
- `test/controllers/api/v1/projects_controller_test.rb`
- `test/controllers/api/v1/pages_controller_test.rb`
- `test/controllers/api/v1/screenshots_controller_test.rb`
- `test/controllers/api/v1/annotations_controller_test.rb`
- `test/controllers/api/v1/annotation_comments_controller_test.rb`

Approach:

- For API-key requests, keep current behavior: project comes from the API key, and route project mismatches are forbidden.
- For OAuth requests:
  - `GET /api/v1/projects` returns all projects the authenticated user can access via memberships, with each role populated from membership where available.
  - Project-scoped endpoints resolve project from route `project_id` where present.
  - Endpoints whose current URL lacks project context (`POST /api/v1/screenshots`, `GET /api/v1/screenshots/:id/annotations`, `GET /api/v1/annotations/:id`, `POST /api/v1/annotations/:id/comments`) must either require a `project_id` request param/header for OAuth before object lookup or verify the object belongs to the requested project after lookup. Prefer requiring explicit `project_id` for all OAuth project-scoped operations to match CLI determinism.
  - Reject missing project on OAuth project-scoped REST calls with JSON code `missing_project` and 422 or 400 only if the API contract already uses usage-style errors; otherwise 403/404 can be used for inaccessible projects. The CLI should still surface missing project locally before calling the server.
  - Validate `current_user` has membership in the selected project.
- Add scope guards:
  - read: `project list`, `page list`, `screenshot list`, `annotation list`, `annotation get` require `mcp_read`;
  - write: `screenshot create`, `comment add` require `mcp_write`.
- Consider whether `mcp_write` should imply read for write endpoints only. Do not assume `mcp_write` implies `mcp_read` for read-only endpoints unless Doorkeeper scope policy already documents that.
- Attribute `comment add` by OAuth user (`user: current_user`) and by API key (`api_key: current_api_key`) depending on auth mode.

Test scenarios:

- OAuth `project list` returns all and only the user's projects.
- OAuth read token with `mcp_read` can list pages/screenshots/annotations and get annotation details for member projects.
- OAuth read token cannot create screenshots or comments without `mcp_write`.
- OAuth write token with `mcp_write` can create screenshots/comments only for member projects.
- OAuth token for a user without membership cannot access another user's project, even if object IDs are known.
- OAuth project-scoped request missing explicit project returns a machine-readable error.
- API-key requests retain one-project `project list` semantics and route mismatch forbidden behavior.

Verification:

- Rails controller tests covering both auth modes and scope matrix.

### 7. Documentation and examples

Goal:

- Update user-facing CLI docs from API-key examples to OAuth token/login examples while preserving server/API-key docs where they still apply.

Files:

- `README.md`
- `wiki/api-cli.md`
- `wiki/controllers/api-controllers.md`
- `wiki/routes.md`
- `wiki/mcp-tools.md`
- Any CLI help text generated from `internal/cli/*`

Approach:

- Replace CLI configuration docs with:
  - `--token`, `SCREENOTE_TOKEN`, `token`,
  - `screenote login`,
  - `screenote logout`,
  - explicit `--project`/`SCREENOTE_PROJECT`/config `project` for project-scoped commands.
- Remove CLI API-key examples and CLI API-key setup instructions.
- Keep API-key documentation where it describes the web UI, existing REST API compatibility, or MCP support for non-CLI callers.
- Document exit-code behavior: invalid/expired token uses auth code `3`, missing project uses usage/config code `2`.
- Document that ordinary commands do not prompt or launch a browser.

Test scenarios:

- Docs/examples do not mention `--api-key`, `SCREENOTE_API_KEY`, or config `api_key` as CLI auth.
- Docs include both CI token and interactive login flows.
- Docs clearly distinguish CLI OAuth auth from server-side API-key compatibility.

Verification:

- Documentation grep for removed CLI-facing terms, allowing server/API-key compatibility pages where intentional.

## Risks

- CLI branch dependency: the Go CLI is on draft branch `add-a-go-cli-for-260708-edec`, not the current checked-out tree. Implementation should start from that branch or a merged equivalent.
- Login size: PKCE loopback login, dynamic registration, browser launching, callback serving, secure persistence, and refresh add meaningful complexity. If this threatens delivery, split login/logout/refresh into a follow-up while landing `--token`/`SCREENOTE_TOKEN` and REST OAuth first.
- Scope ambiguity: `mcp_write` may or may not imply `mcp_read` in local expectations. The plan treats read and write as explicit requirements; implementation should keep tests aligned with Doorkeeper's actual scope behavior.
- Project context gaps: several existing REST routes do not include project ID in the path. OAuth must still require/validate explicit project context to avoid object-ID-only authorization mistakes.
- Token storage: without OS keyring integration, stored login credentials live in a file. Use `0600` permissions and avoid printing stored secrets through `screenote config`.
- Shared auth extraction: moving MCP auth logic into a shared service could accidentally alter MCP behavior. Keep extraction small and cover MCP auth with existing tests if `config/initializers/fast_mcp.rb` changes.
- API-key compatibility: server-side API-key behavior must remain stable for REST/MCP callers even though the CLI stops exposing API-key auth.

<!-- COMPLETE -->
