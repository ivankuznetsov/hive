# Artifacts — replace-screenote-cli-api-key-260708-545b

## Task

Replace the Screenote CLI's project-scoped API-key auth with OAuth bearer tokens,
while the REST v1 API keeps accepting API keys for existing callers.

## Release artifacts

- **Pull request:** [#37](https://github.com/ivankuznetsov/screenote/pull/37) (draft).
- **Branch:** `replace-screenote-cli-api-key-260708-545b` (5 task commits on top of the
  merged draft Go CLI).
- **No separately-published artifacts.** There is no new binary release, container
  image, or package tag produced by this task. The Go CLI is built from source via
  the existing `.goreleaser.yml` / CI Go job; this PR does not cut a release. The
  key deliverable is the source diff and its documentation:
  - CLI packages: `cmd/screenote`, `internal/cli`, `internal/config`, `internal/screenote`.
  - REST auth: `app/controllers/api/base_controller.rb`, `app/services/api/bearer_authenticator.rb`,
    `app/services/api/v1/project_scope.rb`, `app/serializers/api/v1/contract_serializer.rb`.
  - Docs: `README.md`, `wiki/api-cli.md`, `wiki/controllers/api-controllers.md`, `wiki/routes.md`.

## Validation (from prior stages)

- `mise exec -- go test -mod=mod ./...` — passed (token precedence, project requirement,
  PKCE/login callback, refresh, logout).
- REST v1 controller suite — passed (47 runs, 145 assertions): API-key compatibility,
  OAuth acceptance, scope enforcement, project-membership checks.
- Full `bin/rails test` fails only on a pre-existing environment issue (missing
  `libvips.so.42`), unrelated to this change.
- Review: 2 passes complete; browser review skipped (no web UI surface).

## Visual demo (best-effort)

Surface is a **CLI/TUI** (`screenote` Go binary), captured under `media/` as
`surface: "tui"`.

The CLI was built from the worktree (`go build -mod=mod ./cmd/screenote`) and driven
to capture the auth-contract change. Real command output was rendered into terminal-style
stills plus a looping GIF (ImageMagick; no `vhs`/`asciinema`/`agg` available, so frames
were composited from captured output rather than a live screen recording):

- `01-help.png` — command surface: `--token` (OAuth bearer), `login`, `logout`; the old
  `--api-key` flag is gone.
- `02-oauth-token.png` — `missing_token` JSON error (exit 2) and `config` showing the
  resolved token source = `flag`.
- `03-login-logout.png` — `screenote login` OAuth flow summary and idempotent `logout`.
- `demo.gif` — cycles the three panels.

Observed behavior confirms the change: project-scoped commands demand an OAuth bearer
token (`--token` / `SCREENOTE_TOKEN` / config `token` / stored login) and emit the
machine-readable `missing_token` / `missing_project` JSON errors with exit code 2; no
API-key surface remains on the CLI.

Screenote upload is unavailable (not connected; run `hive connect screenote`), so every
still's `screenote_url` is `null` with `screenote_skipped_reason` recorded; the GIF is
kept local. See `media/manifest.json`.

<!-- COMPLETE -->
