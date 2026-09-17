# Code Review — add-a-go-cli-for-260708-edec (Pass 1)

Scope: `git diff origin/main..HEAD` (43 files: Go CLI under `cmd/`+`internal/`, `api/v1` REST expansion, wiki/docs, CI, GoReleaser).
Intent: Ship an installable Go REST CLI plus the `api/v1` endpoints it needs, mirroring MCP behavior via shared serializers/scopes.
All must-have commands (A3) and the exit-code/output contract (A6) are present; no plan-required item is missing.

## High

_None._

## Medium
- [x] AUTO-FIX: `annotation list` without `--screenshot` silently caps at 100 screenshots and misreports pagination (`internal/cli/annotation.go`): it fetches screenshots via `WithLimitOffset(Query(nil), 100, 0)` then loops one request per screenshot, so annotations on the 101st+ screenshot are dropped with no warning; `--limit`/`--offset` are forwarded into each per-screenshot query (limiting each screenshot's slice, not the aggregate), and the emitted `pagination.total` is just `len(annotations)` — an agent gets incomplete data that looks complete. <!-- triage: real defect confirmed, all 3 reviewers agree; plan A6 warns against silent truncation — page all screenshots, apply limit/offset to aggregate, report true total -->
- [x] AUTO-FIX: N+1 query in `ContractSerializer.screenshot` (`app/serializers/api/v1/contract_serializer.rb:513`): `screenshot.screenshot_images.order(:viewport)` builds a new relation and ignores the `includes(:screenshot_images)` preload from `ProjectScope.screenshots`, issuing one query per screenshot in `screenshot list`; sort the preloaded records in Ruby (e.g. `sort_by(&:viewport)`) to keep the eager load. <!-- triage: confirmed at line 36; clear mechanism, sort preloaded records in Ruby -->

## Nit
- [x] AUTO-FIX: Dead code: `fileExists` in `internal/cli/root.go:133` is defined but never referenced anywhere in the tree; remove it (it also pulls `os` into the file solely for this unused helper). <!-- triage: dead code removal -->
- [x] AUTO-FIX: `screenshot create` never sets the image content type (`internal/cli/screenshot.go` passes `""` to `CreateScreenshot`, which defaults to `application/octet-stream`): it works only because ActiveStorage re-identifies from bytes via Marcel (`Screenshot#acceptable_image` allows PNG/JPEG); deriving the type from the file extension would be more explicit and robust, and there is no test asserting a real content type. <!-- triage: robustness polish; derive content type from file extension for file uploads, keep octet-stream fallback for stdin, add test — satisfies plan Unit 4 content-type-fallback scenario -->
- [x] AUTO-FIX: Unreachable branch in `writeRawJSON` (`internal/cli/root.go:1267-1274`): after `raw = []byte("{}")` when empty, the later `len(raw) == 0` check can never be true, so the trailing-newline guard's first clause is dead. <!-- triage: dead branch simplification -->
- [x] RESOLVED/NO-FIX: Inconsistent cross-project rejection code: mismatched `:project_id` on pages/screenshots returns `403 forbidden` (`require_current_project!`), while cross-project annotation/comment access returns `404 not_found` (scope join). Both are plan-permitted, but a single convention would give the CLI one predictable code to map. <!-- triage: plan Unit 1 explicitly permits "forbidden or not found"; 403-on-explicit-mismatch vs 404-on-scope-miss is a reasonable semantic distinction, not a defect -->
