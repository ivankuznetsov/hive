---
date: 2026-06-16
slug: codex-device-auth-url-sanitize
pages: [decisions, gaps]
---

Decisions captured for the hivebox web agent-login relay
(`lib/hive/web/agents_auth.rb`, the PTY OAuth relay from ADR-035).

**codex login uses the headless device-flow.** `AGENT_COMMANDS["codex"]`
changed from `codex login` to `codex login --device-auth` (#502). Plain
`codex login` is a localhost-callback OAuth: it starts a server on the
*container's* `localhost:1455` and prints that as the first URL, which the
operator's host browser can never reach across the container boundary, and
which `URL_RE` would surface ahead of the real provider URL. `--device-auth`
is the RFC-8628 device-flow (one authorize URL + a one-time code entered at
the provider) — codex itself recommends it "on a remote or headless machine".

**Surfaced URLs are sanitized before becoming an href.** Agents print the
device link wrapped in terminal control sequences (codex: `\e[94m<url>\e[0m`).
`URL_RE` only stops at whitespace, so the raw match carries those bytes.
`sanitize_url` now replaces each `TERMINAL_CONTROL_RE` run with a **space**
(not a deletion — deleting would splice two back-to-back URLs into one href,
`…/device\e[0mhttps://evil` → `…/devicehttps://evil`) and re-extracts the
first whitespace-terminated URL via `URL_RE`. This drops the trailing color
reset, OSC-8 wrapper residue, and any trailing second URL.

**Known gap (see [[gaps]]):** codex `--device-auth` (and `gh`) are
*operator-ward* device flows — the one-time code is entered at the provider
and the CLI polls in the background; nothing is pasted back. The relay's
login-status view still shows a `required` paste-code form and stops polling
once the URL is captured, so the token saves but the UI does not auto-reflect
completion. A follow-up reworks the view/controller to keep polling until
`session.done` and suppress the paste form for poll-type agents.
