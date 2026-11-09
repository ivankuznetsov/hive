## 2026-11-07 — Digest: OpenCode 2.x errors, visible failures, any-agent routing

- The daily digest stopped refreshing on 2026-11-02 (OpenCode 2.2.5 install
  day): every `hive digest refresh` died with `AgentCliRuntime::MalformedOutput:
  OpenCode error name must be a non-empty string`, while Web `/digests/today`
  silently kept showing 2026-10-31.
- OpenCode 2.x emits `error: {type, message, status}` instead of 1.x
  `error: {name, data: {message}}`, sometimes with an empty `sessionID`.
  `OpenCode::ResultParser`, its nonzero-exit classifier, and
  `ErrorExtractors::OPENCODE` accept both; success output is unchanged
  (fixtures in `components/agent-cli-runtime/test/fixtures/opencode/v2.2.6/`).
- The underlying cause on hivebox was an expired OpenCode Go API key (401
  `provider.auth`); the local host now routes the digest to Codex
  `gpt-6-astra` / `medium`.
- `DocumentGenerator` reports the provider error event on a failed run and
  tries `daily_digest.fallback_agents` in order (validated in `Config`).
- `DocumentWriter` records failures in `generation-failures.json`; the reader,
  `hive digest` (text + `hive-digest.v1` `generation_failure`), and Web surface
  them instead of serving the previous day as current.
- Pages: [[modules/agent_cli_runtime]], [[commands/digest]].
