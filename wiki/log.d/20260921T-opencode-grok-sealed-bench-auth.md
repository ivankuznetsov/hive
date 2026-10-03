# 2026-09-21 — Sealed benchmark auth for OpenCode Go and Grok

- Sealed benchmark cells now permit the native `grok` agent when the candidate
  explicitly routes to it.
- OpenCode cells mount the host's `~/.local/share/opencode/auth.json` read-only
  inside disposable XDG parent directories, allowing OpenCode Go subscription
  authentication without requiring `OPENCODE_API_KEY`.
