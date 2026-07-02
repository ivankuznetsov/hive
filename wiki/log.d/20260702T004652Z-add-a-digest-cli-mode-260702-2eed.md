## [2026-07-02T00:46:52Z] digest — merged-PR source and pairing approval coverage

**Action:** Refreshed wiki planning/documentation coverage for branch
`add-a-digest-cli-mode-260702-2eed` after a wiki-residue commit documented
digest and Telegram pairing surfaces. Read `AGENTS.md`, [[index]],
[[decisions]], [[gaps]], recent [[log]] entries, `.llm-wiki/config.json`, and
searched the project wiki plus configured main wiki for `digest cli mode`.
Inspected the committed diff with `git show`, read committed snapshots with
git's `<revision>:<path>` form, and verified current source for
`Hive::Commands::Digest`, `Hive::Digest`, `Hive::Digest::MergedPr`,
`Hive::Commands::Pairing`, `PairingStore`, `PairingApprovalQueue`, schemas, and
focused tests.

Documented `hive digest --source merged-prs` / repeatable `--repo owner/name`
as an agent-free, read-only GitHub merged-PR report with its own
`hive-merged-pr-digest.v1` envelope; recorded that the default shipped-task
digest appends pending Telegram pairing reminders from the local pairing
store. Added [[commands/pairing]] for owner-side Telegram pairing approval,
updated command/module/testing coverage, bumped [[index]] for the new page,
and carried forward live-provider uncertainty in [[gaps]]: no in-tree artifact
proves a real merged-PR digest against GitHub plus Telegram delivery, nor a
real delivered shipped digest from the opt-in live test.

Did not edit compiled `wiki/log.md` and did not run `qmd update` or
`qmd embed`.

**Refreshed pages:**
- [[commands]]
- [[commands/digest]]
- [[commands/pairing]]
- [[modules/digest]]
- [[testing]]
- [[gaps]]
- [[index]]
