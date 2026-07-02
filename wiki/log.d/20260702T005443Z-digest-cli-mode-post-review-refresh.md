## [2026-07-02T00:54:43Z] digest — post-review wiki correction pass

**Action:** Refreshed main-checkout wiki coverage for branch
`add-a-digest-cli-mode-260702-2eed` after inspecting the post-review wiki-only
commit and current digest/pairing source. Read `AGENTS.md`, [[index]],
[[decisions]], [[gaps]], recent [[log]] entries, and `.llm-wiki/config.json`;
searched the project wiki plus configured main wiki for digest CLI coverage;
and verified `Hive::Commands::Digest`, `Hive::Digest`,
`Hive::Digest::MergedPr`, `Hive::Commands::Pairing`, `PairingStore`,
`PairingApprovalQueue`, schemas, and focused tests.

Corrected the digest command/module pages to match source-backed details that
were easy to misread in the review-fix diff: the pending-pairing reminder text
uses the key-icon line with a backticked `hive pairing list` command, merged-PR
dry-run rendering is grouped by repository with total counts, and JSON
config/usage error envelopes use the merged-PR schema when that source is
selected. Existing [[gaps]] uncertainty remains current: this pass found no
new in-tree artifact proving live GitHub merged-PR collection plus Telegram
delivery, or a real delivered shipped digest.

Did not edit compiled `wiki/log.md` and did not run `qmd update` or
`qmd embed`.

**Refreshed pages:**
- [[commands/digest]]
- [[modules/digest]]
- [[gaps]]
