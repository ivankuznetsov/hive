## [2026-07-02T01:21:41Z] digest — audit residual wiki refresh coverage

**Action:** Refreshed main-checkout wiki coverage for branch
`add-a-digest-cli-mode-260702-2eed` after its 6-review residual commit touched
wiki pages and log fragments. Read `AGENTS.md`, `.llm-wiki/config.json`,
[[index]], [[decisions]], [[gaps]], and recent [[log]] entries first. Searched
the project wiki for `digest cli mode merged PR Telegram delivery`; `qmd search`
had no exact indexed hit, so verification used `rg` and the configured
main-wiki path check. The configured main-wiki path was absent in this
checkout, so no external wiki results were available.

Inspected the residual diff with `git show`, read committed snapshots with
git's `<revision>:<path>` form, and compared them with the current main wiki
and source for `Hive::Commands::Digest`, `Hive::Digest`,
`Hive::Digest::MergedPr`, schemas, and focused digest tests. Confirmed current
[[commands/digest]], [[modules/digest]], [[testing]], and [[gaps]] already
cover the public digest CLI mode, `--source merged-prs`, repeatable
`--repo owner/name`, the `hive-merged-pr-digest.v1` envelope, pending Telegram
pairing reminders, `.env` loading for real sends, and the remaining live
provider uncertainty. Updated [[gaps]] only to record that this residual audit
found no new live GitHub/Telegram evidence. Page coverage did not change, so
[[index]] did not need a page-list update.

Did not edit compiled `wiki/log.md` and did not run `qmd update` or
`qmd embed`.

**Refreshed pages:**
- [[gaps]]
- [[log]]
