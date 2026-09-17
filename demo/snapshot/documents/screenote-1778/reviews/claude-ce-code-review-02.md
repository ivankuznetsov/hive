# Code Review — Pass 2 (OAuth-first Screenote CLI authentication)

Scope: `git diff origin/main..HEAD` (merge-base `4f4c82d`). Diff includes the merged draft Go CLI plus the OAuth-first work. Reviewed against the plan's Requirements Trace (R1–R12) and scope boundaries.

Verdict: **Ready to merge.** The implementation fully satisfies R1–R12. Dual bearer auth (API key + Doorkeeper OAuth) is correct, OAuth requests validate project membership (no object-ID-only authorization), scopes are enforced exactly (no implicit `mcp_write`→`mcp_read` grant), CLI token precedence and refresh semantics are right, ordinary commands never open a browser or prompt, and exit codes/JSON contract are stable. Test coverage is comprehensive on both the Rails and Go sides and maps directly to the plan's per-unit test scenarios. Two independent reviewers (Rails security/correctness; Go security/correctness) found no P0/P1/P2 that survives scrutiny. Only minor items below.

## High
- _None._

## Medium
- _None._

## Nit
- [x] RESOLVED/NO-FIX: `internal/config/config.go:15` / `internal/cli/config.go:18` — `screenote config` echoes the resolved top-level `token` value verbatim to stdout: plan-sanctioned (Unit 1 explicitly permits the CI token value; stored login creds are correctly excluded via `json:"-"`), but masking to `token_set: true` + `sources.token` would avoid leaking a live bearer token through pasted CLI output/logs. <!-- triage: plan Unit 1 explicitly sanctions echoing the top-level CI token value (reviewer agrees plan-sanctioned); masking would break expected CI-verification behavior -->>
- [x] AUTO-FIX: `internal/screenote/client.go:119` — `CreateScreenshot`'s producer goroutine leaks (and holds the open upload file) if `doJSON`'s `http.NewRequestWithContext` returns before draining the `io.PipeReader`; effectively unreachable today (constant `POST`, pre-validated base URL), so cosmetic — a `defer pr.Close()` after the call would make it robust to future refactors. <!-- triage: simple robustness fix with obvious right answer -->>
- [x] AUTO-FIX: `internal/cli/login.go:120` — `defer server.Shutdown(context.Background())` has no timeout; a stuck loopback callback connection could hang `login` after Ctrl-C. Bound it with `context.WithTimeout(..., 2*time.Second)`. <!-- triage: simple mechanical hardening fix with obvious right answer -->>
- [x] AUTO-FIX: `internal/cli/root.go:129` — stored-credential base-URL guard is exact-string and trailing-slash sensitive (`https://x` vs `https://x/`), forcing an unnecessary re-login; fails closed so no security impact. Normalize (parse + trim trailing slash) before comparing. <!-- triage: simple normalization fix with clear mechanism -->>
- [x] AUTO-FIX: `internal/cli/root.go:139` / `internal/config/config.go:27` — refresh re-discovers OAuth metadata from `resolved.BaseURL` and never reads the `Issuer` captured at login; either validate `metadata.Issuer == credentials.Issuer` before refreshing or drop the unused `Issuer` field. <!-- triage: clear cleanup; validate stored issuer against rediscovered metadata (safer default) or drop the dead field -->>
