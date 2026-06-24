## [2026-06-22T12:05:21Z] commands/screenote — OAuth 2.1 + MCP artifact uploads

Replaced Screenote API-key REST uploads with OAuth 2.1 and MCP-backed artifact
uploads. `hive connect screenote` now handles auth-code + PKCE setup, dynamic
client registration, MCP project selection, and mode-0600 credential storage in
`screenote.json`; `hive disconnect screenote` revokes and clears the stored
token. `screenote.api_token` and `HIVE_SCREENOTE_API_TOKEN` are obsolete and
user configs that still set the YAML key get a migration error.

The `7-artifacts` stage no longer mutates `media/manifest.json` after the agent
exits. Claude-backed runs with a valid Screenote credential receive a strict
ephemeral MCP config and allowed Screenote MCP tools; disconnected/expired
credentials remain fail-soft and ask the agent to write local media plus
`screenote_skipped_reason`.

Updated [[commands/screenote]], [[stages/artifacts]], [[modules/config]],
[[dependencies]], [[testing]], and [[gaps]]. The live Screenote capture test is
still gated on the Screenote non-interactive test-token endpoint becoming
available.
