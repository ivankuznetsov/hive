## 2026-07-21 — Managed agent draft-PR handoff

- Added a strict controller-owned `handoff.yml` phase machine for terminal
  worktree agents, with exact base/head/report/scan identity and durable
  push/create intent evidence.
- Added pre-publication scanning of every new commit and reachable blob,
  including intermediate add-then-remove content, plus final changed files and
  bounded PR text. Binary, LFS, oversized, credential, and unsafe identity
  states fail closed before publication; controller receipts and resume reports
  use bounded no-follow reads, and current `github_pat_` tokens are detected
  and redacted.
- Draft-PR publication now uses an ordinary immutable-OID refspec and an
  explicit `gh pr create --draft --head --base --title --body-file` call.
  Resume reconciles exact remote branch/PR identity and never force-pushes or
  repeats an ambiguous mutation.
- Generic status exposes the verified `pr_url`. Recoverable remote failures
  preserve the worktree and surface an operator-only `hive run` action that
  the daemon does not dispatch automatically.
