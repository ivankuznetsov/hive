# Escalations for pass 01

## Round 1

### Q1. Should `screenote config` mask the resolved API key in its JSON output, and if so, behind an opt-in flag?
Source: pr-review-toolkit-01.md (Nit / security)
Finding: `screenote config` prints the resolved API key in plaintext to stdout (`internal/cli/config.go` → `writeJSON(resolved)`, `Values.APIKey` serializes as `api_key`), a footgun for CI logs.
Context checked: plan Unit 3 ("`screenote config` ... print the resolved config as JSON"), brainstorm A4/A6 (config precedence, no prompts unless `--interactive`), and the code in `internal/cli/config.go` / `internal/config/config.go`.
Why not auto-fixable: The plan intentionally makes `config` print the resolved configuration as JSON (its purpose is to let users verify what got resolved, including the key), but it never decided whether secrets should be masked. Masking changes documented behavior and has several valid shapes (mask always / mask unless `--show-secrets` / leave as-is). This is a product/security posture call.
Suggested default: Mask the API key by default (e.g. `sk_proj_…abcd`) and add an opt-in `--show-secrets` flag that prints it verbatim — keeps the debugging utility while avoiding accidental CI-log leakage.
### A1.
