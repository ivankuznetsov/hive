# Artifacts — add-a-go-cli-for-260708-edec

Task: add a Go REST CLI for Screenote and expand the `api/v1` contract.
PR: [#36](https://github.com/ivankuznetsov/screenote/pull/36) (draft) · Review: complete (pass 2, browser skipped).

## Primary artifact — `screenote` Go CLI

The shippable artifact is an installable Go binary that drives Screenote over
REST without an MCP client:

- Install path: `go install github.com/ivankuznetsov/screenote/cmd/screenote@latest`
- Source: `cmd/screenote/main.go`, `internal/cli/*`, `internal/screenote/*`, `internal/config/*`
- Release plumbing: `.goreleaser.yml` (cross-platform builds), CI Go job in `.github/workflows/ci.yml`
- Docs: `README.md` CLI section, `wiki/api-cli.md`

### Build & smoke verification (this stage)

Built and exercised the CLI from the worktree to confirm it is a working artifact
(no source edited):

- `GOFLAGS=-mod=mod GOBIN=/tmp/... go install ./cmd/screenote` (go 1.26.4) — succeeded, ~10 MB binary.
- `screenote --help` / `project --help` / `screenshot create --help` — full Cobra command tree renders.
- Error contract confirmed live:
  - `project list` with no base URL → `{"code":"missing_base_url",...}`, exit **2**
  - unknown command `bogus` → `{"code":"unexpected_arguments",...}`, exit **2**
  - `--base-url ... --project ... config` → resolved JSON with `sources` map, exit **0**

These match the exit-code and JSON-error contract described in the PR (0 ok,
2 usage, 3 auth, 4 not found, 5 rate-limited, 1 generic).

## Supporting artifacts

- Expanded `api/v1` REST surface (projects, pages, screenshots, annotations, comments)
  with shared `Api::V1::ContractSerializer` / `Api::V1::ProjectScope` helpers.
- Controller tests under `test/controllers/api/v1/` and Go tests under `internal/...`.

## Visual demo

Surface is a CLI, recorded under `surface: "tui"`. `vhs`/`asciinema`/`agg` were
not available in this environment, so the demo was rendered from **real captured
CLI output** using `pango-view` (frames) + `ffmpeg` (GIF). See
`media/manifest.json`.

- `media/demo.gif` — progressive session: help → config precedence → machine-readable errors/exit codes.
- `media/01-help.png` — `screenote --help` command tree and global flags.
- `media/02-contract.png` — JSON error contract, exit codes, and flag>env>file config precedence.

Screenote upload is unavailable (not connected; run `hive connect screenote`),
so all `screenote_url` values are `null` and stills carry the not-connected
`screenote_skipped_reason`.

## Notes

- Full `bin/rails test` cannot run here because `libvips.so.42` is missing
  (image dimension/crop tests only); this is environmental and unrelated to the change.
  The targeted `api/v1`, tools, and Go suites passed during execution.

<!-- COMPLETE -->
