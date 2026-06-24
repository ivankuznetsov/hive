## Screenote connect/MCP hardening (review pass 02) — 2026-06-22

Applied the 6-review pass-02 findings on the Screenote OAuth/MCP integration:

- **MCP tool-channel errors surface.** `McpClient#call_tool` now raises a typed
  `Hive::Error` (joined `content` text) on a 2xx whose `result` is
  `{"isError":true,…}`, instead of letting `list_projects` fall through to `[]`
  (and `connect` raise the wrong "create a project" remedy) or a failed upload
  read as success. `extract_projects` guards a non-Hash `result` (no more
  untyped `TypeError`).
- **SSE replies parse.** `call_tool` de-frames a `text/event-stream` body
  (`data:` lines) so a spec-compliant Streamable-HTTP server no longer breaks
  with "unparseable response". JSON-object parsing is shared via
  `Hive::Screenote::Http.parse_json_object` (OAuth keeps the empty-body→`{}`
  guard).
- **`connect` no longer abandons a live token.** Any post-`exchange_code`
  failure (project listing/selection/payload/`save`) best-effort revokes the
  fresh bearer before re-raising; an OS-level `save` failure maps to a typed
  error with the path; the loopback socket closes on an early raise.
- **`--json` is machine-usable.** `connect`/`disconnect` emit a structured
  `{ "ok": false, … }` error envelope on failure; under `--json`, `connect`
  auto-selects a lone project and emits a `needs_project_selection` envelope for
  several (no human prose on the JSON stream, no silent default).
- **Artifacts fail-soft is visible.** `screenote_context` skips now `warn` why
  no upload happened; the MCP-config write rescue covers `Hive::ConfigError`
  too; ephemeral-config cleanup failures warn.
- Doc/comment fixes: `disconnect` `reason` no longer claims an "already-revoked"
  case RFC 7009 can't emit; `config.rb` names the real `load_global_screenote`
  owner.
