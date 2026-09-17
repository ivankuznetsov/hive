# add-a-go-cli-for-260708-edec

## Overview

Build a deterministic Go CLI for Screenote that gives agents and CI scripts a portable shell contract without requiring an MCP client. The CLI should talk to REST endpoints, emit JSON to stdout by default, emit stable machine-readable errors to stderr, support stdin image upload, and install with:

```sh
go install github.com/ivankuznetsov/screenote/cmd/screenote@latest
```

The current REST API is too small for the desired command surface, so this plan includes expanding `api/v1` REST endpoints by sharing the behavior already expressed in the MCP tool layer. MCP remains the rich agent protocol; the CLI becomes the scriptable REST client.

Primary assumptions:
- V1 auth is project API key only. OAuth bearer-token support is deferred unless it is effectively free through existing request plumbing.
- Base URL is configurable through `--base-url`, `SCREENOTE_BASE_URL`, and config. A production default should only be added if the app already has a canonical hosted URL in repo configuration or docs; otherwise the CLI should require a base URL and document localhost/staging examples.
- `annotation resolve`, `annotation reopen`, and multi-viewport upload are planned as extension points but not required for the v1 ship decision.

## Requirements Trace

| Source | Requirement | Planned coverage |
| --- | --- | --- |
| A1 | CLI value is shell/CI automation and non-MCP agent environments; CLI drives REST, not MCP. | Add a Go CLI under `cmd/screenote` with REST client internals only. |
| A2 | New `api/v1` REST endpoints are in scope and should mirror MCP capabilities via shared code. | Add REST controllers/routes for projects, pages, screenshots, annotations, and comments; extract shared serializers/query helpers where useful. |
| A3 | Must-have commands: `config`, `project list`, `page list`, `screenshot create`, `screenshot list`, `annotation list`, `annotation get`, `comment add`. | Implement these commands and focused tests; document nice-to-have commands as deferred. |
| A4 | Auth precedence: `--api-key`, `SCREENOTE_API_KEY`, `~/.config/screenote/config.toml`; project from key where possible, otherwise `--project`, `SCREENOTE_PROJECT`, config. | Implement config resolution in Go and keep REST project scoping compatible with project API keys. |
| A5 | Support base URL flag/env/config; self-hosted from v1; default hosted URL only if canonical. | Add base URL resolver and docs examples for localhost/staging/self-hosted. |
| A6 | JSON stdout by default; stable JSON stderr errors; exit codes 0/1/2/3/4/5; no prompts unless `--interactive`; screenshot create supports stdin. | Implement CLI output/error contract centrally and cover with command tests. |
| A7 | Root Go module, Cobra, GoReleaser/GitHub Releases/checksums, Linux/macOS amd64/arm64, current stable Go used by repo tooling. | Add root `go.mod`, Cobra command tree, release config, and CI build matrix. |
| A8 | Done: `go install` works, v1 commands work locally/staging, `httptest` command/client tests, README/wiki docs, CI cross-compiles. | Add verification gates per implementation unit and docs updates. |

## Scope Boundaries

In scope:
- Root-level Go module for the CLI.
- REST API expansion under `api/v1` for the v1 CLI command surface.
- Shared API serialization/query/service code to avoid duplicating MCP business behavior.
- Project API key auth for CLI requests.
- JSON-first command output and stable JSON errors.
- Stdin and file-path screenshot upload for `screenshot create`.
- Focused Rails controller tests and Go `httptest`/command parsing tests.
- README, wiki docs, CI, and GoReleaser configuration.

Out of scope:
- Browser/OAuth login flow.
- Daemon/watch mode.
- Project member and invitation management.
- Annotation image rendering in the CLI beyond returning server-provided fields for `annotation get`.
- Full MCP client support inside the CLI.
- Required multi-viewport upload for v1.
- Required `annotation resolve` / `annotation reopen` commands for v1.

## Implementation Units

### 1. Shared API Contract and REST Foundation

Goal:
- Make `api/v1` a stable JSON contract that can back the CLI without copying MCP logic into controllers.

Files:
- `config/routes.rb`
- `app/controllers/api/base_controller.rb`
- `app/controllers/api/v1/projects_controller.rb`
- `app/controllers/api/v1/pages_controller.rb`
- `app/controllers/api/v1/screenshots_controller.rb`
- `app/controllers/api/v1/annotations_controller.rb`
- `app/controllers/api/v1/annotation_comments_controller.rb`
- `app/controllers/concerns/project_authorization.rb`
- `app/models/annotation.rb`
- `app/models/screenshot.rb`
- `app/models/page.rb`
- `app/models/project.rb`
- `app/tools/application_tool.rb`
- New shared service/serializer files if needed, for example `app/serializers/api/v1/annotation_serializer.rb` or `app/services/api/v1/project_scope.rb`
- `test/controllers/api/v1/projects_controller_test.rb`
- `test/controllers/api/v1/pages_controller_test.rb`
- `test/controllers/api/v1/screenshots_controller_test.rb`
- `test/controllers/api/v1/annotations_controller_test.rb`
- `test/controllers/api/v1/annotation_comments_controller_test.rb`

Approach:
- Keep `Api::BaseController` as the project API key entry point and return consistent JSON errors with machine codes, while preserving existing behavior for current clients.
- Add routes for:
  - `GET /api/v1/projects`
  - `GET /api/v1/projects/:project_id/pages`
  - `GET /api/v1/projects/:project_id/screenshots`
  - `POST /api/v1/screenshots`
  - `GET /api/v1/screenshots/:screenshot_id/annotations`
  - `GET /api/v1/annotations/:id`
  - `POST /api/v1/annotations/:annotation_id/comments`
- For project API keys, treat the key's project as authoritative. If a request includes a mismatched `project_id`, return forbidden or not found rather than crossing project boundaries.
- Reuse logic already represented by MCP tools such as `ListPagesTool`, `ListScreenshotsTool`, `ListAnnotationsTool`, `GetAnnotationTool`, and `AddAnnotationCommentTool` by extracting shared query/serialization helpers instead of having controllers call FastMCP tool classes directly.
- Preserve pagination defaults from MCP list tools where applicable: `limit` default 50, max 100, nonnegative `offset`.
- Keep response shapes close to the MCP tool JSON where practical so agents can move between MCP and CLI with minimal translation.

Test scenarios:
- Missing, invalid, and revoked API keys return 401 with stable error JSON.
- API key requests cannot access resources outside the key's project.
- `GET /api/v1/projects` returns the key's project in a deterministic JSON shape.
- `GET /api/v1/projects/:project_id/pages` returns pages with version counts.
- `GET /api/v1/projects/:project_id/screenshots` supports `page_id`, `status`, `limit`, and `offset`.
- `GET /api/v1/screenshots/:screenshot_id/annotations` supports `status` and `viewport` filters where the underlying model supports them.
- `GET /api/v1/annotations/:id` returns annotation details plus comments and handles crop failure without failing the whole response, matching the MCP intent.
- `POST /api/v1/annotations/:annotation_id/comments` creates an API-key-authored comment and returns the new comment JSON.
- 404 and validation failures map to stable machine codes for the CLI.

Verification:
- Rails controller tests pass for the new and existing API endpoints.
- Existing MCP tool tests still pass, proving shared extraction did not regress MCP behavior.
- Existing `POST /api/v1/screenshots` and `PUT /api/screenshots/:id/upload` clients continue to work.

### 2. Screenshot Upload REST Behavior

Goal:
- Ensure `screenote screenshot create` can upload from a file path or stdin against REST with predictable JSON output.

Files:
- `app/controllers/api/v1/screenshots_controller.rb`
- `app/controllers/api/screenshot_uploads_controller.rb`
- `app/models/screenshot.rb`
- `app/models/screenshot_image.rb`
- `test/controllers/api/v1/screenshots_controller_test.rb`
- `test/controllers/api/screenshot_uploads_controller_test.rb`
- `test/fixtures/files/test_image.png`

Approach:
- Keep direct multipart upload as the v1 happy path for CLI stdin and file uploads.
- Preserve the existing signed upload route for compatibility and document it as an API capability, but do not require the CLI to prefer signed upload unless direct upload is unsuitable for large files.
- Accept explicit `--page` or `--page-id` when the REST API supports it; otherwise keep current `Page.find_or_create_by_name!` behavior as a compatibility fallback and document the exact behavior.
- Return `screenshot_id`, `page_id`, `status`, `annotate_url`, and image/viewport metadata where readily available.

Test scenarios:
- Multipart upload with `title` creates a screenshot and attaches the image.
- Multipart upload without image returns validation JSON and does not create a screenshot.
- Upload associates with the requested page when page selection is provided.
- Direct upload response includes all fields needed by the CLI output contract.
- Existing signed-token upload tests remain green.

Verification:
- API tests prove both direct upload and existing signed upload still work.
- Manual next-stage smoke target: create a screenshot against local/staging from stdin and from a file path.

### 3. Go Module, CLI Skeleton, and Configuration

Goal:
- Add an installable Cobra-based CLI with deterministic config resolution and no accidental interactivity.

Files:
- `go.mod`
- `go.sum`
- `cmd/screenote/main.go`
- `internal/cli/root.go`
- `internal/cli/config.go`
- `internal/cli/errors.go`
- `internal/screenote/client.go`
- `internal/screenote/types.go`
- `internal/config/config.go`
- `internal/config/config_test.go`
- `internal/cli/root_test.go`

Approach:
- Use a root module path of `github.com/ivankuznetsov/screenote` to preserve the requested `go install` path.
- Use Cobra for subcommands, persistent flags, help text, and usage errors.
- Implement config resolution in one package:
  - API key: `--api-key`, then `SCREENOTE_API_KEY`, then `~/.config/screenote/config.toml`.
  - Base URL: `--base-url`, then `SCREENOTE_BASE_URL`, then config, then canonical production URL only if already established; otherwise error with code `missing_base_url`.
  - Project: `--project`, then `SCREENOTE_PROJECT`, then config, but allow commands backed by project API keys to omit it when the server can infer the project.
- Add `screenote config` as a noninteractive command family that can print the resolved config as JSON and optionally write config values. Do not prompt unless `--interactive` is explicitly passed.
- Centralize output so successful commands write JSON to stdout and errors write `{"error":"...","code":"..."}` to stderr.
- Map exit codes centrally: 0 ok, 1 generic, 2 usage, 3 auth, 4 not found, 5 rate limited.

Test scenarios:
- Flag values override env values and config file values.
- Env values override config file values.
- Missing base URL fails with usage-style error unless a canonical default is intentionally configured.
- `screenote config` prints JSON and never prompts by default.
- Cobra usage errors exit with code 2 and JSON stderr.
- Auth, not found, rate limit, and generic client errors map to the required exit codes.

Verification:
- `go test ./...` passes in the next execution stage.
- `go install github.com/ivankuznetsov/screenote/cmd/screenote@latest` is structurally supported by the module layout.

### 4. REST Client and V1 Commands

Goal:
- Implement the v1 command surface against REST with stable request and response handling.

Files:
- `internal/screenote/client.go`
- `internal/screenote/client_test.go`
- `internal/screenote/types.go`
- `internal/cli/project.go`
- `internal/cli/page.go`
- `internal/cli/screenshot.go`
- `internal/cli/annotation.go`
- `internal/cli/comment.go`
- `internal/cli/*_test.go`

Approach:
- Implement a small typed REST client using the Go standard `net/http` package.
- Commands:
  - `screenote project list`
  - `screenote page list --project <id>`
  - `screenote screenshot list --project <id> [--page <id>] [--status <status>] [--limit N] [--offset N]`
  - `screenote screenshot create --title <title> [--page <id-or-name>] [--file path]`, reading stdin when `--file` is omitted or set to `-`.
  - `screenote annotation list [--project <id>] [--screenshot <id>] [--status open|resolved] [--viewport desktop|tablet|mobile]`
  - `screenote annotation get --annotation <id> [--project <id>]`
  - `screenote comment add --annotation <id> --body <text> [--project <id>]`
- Do not add human-readable default output. If a later mode is desired, make it opt-in rather than changing v1 defaults.
- Preserve server JSON where possible, adding client-side wrapping only for local errors.
- For `screenshot create`, stream file/stdin into multipart form data without loading unnecessarily large files into memory.

Test scenarios:
- Each command sends the expected method, path, query parameters, headers, and body to an `httptest` server.
- Successful command responses are written unchanged or predictably normalized as JSON to stdout.
- Server 401 maps to exit code 3; 404 maps to 4; 429 maps to 5.
- `screenshot create` reads from stdin and sends multipart content with the expected filename/content type fallback.
- `comment add` validates required `--body` locally and does not send an empty request.
- Commands do not prompt when required input is missing; they return JSON errors.

Verification:
- Go command tests pass.
- Next-stage manual smoke target covers a local Rails server with at least `project list`, `screenshot create < image.png`, `screenshot list`, `annotation list`, and `comment add`.

### 5. Nice-to-Have Command Hooks Without Scope Creep

Goal:
- Leave clear extension points for approved v1 nice-to-haves without making them required for shipping.

Files:
- `app/controllers/api/v1/annotations_controller.rb`
- `internal/cli/annotation.go`
- `internal/screenote/client.go`
- `test/controllers/api/v1/annotations_controller_test.rb`
- `internal/cli/annotation_test.go`

Approach:
- If time remains after must-haves are green, add `annotation resolve` and `annotation reopen` by reusing the existing MCP behavior in `ResolveAnnotationTool` and `ReopenAnnotationTool`.
- Keep multi-viewport upload deferred unless the direct upload path naturally exposes it without destabilizing the v1 CLI.
- Do not document these as guaranteed v1 commands unless implemented and tested.

Test scenarios:
- Resolve/reopen, if implemented, require annotation id and project scope.
- Resolved annotation records who/what resolved it consistently with existing model behavior.
- Reopen transitions only accessible annotations in the key's project.

Verification:
- These commands are omitted from ship criteria unless implemented.
- Docs accurately label unimplemented nice-to-haves as future work.

### 6. Documentation, Release, and CI

Goal:
- Make the CLI installable, testable, and understandable for agentic and CI users.

Files:
- `README.md`
- `wiki/commands.md`
- `wiki/routes.md`
- `wiki/mcp-tools.md`
- `wiki/api-cli.md` or another existing wiki page chosen by repo convention
- `.github/workflows/ci.yml` or existing CI workflow files
- `.goreleaser.yml`

Approach:
- Document install, auth, base URL configuration, command examples, stdin upload, JSON stdout, JSON stderr, and exit codes.
- Include localhost/staging examples and self-hosted configuration. Only include a production default in examples if the repo has a canonical production URL.
- Add CI jobs to run Go tests and cross-compile Linux/macOS amd64/arm64 binaries.
- Add GoReleaser config for GitHub Releases, checksums, and archives. Homebrew tap can be called out as a later distribution channel.
- Keep MCP docs positioned as the rich agent protocol and CLI docs positioned as the shell/CI REST contract.

Test scenarios:
- CI validates `go test ./...`.
- CI validates Go build for `cmd/screenote` on the target OS/arch matrix.
- Release config can generate archives and checksums in dry-run mode in the next stage.
- Docs include examples for each must-have command and the exact error shape.

Verification:
- README and wiki cover all v1 acceptance criteria from the brainstorm.
- CI configuration gives the next stage a clear pass/fail signal for Go code.

## Risks

- **REST and MCP behavior drift:** The MCP tools already encode the richer behavior. Extract shared serializers/query helpers instead of duplicating logic in REST controllers.
- **Auth model mismatch:** Some MCP list tools assume user/OAuth context, while v1 CLI is project API key first. REST endpoints must define project-key behavior explicitly, especially `project list`.
- **Root Go module in Rails repo:** Adding `go.mod` at the root can affect tooling and dependency scanners. Keep Go packages isolated under `cmd/` and `internal/`, and verify existing Ruby workflows ignore Go files unless configured otherwise.
- **Base URL default ambiguity:** A guessed production URL would make scripts brittle. Require explicit base URL unless a canonical URL is already present in repo configuration/docs.
- **Large stdin uploads:** Multipart streaming should avoid reading whole images into memory where practical.
- **Error contract compatibility:** Existing API errors only expose `error`. The CLI needs machine codes; API responses should gain codes carefully so current clients are not broken.
- **Scope expansion pressure:** Multi-viewport, OAuth login, member management, and daemon mode are natural follow-ups but should not block v1.

<!-- COMPLETE -->
