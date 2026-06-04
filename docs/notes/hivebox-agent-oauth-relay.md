---
title: hivebox agent OAuth relay
created: 2026-06-04
---

# hivebox agent OAuth relay

hivebox does not proxy provider login pages. That would put Anthropic/OpenAI
HTML under the hivebox origin and conflicts with normal phishing defenses and
fixed OAuth redirect URI expectations.

The implemented v1 path is B2, a paste-the-code relay:

1. `POST /agents/:agent/login/start` spawns the agent CLI in a PTY.
2. hivebox captures stdout/stderr and extracts the first `http(s)://` URL.
3. The operator opens that real provider URL in their browser.
4. The operator pastes the returned code or full callback URL into hivebox.
5. hivebox writes that text plus a newline into the waiting PTY.
6. The agent CLI writes its own credentials below `$HOME`.

Commands:

- Claude: `claude setup-token`
- Codex: `codex login`
- Pi: web form writes non-empty JSON to `~/.pi/agent/auth.json`

Credential survival is a Docker bind-mount property: hivebox sets
`HOME=/data/home`, so `~/.claude`, `~/.codex`, and `~/.pi` are part of the
operator-provided `/data` mount and survive image upgrades.

B1, callback proxying to a localhost listener, is not implemented because the
CLIs cannot be assumed to allow hivebox's public origin as their redirect URI.
If a future CLI exposes a supported callback-host override, the route can be
added without changing the persisted-token model.
