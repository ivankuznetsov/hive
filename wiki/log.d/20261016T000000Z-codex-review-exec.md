# 2026-10-16 — Native Codex reviewer runs `codex exec review`

- `AgentSupport::Codex::Reviewer` now runs `codex exec review` inside
  `Hive::Mcp.with_launch(scope: "review")` instead of top-level `codex review`,
  which has no `--ignore-user-config`. It gets the same isolated launch as other
  Codex launches (one `--ignore-user-config`, granted `-c mcp_servers.*`,
  carried personal settings), plus an explicit `-c sandbox_mode="read-only"`;
  the "MCP isolation incomplete" warning is gone and launch notices go to
  `isolation-warnings.log`.
- `Hive::Reviewers::Runtime.capture` spawns with stdin `/dev/null`.
- A real codex-cli 0.162.1 comparison showed both forms print the same
  stream (transcript on stderr, final message on stdout), so parsing is
  unchanged. The final message appears twice in the merged capture, and
  the reviewer now publishes it once.
  `exec review --json` reports zero usage, so usage is still not recorded.
- Fixtures: `test/fixtures/codex_exec_review/`. See [[modules/reviewers]],
  [[modules/mcp]], [[gaps]].
