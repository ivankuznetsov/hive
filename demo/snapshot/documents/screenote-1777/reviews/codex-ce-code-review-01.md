## High
- [x] AUTO-FIX: Cobra parse errors return generic exit code 1 instead of usage exit code 2: `Execute` sends every `cmd.ExecuteContext` error through `writeError`, and `writeError` only maps custom/client errors, so unknown flags or bad flag values violate the required CLI error contract. <!-- triage: plan Unit 3 test scenario requires "Cobra usage errors exit with code 2"; map flag-parse errors to ExitUsage -->

## Medium
- [x] AUTO-FIX: Invalid base URL configuration returns a generic error instead of a usage/config error: `screenote.NewClient` errors from `internal/cli/root.go:84` fall through `writeError` as `internal_error` with exit 1, despite malformed `--base-url`/config being a usage-style failure. <!-- triage: wrap NewClient config error as usageError (exit 2), consistent with error contract -->
- [x] AUTO-FIX: Malformed pagination parameters can bypass stable JSON API errors: `pagination_params` calls `to_i` on raw params in `app/controllers/api/base_controller.rb:50`, so structured values such as `limit[x]=1` raise instead of returning machine-readable validation JSON. <!-- triage: plan wants stable JSON errors; coerce/guard param types so malformed values return validation JSON not a 500 -->
- [x] AUTO-FIX: Malformed screenshot upload payloads can bypass stable JSON API errors: `app/controllers/api/v1/screenshots_controller.rb:34` assumes any present `image` param has `tempfile`, `original_filename`, and `content_type`, so `image=not-file` raises instead of returning validation JSON. <!-- triage: guard that image param is an uploaded file, else return validation JSON — aligns with stable-error contract -->

## Nit
