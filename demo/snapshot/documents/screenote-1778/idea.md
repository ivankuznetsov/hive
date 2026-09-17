---
slug: replace-screenote-cli-api-key-260708-545b
created_at: 2026-07-08T19:17:49Z
original_text: |
  Replace Screenote CLI API-key authentication with OAuth-first authentication. The current Go CLI PR was planned around project API keys, but the product decision is that the CLI must use OAuth instead. Remove --api-key, SCREENOTE_API_KEY, and api_key config as the primary CLI auth contract. Add deterministic OAuth credential/token handling suitable for agents and CI, with explicit project selection via --project, SCREENOTE_PROJECT, or config when OAuth/user-scoped credentials need project scope. Keep JSON stdout, machine-readable JSON stderr errors, stable exit codes, and no hidden prompts in non-interactive mode. If interactive login is added, gate it behind an explicit command or flag. Update REST/backend auth as needed so the CLI commands work with OAuth bearer tokens, and update docs/tests/release notes.
---

# replace-screenote-cli-api-key-260708-545b

Replace Screenote CLI API-key authentication with OAuth-first authentication. The current Go CLI PR was planned around project API keys, but the product decision is that the CLI must use OAuth instead. Remove --api-key, SCREENOTE_API_KEY, and api_key config as the primary CLI auth contract. Add deterministic OAuth credential/token handling suitable for agents and CI, with explicit project selection via --project, SCREENOTE_PROJECT, or config when OAuth/user-scoped credentials need project scope. Keep JSON stdout, machine-readable JSON stderr errors, stable exit codes, and no hidden prompts in non-interactive mode. If interactive login is added, gate it behind an explicit command or flag. Update REST/backend auth as needed so the CLI commands work with OAuth bearer tokens, and update docs/tests/release notes.

<!-- WAITING -->
