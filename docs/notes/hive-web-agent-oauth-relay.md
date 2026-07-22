---
title: Hive web agent OAuth relay
created: 2026-06-04
---

# Hive web agent OAuth relay

Hive web does not proxy provider login pages. That would put Anthropic/OpenAI
HTML under the Hive web origin and conflicts with normal phishing defenses and
fixed OAuth redirect URI expectations.

The implemented v1 path is B2, a paste-the-code relay:

1. `POST /agents/:agent/login` spawns the agent CLI in a PTY.
2. Hive web captures stdout/stderr and extracts the first `http(s)://` URL.
3. The operator opens that real provider URL in their browser.
4. The operator pastes the returned code or full callback URL into Hive web.
5. Hive web writes that text plus a newline into the waiting PTY.
6. The agent CLI writes its own credentials below `$HOME`.

Commands:

- Claude: `claude setup-token`
- Codex: `codex login --device-auth`
- Pi: web form writes non-empty JSON to `~/.pi/agent/auth.json`
- Grok: `grok login --device-auth` or `XAI_API_KEY`

In the Hivebox distribution, credential survival is a Docker bind-mount
property: Hivebox sets
`HOME=/data/home`, so `~/.claude`, `~/.codex`, `~/.pi`, and `~/.grok` are part of the
operator-provided `/data` mount and survive image upgrades.

B1, callback proxying to a localhost listener, is not implemented because the
CLIs cannot be assumed to allow the configured Hive web origin as their redirect URI.
If a future CLI exposes a supported callback-host override, the route can be
added without changing the persisted-token model.
