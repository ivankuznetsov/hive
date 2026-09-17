---
slug: add-a-go-cli-for-260708-edec
created_at: 2026-07-08T11:09:07Z
original_text: |
  Add a Go CLI for Screenote that is easy to install and use. The CLI should live in this repo, be written in Go, and provide a clean command surface for common Screenote workflows such as authentication/configuration, creating or uploading screenshots/notes when supported by existing APIs, listing/retrieving recent screenshots or annotations, and printing helpful errors. Design it as a small distributable binary with conventional Go module layout, tests for command parsing and API client behavior, docs in README/wiki, and an easy install path such as go install github.com/ivankuznetsov/screenote/cmd/screenote@latest plus release/package guidance. Reuse existing Screenote auth/API concepts instead of inventing a new backend contract, and keep the Rails app behavior unchanged except for any API/documentation support required by the CLI.
---

# add-a-go-cli-for-260708-edec

Add a Go CLI for Screenote that is easy to install and use. The CLI should live in this repo, be written in Go, and provide a clean command surface for common Screenote workflows such as authentication/configuration, creating or uploading screenshots/notes when supported by existing APIs, listing/retrieving recent screenshots or annotations, and printing helpful errors. Design it as a small distributable binary with conventional Go module layout, tests for command parsing and API client behavior, docs in README/wiki, and an easy install path such as go install github.com/ivankuznetsov/screenote/cmd/screenote@latest plus release/package guidance. Reuse existing Screenote auth/API concepts instead of inventing a new backend contract, and keep the Rails app behavior unchanged except for any API/documentation support required by the CLI.

Additional direction: design the CLI agentic-first. Agents should be the primary users, so commands must be scriptable, deterministic, composable, and friendly to non-interactive automation. Prefer structured output modes such as JSON/NDJSON where useful, stable exit codes, explicit auth/config discovery, machine-readable errors, stdin/stdout workflows, no hidden prompts unless requested, and documentation/examples aimed at coding agents and MCP/tool callers.

<!-- WAITING -->
