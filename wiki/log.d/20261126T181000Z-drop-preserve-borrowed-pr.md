# 2026-11-26 — Preserve borrowed PRs on `hive drop`

**Action:** Extracted and hardened the borrowed-PR safety guard from PR `#1417`
in `lib/hive/commands/drop.rb` so `Hive::Commands::Drop#close_draft_prs` never
closes pull requests that Hive did not create. Tasks marked `source: ad-hoc`
(case-insensitive) in `pr.md`, `task.md`, or `idea.md`, tasks whose `meta.yml`
records `workflow: pr-review`, and tasks whose ownership frontmatter cannot be
read (fail closed with a stderr warning) skip `gh pr close` while still cleaning
up local task state and reporting `pr_closed: true`. Hive-owned PRs continue to
be closed best-effort as before. Added unit tests in
`test/unit/commands/drop_test.rb` and updated [[commands/drop]].
