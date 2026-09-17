## High

## Medium
- [x] AUTO-FIX: Project-scoped CLI commands refresh stored login credentials before reporting missing project: <!-- triage: plan R8/R2/R10 — resolve project locally before a.client(); confirmed page.go:12-19 calls client() first --> `page list`, `screenshot list/create`, `annotation list/get`, and `comment add` all call `a.client()` before `projectID`, so a no-project invocation can hit OAuth metadata/token endpoints, mutate the config, or return an auth error instead of the required local JSON `missing_project` usage error.

## Nit
- [x] AUTO-FIX: README screenshot list example omits project selection: <!-- triage: doc fix — add --project to example --> the documented `screenote screenshot list --status ready --limit 25` command is project-scoped and will fail with `missing_project` unless a config/env project was set, undercutting the OAuth-first explicit-project contract shown in the surrounding examples.
