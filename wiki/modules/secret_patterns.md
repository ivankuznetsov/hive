---
title: Hive::SecretPatterns
type: module
source: lib/hive/secret_patterns.rb
created: 2026-04-26
updated: 2026-05-17
tags: [security, secrets, regex, secret-scan, redact]
---

**TLDR**: Shared regex set for credential / secret detection. One Hash, `scan(text)` returns `[{name:, snippet:}, …]`, `redact(text)` returns the string with each match replaced by `[REDACTED:<name>]`. Consumers include `Stages::OpenPr` / `Stages::Finalize` PR-body scans, review PR-comment publishing, `Stages::Review::FixGuardrail`'s post-fix diff scan, and (since PR #84) `TaskAction#diagnostic` / `DiagnosisAgent#artifact_body` redaction. New patterns must come with at least one test in `test/unit/secret_patterns_test.rb`.

## API

```ruby
Hive::SecretPatterns::PATTERNS    # → frozen Hash<Symbol, Regexp>
Hive::SecretPatterns.scan(text)   # → [{name: :aws_access_key, snippet: "AKIA..."}, …]
Hive::SecretPatterns.redact(text) # → String with each match replaced by "[REDACTED:<name>]"
```

`scan` snippets are truncated to 80 characters. `redact` coerces binary input to UTF-8 with invalid bytes replaced (so a binary log tail with `\xff` bytes never raises `Encoding::CompatibilityError` when gsubbed against the UTF-8 PATTERNS regexes — the failure path that previously aborted the entire `hive status --json` snapshot, PR #84 review finding #4).

## Pattern catalogue

| Key | Matches | Notes |
|-----|---------|-------|
| `aws_access_key` | `\b(AKIA|ASIA)[0-9A-Z]{16}\b` | Long-term and temporary session tokens. |
| `aws_secret_access_key` | `aws[_- ]secret[_- ]access[_- ]key…40-byte b64` | Case-insensitive, optional quotes. |
| `github_token` | `gh[psou]_[A-Za-z0-9]{36,}` | PAT (`ghp`), server-to-server (`ghs`), OAuth (`gho`), user (`ghu`). |
| `generic_api_key` | `\bapi[_-]?key\b[\s:=]{0,3}['"]?…20+ chars` | Quoted or unquoted assignments. |
| `pem_private_key` | `-----BEGIN … PRIVATE KEY-----…-----END … PRIVATE KEY-----` (`/m`) | Block form — redacts the base64 body, not just the BEGIN header. PR #84 #3. |
| `password_assignment` | `\b(password|passwd|pwd)\b[\s:=]{0,3}['"]?…6+ chars` | Catches shell / env / YAML assignment shapes. |
| `bearer_token` | `\bauthorization\s*[:=]\s*['"]?(Bearer|Basic|Token)\s+…8+ chars` | HTTP `Authorization:` headers across curl / log / framework formats. |
| `session_cookie` | `(Set-)?Cookie:\s*…(session(id)?|sid|auth)…=…8+` | Cookie / Set-Cookie values containing a session-like key. |
| `openai_api_key` | `\bsk-[A-Za-z0-9]{20,}` | OpenAI API key prefix. |
| `anthropic_api_key` | `\bsk-ant-[A-Za-z0-9_-]{20,}` | Anthropic API key prefix. |
| `stripe_api_key` | `\b(sk|rk|pk)_(live|test)_[A-Za-z0-9]{20,}` | Stripe keys, both live and test. |
| `slack_token` | `\bxox[abprs]-[A-Za-z0-9-]{10,}` | All five Slack token kinds. |
| `jwt` | `\beyJ…\.eyJ…\.[A-Za-z0-9_-]+\b` | Three base64 segments. |

## Used by

- `Hive::Stages::OpenPr` / `Hive::Stages::Finalize` — refuse PR body/state content containing any match (ADR-008).
- `Hive::Stages::Review::GithubPublisher` — skips PR comment mirroring when a reviewer file contains a secret pattern.
- `Hive::Stages::Review::FixGuardrail` — the `secrets_pattern_match` default pattern dispatches to `SecretPatterns.scan` for added lines in the post-fix diff.
- `Hive::TaskAction#diagnostic` — calls `SecretPatterns.redact` on the bounded summary / detail before emission to JSON consumers (TUI, bot, daemon).
- `Hive::DiagnosisAgent#artifact_body` — calls `SecretPatterns.redact` on the agent-produced body before writing `diagnostics/red-status.md`.

## Tests

- `test/unit/secret_patterns_test.rb` — at least one positive + one negative case per pattern.

## Backlinks

- [[stages/open-pr]] · [[stages/finalize]] · [[stages/review]]
- [[decisions]] (ADR-008 / ADR-020)
