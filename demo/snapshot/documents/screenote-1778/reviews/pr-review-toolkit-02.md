# PR Review (pass 2) — replace-screenote-cli-api-key (OAuth-first CLI auth)

Reviewed `git diff origin/main..HEAD` in the worktree. The `pr-review-toolkit`
plugin is not installed here, so the multi-persona review was reproduced manually
across correctness, security, performance, type-design, api-design, maintainability,
and tests, grounded in code reads plus a live run of the Rails API v1 + bearer
authenticator tests (59 runs, 173 assertions, 0 failures) and `rubocop` (10 files,
0 offenses). The Go toolchain is absent, so Go findings are from code reading only.

Pass-1 findings are all verified fixed: the OAuth `project list` N+1 count is now a
single grouped `Screenshot.joins(:page).group("pages.project_id").count`; token
refresh threads the cobra `cmd.Context()` through `client()`/`storedLoginToken`;
the dead `callbackURL`/`--interactive` code is gone; the callback success body is
written before the result is signaled; and `TestStoredExpiredCredentialsFailedRefreshReturnsAuthError`
covers the exit-3 refresh-failure path.

The change traces cleanly to plan requirements R1–R12. No High-severity defects and
no plan-required-but-missing behavior were found. Residual items below are low-severity.

## High

_(none)_

## Medium
- [x] AUTO-FIX: [correctness] `screenote login` can hang indefinitely: `runLogin` blocks on `select { case <-ctx.Done(); case <-result }`, but `main.go` passes `context.Background()` with no signal or timeout wiring, so if the browser authorization is abandoned or never completes the command never unblocks — only an external Ctrl-C exits: `internal/cli/login.go:126-129`, `cmd/screenote/main.go:11`. <!-- triage: clear fix — wire signal.NotifyContext(SIGINT/SIGTERM) in main.go so abandoned login cancels cleanly -->>
- [x] AUTO-FIX: [correctness] CLI HTTP calls have no timeout: production `NewClient` falls back to `http.DefaultClient` (no `Timeout`) and the root context is never cancelled, so any ordinary command can hang forever against an unresponsive server, weakening the CI/agent determinism goal (R2/R10): `internal/screenote/client.go:48-49`. <!-- triage: clear mechanism serving R2/R10 determinism — construct the default client with a sane Timeout instead of http.DefaultClient -->>

## Nit
- [x] RESOLVED/NO-FIX: [maintainability] `appconfig.Save` re-encodes the entire `config.toml` via the TOML encoder on every `login`/`logout`/`config set`, silently discarding any user comments or formatting in a hand-authored config file: `internal/config/config.go:126-148`. <!-- triage: config is a tool-managed file rewritten by login/logout/config set; comment-preserving TOML round-trip needs a different library/approach, out of scope for this task and not a mechanical fix -->>
- [x] AUTO-FIX: [tests] The OAuth `project list` test only asserts `role.present?` rather than matching each project's actual membership role, so a role-mapping mix-up (e.g. always emitting "member") would still pass: `test/controllers/api/v1/projects_controller_test.rb:37`. <!-- triage: strengthen assertion to match each project's actual membership role — clear test rigor improvement for defined behavior (plan Unit 6: role populated from membership) -->>
