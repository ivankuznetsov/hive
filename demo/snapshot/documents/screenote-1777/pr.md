---
pr_url: https://github.com/ivankuznetsov/screenote/pull/36
pr_number: 36
---

# feat(cli): add Go REST CLI and expand v1 API contract

## Summary

Screenote can now be driven from a shell or CI script without an MCP client. `go install github.com/ivankuznetsov/screenote/cmd/screenote@latest` installs a Cobra-based CLI that talks to the REST API, emits JSON on stdout, and reports machine-readable errors on stderr with stable exit codes. MCP remains the rich agent protocol; the CLI is the scriptable REST counterpart, and both share the same query and serialization behavior.

## Test plan

- `bin/rails test test/controllers/api/v1 test/controllers/api/screenshot_uploads_controller_test.rb` — pass
- `bin/rails test test/tools` — pass (MCP behavior unregressed)
- `go test ./...` — pass
- Cross-compile smoke for Linux amd64 and macOS arm64 — pass
- `go install ./cmd/screenote` into a scratch `GOBIN` — pass

## Review summary

Two automated review passes ran against the diff. No High or Medium findings remain open. Fixed items include aggregate `annotation list` paging/total, error propagation, serializer N+1s, usage exit codes, stable validation JSON, and content-type derivation; tests added for the aggregate path and content-type derivation. One open product decision (`screenote config` prints the resolved API key; future move to OAuth CLI auth) is a deferred follow-up outside this v1 change.

## Linked task

- Slug: `add-a-go-cli-for-260708-edec`

<!-- COMPLETE pr_url=https://github.com/ivankuznetsov/screenote/pull/36 is_draft=false -->
