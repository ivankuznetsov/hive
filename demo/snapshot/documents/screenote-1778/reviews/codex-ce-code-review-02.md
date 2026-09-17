## High

## Medium
- [x] RESOLVED/NO-FIX: `screenote login` can emit non-JSON stderr on browser-launch failure: `internal/cli/login.go:123` writes plain text instructions to stderr while the CLI contract requires machine-readable JSON stderr. <!-- triage: brainstorm A5/A8 + plan R10 scope the machine-readable-JSON-stderr contract to non-interactive commands; login is an explicitly interactive command and the browser-fallback prompt is appropriate human-facing UX (JSON stdout ok:true is preserved) -->>

## Nit
