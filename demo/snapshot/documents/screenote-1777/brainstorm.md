# add-a-go-cli-for-260708-edec

Grounding notes (from the repo, so the questions are concrete):
- Existing REST API is thin: `POST /api/v1/screenshots` (create + direct image),
  `GET /api/v1/screenshots/:id/annotations` (index), `PUT /api/screenshots/:id/upload`
  (signed-token upload). Auth = project API key via `Authorization: Bearer sk_proj_...`.
- A rich **MCP server** already exists (17 FastMCP tools) covering projects, pages,
  screenshots, multi-viewport upload, annotations, comments, resolve/reopen,
  collaboration. Transport auth accepts project API keys *or* OAuth 2.1 bearer tokens
  (OAuth requires an explicit `project_id`), rate-limited 60 req/min.
- So Screenote already has a machine/agent contract (MCP). The core design question is
  what a Go CLI adds on top, and which contract it drives.

## Round 1
### Q1. Screenote already exposes two agent-facing surfaces: a thin REST API and a full 17-tool MCP server. Since agents (the stated primary users) can already call MCP directly, what is the CLI's distinct value in v1 — shell/CI pipelines and stdin/stdout composition, environments without an MCP client, human ergonomics, or something else? And which backend contract should the CLI drive: the existing REST API only, the MCP endpoint, or both?
### A1.
The CLI's distinct v1 value is shell/CI automation and agent environments that do not have an MCP client. It should be deterministic, stdin/stdout-friendly, easy to install, and useful from scripts.

The CLI should drive REST, not MCP. REST should reuse the same backend capabilities that MCP already exposes, so MCP remains the rich agent protocol and the CLI becomes the portable shell contract.

### Q2. The seed permits "API/documentation support required by the CLI." The current REST surface only supports create-screenshot, list-annotations, and signed upload — it can't back commands like list-projects/pages/screenshots or get/create/resolve annotations. Is adding new `api/v1` REST endpoints (mirroring existing MCP tools) in-scope for this work, or must the v1 CLI stay strictly within today's three REST endpoints (and thus have a small command surface)?
### A2.
Adding new `api/v1` REST endpoints is in scope. A v1 CLI limited to the current three REST endpoints would not be useful enough for agentic workflows. Prefer mirroring the existing MCP capabilities through shared service/query code rather than duplicating business logic.

### Q3. Which commands are must-have for v1 vs deferred? Candidate surface: `auth`/`config`, `screenshot create` (direct + signed-upload flow; single vs multi-viewport), `screenshot list`, `project list`, `page list`, `annotation list`/`get`/`create`/`resolve`/`reopen`, `comment add`, project members/invitations. Please tier these into v1 must-have, v1 nice-to-have, and out-of-scope.
### A3.
V1 must-have:
- `config`
- `project list`
- `page list`
- `screenshot create`
- `screenshot list`
- `annotation list`
- `annotation get`
- `comment add`

V1 nice-to-have:
- `annotation resolve`
- `annotation reopen`
- multi-viewport upload

Out of scope:
- project members and invitations
- browser/OAuth login flow
- daemon/watch mode

### Q4. Auth & config discovery: v1 supports project API keys (`sk_proj_...`, project-scoped), OAuth 2.1 bearer tokens (user-scoped, need explicit `project_id`), or both? Please confirm the discovery/precedence chain — env var name(s) (e.g. `SCREENOTE_API_KEY`), config file path & format (e.g. `~/.config/screenote/config.toml`), and `--api-key` flag — and how the active project is selected (implicit from API key vs `--project`/`SCREENOTE_PROJECT`).
### A4.
V1 supports project API keys first. OAuth bearer-token support can be deferred unless an existing endpoint makes it nearly free.

Precedence:
1. `--api-key`
2. `SCREENOTE_API_KEY`
3. `~/.config/screenote/config.toml`

Active project is implicit from a project API key when possible. If a command needs explicit project selection, use `--project`, then `SCREENOTE_PROJECT`, then config.

### Q5. Base URL / deployment targets: Should the CLI default to a hosted endpoint (e.g. `https://screenote.com`), require an explicit `--base-url`/`SCREENOTE_BASE_URL`, and/or support self-hosted instances? Is there a dev/localhost default? This affects auth discovery and docs examples.
### A5.
Support `--base-url` and `SCREENOTE_BASE_URL`.

Default to a hosted production endpoint only if the app already has a canonical production URL. Otherwise require an explicit base URL and document localhost examples. Self-hosted instances should be supported from v1 by treating base URL as normal configuration.

### Q6. Agentic output & error contract (defaults matter for determinism): Is output JSON-to-stdout by default, or human-readable with an opt-in `--json`/`--format ndjson`? What is the exit-code taxonomy (propose: 0 ok, 2 usage error, 3 auth, 4 not-found, 5 rate-limited/429, 1 generic)? What machine-readable error shape (e.g. `{"error": "...", "code": "..."}` on stderr)? Should image upload support stdin (e.g. `screenote screenshot create --title X < img.png`)? Confirm: no interactive prompts unless a flag like `--interactive` is passed.
### A6.
Agentic default: JSON to stdout by default. Machine-readable errors go to stderr. No interactive prompts unless `--interactive` is passed.

Exit codes:
- `0` ok
- `1` generic failure
- `2` usage error
- `3` auth failure
- `4` not found
- `5` rate limited / 429

Error shape should be stable, for example `{"error":"message","code":"machine_code"}`. Image upload should support stdin, e.g. `screenote screenshot create --title X < img.png`.

### Q7. Repo layout & distribution: `go install github.com/ivankuznetsov/screenote/cmd/screenote@latest` implies a `go.mod` at the root of this Rails repo. Is a root-level Go module acceptable, or should Go live in a subdirectory (which would change the install path)? Preferred command framework (stdlib `flag`, `cobra`, `urfave/cli`)? Release/packaging target (GoReleaser + GitHub Releases, Homebrew tap, checksums)? Minimum Go version and OS/arch matrix?
### A7.
Use a root-level Go module if the desired install path is `go install github.com/ivankuznetsov/screenote/cmd/screenote@latest`.

Use Cobra for command ergonomics and maintainable subcommands. Distribution target: GoReleaser, GitHub Releases, checksums, and later Homebrew tap. Support Linux and macOS on amd64 and arm64. Choose the current stable Go version used by repo tooling.

### Q8. Acceptance criteria / definition of done for v1: What must be true to ship — e.g. `go install` path works, the v1 command set functions against a live/staging Screenote, unit tests for command parsing + API-client behavior (httptest-based), docs in README + `wiki/`, CI cross-compiling binaries? And explicit non-goals to lock scope (e.g. no annotation image rendering, no watch/daemon mode, no browser/OAuth-login flow, no write-side annotation ops)?
### A8.
Done means:
- `go install github.com/ivankuznetsov/screenote/cmd/screenote@latest` works
- v1 commands work against local/staging Screenote
- command parsing and API-client behavior have focused tests using `httptest`
- README and wiki docs cover install, auth, examples, JSON/error contract, and stdin upload
- CI builds/cross-compiles release binaries

Explicit non-goals:
- annotation image rendering
- daemon/watch mode
- browser/OAuth login flow
- project member/invitation management

<!-- COMPLETE -->
