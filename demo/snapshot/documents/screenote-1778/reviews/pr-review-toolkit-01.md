# PR Review — replace-screenote-cli-api-key (OAuth-first CLI auth)

Reviewed `git diff origin/main..HEAD` in the worktree. Note: the `pr-review-toolkit`
plugin is not installed in this environment; the multi-persona review was reproduced
manually across correctness, security, performance, type-design, api-design,
maintainability, and tests personas, grounded in code reads plus a live run of the
Rails API v1 tests (47 runs, 0 failures), MCP tool tests (75 runs, 0 failures),
`rubocop` (0 offenses), and `brakeman` (no warnings). Go tests could not be executed
(`go` toolchain absent), so Go findings are from code reading only.

Overall the change is high quality and traces cleanly to plan requirements R1–R12.
No High-severity defects and no missing plan-required behavior were found.

## High

_(none)_

## Medium
- [x] AUTO-FIX: [performance] `ContractSerializer.project` calls `project.screenshots.count` <!-- triage: duplicate of claude N+1 finding; clear perf mechanism --> (a SQL COUNT) per project, and `ProjectsController#index` maps it over every membership — an N+1 count query for OAuth `project list`: `app/serializers/api/v1/contract_serializer.rb:11` / `app/controllers/api/v1/projects_controller.rb:9`.
- [x] AUTO-FIX: [correctness] CLI token-refresh during ordinary commands runs on `context.Background()` <!-- triage: obvious fix — thread cmd.Context() into client()/storedLoginToken --> via `cmdContext()` instead of the cobra command context, so a refresh HTTP call ignores parent cancellation/timeout/Ctrl-C: `internal/cli/root.go:88,102-104`.

## Nit
- [x] AUTO-FIX: [dead-code] `callbackURL` in `internal/cli/login.go:183-187` <!-- triage: duplicate of claude dead-code finding --> is never referenced in production or tests — dead function.
- [x] AUTO-FIX: [api-design] The persistent `--interactive` flag is bound to `a.interactive` but never read anywhere; <!-- triage: confirmed root.go:57 flag never read — remove dead flag --> it is advertised as "Allow interactive prompts" yet has no effect: `internal/cli/root.go:57`.
- [x] RESOLVED/NO-FIX: [maintainability] `screenote login` calls `RegisterOAuthClient` on every invocation, <!-- triage: repo code — redirect URI uses a fresh random loopback port each login (login.go:98), so a stored client_id would not match; reuse is non-trivial and server-side row cleanup is out of plan scope --> creating a fresh Doorkeeper dynamic client each time rather than reusing the stored `client_id`; repeated logins accumulate orphaned `Doorkeeper::Application` rows server-side: `internal/cli/login.go:99`.
- [x] AUTO-FIX: [maintainability] In `callbackHandler` the browser success body is written after the code is pushed to the result channel, <!-- triage: obvious fix — write response body before signaling result channel --> and `runLogin` defers `server.Shutdown`; the shutdown can race ahead of the response write, occasionally truncating the "login complete" page: `internal/cli/login.go:121,177-179`.
- [x] RESOLVED/NO-FIX: [consistency] `resolve_page` accepts a project-scoped numeric page via `params[:page_id]` or `params[:page]`, <!-- triage: repo code — harmless extra server-side param flexibility, not a defect and not plan-required; no behavior change needed --> but the CLI only ever sends the `page` field (`internal/screenshot/client.go` writes `page`), so the `page_id` branch in `app/controllers/api/v1/screenshots_controller.rb` is server-only surface with no CLI test exercising it.
- [x] AUTO-FIX: [tests] Plan IU4 lists "failed refresh returns JSON auth error exit code 3" as a scenario; <!-- triage: missing test for explicit plan IU4 scenario --> login/oauth tests cover login, state mismatch, successful refresh, explicit-token-skips-refresh, and logout, but there is no explicit test asserting the exit-3/`invalid_token` path when refresh fails: `internal/cli/login_test.go`.
