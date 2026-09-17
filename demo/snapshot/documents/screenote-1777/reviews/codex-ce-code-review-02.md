## High
- [x] AUTO-FIX: Cobra usage errors still fall through as generic failures: `internal/cli/root.go:41` only wraps flag parse errors, and leaf commands such as `internal/cli/project.go:7`, `internal/cli/page.go:7`, and `internal/cli/screenshot.go:17` do not set `Args`, so unknown commands or stray positional args violate the required JSON usage-error contract and exit as code 1 or run anyway instead of exit code 2. <!-- triage: plan A6 mandates exit 2 for usage errors; set cobra.NoArgs and map command-resolution errors to usageError -->>

## Medium
- [x] AUTO-FIX: Project-wide `annotation list` can silently drop server failures: `internal/cli/annotation.go:51` skips every `allAnnotations` error with `continue`, so a 429/500/401 from one screenshot is reported as a successful partial JSON result instead of mapping to the required stable error and exit code. <!-- triage: duplicate of claude-ce Medium (error-swallow); same 404-only fix -->>
- [x] RESOLVED/NO-FIX: Project-wide annotation pagination is not the REST/MCP ordering contract: `internal/cli/annotation.go:43` pages screenshots first and then appends each screenshot's annotations at `internal/cli/annotation.go:51`, so `--limit`/`--offset` are applied to screenshot-grouped data rather than the API's global `created_at` annotation ordering. <!-- triage: plan/API — no project-wide annotation endpoint exists; annotations are ordered per-screenshot, so no global created_at contract is defined; screenshot-grouped aggregation is deterministic and acceptable -->>

## Nit
