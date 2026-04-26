---
title: Hive::SecretPatterns
type: module
source: lib/hive/secret_patterns.rb
created: 2026-04-26
updated: 2026-04-26
tags: [security, secrets, regex, secret-scan]
---

**TLDR**: Shared regex set for credential / secret detection. One Hash, one `scan(text)` method that returns `[{name:, snippet:}, …]`. Two consumers: `Stages::Pr`'s body secret-scan (ADR-008) and `Stages::Review::FixGuardrail`'s post-fix diff scan (ADR-020). New patterns must come with at least one test in `test/unit/secret_patterns_test.rb` (or a consumer's tests).

## API

```ruby
Hive::SecretPatterns::PATTERNS    # → frozen Hash<Symbol, Regexp>
Hive::SecretPatterns.scan(text)   # → [{name: :aws_access_key, snippet: "AKIA..."}, …]
```

Snippets are truncated to 80 characters so callers can include them in error messages without leaking long secrets to logs.

## Pattern catalogue

| Key | Matches | Notes |
|-----|---------|-------|
| `aws_access_key` | `\b(AKIA|ASIA)[0-9A-Z]{16}\b` | Long-term and temporary session tokens. |
| `aws_secret_access_key` | `aws[_- ]secret[_- ]access[_- ]key…40-byte b64` | Case-insensitive, optional quotes. |
| `github_token` | `gh[psou]_[A-Za-z0-9]{36,}` | PAT (`ghp`), server-to-server (`ghs`), OAuth (`gho`), user (`ghu`). |
| `generic_api_key` | `\bapi[_-]?key\b[\s:=]{0,3}['"]?…20+ chars` | Quoted or unquoted assignments. |
| `pem_private_key` | `-----BEGIN (RSA|OPENSSH|EC|DSA|PGP)? PRIVATE KEY( BLOCK)?-----` | All PEM private-key flavors. |
| `openai_api_key` | `\bsk-[A-Za-z0-9]{20,}` | OpenAI API key prefix. |
| `anthropic_api_key` | `\bsk-ant-[A-Za-z0-9_-]{20,}` | Anthropic API key prefix. |
| `stripe_api_key` | `\b(sk|rk|pk)_(live|test)_[A-Za-z0-9]{20,}` | Stripe keys, both live and test. |
| `slack_token` | `\bxox[abprs]-[A-Za-z0-9-]{10,}` | All five Slack token kinds. |
| `jwt` | `\beyJ…\.eyJ…\.[A-Za-z0-9_-]+\b` | Three base64 segments. |

## Used by

- `Hive::Stages::Pr.scan_body_for_secrets!` — refuses to push a PR body containing any match (ADR-008).
- `Hive::Stages::Review::FixGuardrail` — the `secrets_pattern_match` default pattern dispatches to `SecretPatterns.scan` for added lines in the post-fix diff.

## Tests

- `test/unit/secret_patterns_test.rb` — at least one positive + one negative case per pattern.

## Backlinks

- [[stages/pr]] · [[stages/review]]
- [[decisions]] (ADR-008 / ADR-020)
