---
slug: add-a-go-cli-for-260708-edec
started_at: 2026-07-08T14:38:06Z
---

# add-a-go-cli-for-260708-edec

## Implementation


## Execute Output

Implemented and committed the stage 4 work. Worktree is clean.

Commits created:
- `760c98c feat(api): U1-U2 expand v1 REST contract`
- `c65e071 feat(cli): U3-U4 add Go REST CLI`
- `1f2b4e4 chore(release): U6 document and build CLI`
- `62e4138 fix(cli): stream screenshot upload bodies`

What changed:
- Expanded `api/v1` REST endpoints for projects, pages, screenshots, annotations, and comments with stable JSON error codes.
- Added shared Rails API query/serialization helpers used by REST and MCP annotation serialization.
- Added installable Go CLI under `cmd/screenote` with Cobra commands, config precedence, JSON stdout/stderr, exit-code mapping, stdin/file upload, and `httptest` coverage.
- Added Go module, GoReleaser config, CI Go tests/cross-compile job, README docs, and wiki docs.

Verification run:
- `bin/rails test test/controllers/api/v1 test/controllers/api/screenshot_uploads_controller_test.rb` passed.
- `bin/rails test test/tools` passed.
- `GOFLAGS=-mod=mod mise exec go@1.26.4 -- go test ./...` passed.
- Cross-compile smoke for Linux amd64 and macOS arm64 passed.
- Local install smoke with `GOBIN=/tmp/screenote-go-install ... go install ./cmd/screenote` passed.

Full `bin/rails test` did not pass in this environment because `libvips.so.42` is missing; the failures/errors were in image dimension/crop tests that need that system library.

<!-- COMPLETE -->
