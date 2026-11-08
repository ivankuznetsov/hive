# 2026-11-06 — Artifact custody treats the task journal as append-only

**Action:** Fixed the recurring false positive where custody failed a stage
with "protected anchor 'task-journal.jsonl' changed from file to file;
restoration verified" (hivedev C6 artifacts reviewer 02:45 UTC, C14 artifacts
producer 07:29 UTC; review CI-fix REVIEW_ERROR on F3, inbox task
`ci-fix-custody-flags-hive-261103-f417`).

**Findings:** In both artifacts failures the PR was merged while the agent
ran (C6 02:41:23, C14 07:22:53). The daemon's GitHub observer appended
`pull request outcome changed` to the journal inside the custody window; the
firewall compared whole-file SHA-256, flagged it as tampering, and restoration
rolled the journal back. The record reappears with a later `ingested_at`
(02:45:38, 07:29:46) because the observer re-ingested it after restore.

**Change:** `Hive::ProtectedFiles` declares `APPEND_ONLY_LOGS`
(`task-journal.jsonl` ⇒ `.task-journal.lock`). For such anchors
`Hive::ArtifactFirewall` accepts a change only when the captured bytes and mode
survive and the growth is complete, unseen journal records; capture, check,
and restore hold the journal flock. Restoration keeps the captured bytes plus
any complete journal records found after them, so controller history is never
deleted. Truncation/rewrite/foreign content still fails. Applies to every
custody user (artifacts roles, review CI-fix/triage/runner, execute, open PR,
finalize, planner revision, patrol fix).
