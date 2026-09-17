# Escalations for pass 02

## Round 1

### Q1. Should `screenote config` mask the resolved API key in its JSON output, and if so, behind an opt-in flag?
Source: claude-ce-code-review-02.md (Nit / security), pr-review-toolkit-02.md (Nit / security)
Finding: `screenote config` prints the resolved API key verbatim to stdout (`internal/cli/config.go` → `writeJSON(a.stdout, resolved)`; `appconfig.Values.APIKey` serializes as `api_key`), a footgun for CI logs.
Context checked: plan Unit 3 ("`screenote config` ... print the resolved config as JSON"), brainstorm A4/A6 (config precedence; no prompts unless `--interactive`), pass-1 escalation Q1 (same finding — its answer A1 was left blank), and `internal/cli/config.go` / `internal/config/config.go`.
Why not auto-fixable: The plan deliberately makes `config` print the resolved configuration so users can verify what was resolved, but never decided whether secrets should be masked. Masking changes documented behavior and has several valid shapes (mask always / mask unless `--show-secrets` / leave as-is) — a product/security posture call. It was escalated in pass 1 and never answered.
Suggested default: Mask the API key by default (e.g. `sk_proj_…abcd`) and add an opt-in `--show-secrets` flag that prints it verbatim — preserves the debugging utility while avoiding accidental CI-log leakage.
### A1.
Use OAuth for the CLI, not project API keys.

This supersedes the earlier brainstorm/plan assumption that v1 CLI auth should be project-API-key first. The CLI should not expose or depend on `SCREENOTE_API_KEY`, `--api-key`, or an `api_key` field in `screenote config` as its primary auth contract. Replace the API-key config/output path with OAuth-oriented credentials/token handling suitable for agents and CI.

Desired shape:
- CLI authentication should be OAuth-based.
- `screenote config` must not print API keys because API keys are not the CLI auth model.
- Use explicit project selection where OAuth/user-scoped credentials need it (`--project`, `SCREENOTE_PROJECT`, or config).
- Keep command output agentic: JSON stdout, machine-readable JSON errors, no hidden prompts in non-interactive mode.
- If an interactive login flow is added, gate it behind an explicit command/flag; non-interactive agents should be able to provide/use existing OAuth credentials deterministically.
