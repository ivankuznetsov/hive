---
date: 2026-06-12
slug: dispatch-request-writer-fixture-audit
pages: [log]
---

Post-commit wiki coverage audit after commit `99fe942d` changed
`test/unit/bot/dispatch_request_writer_test.rb` so the dispatch-request writer
fixture asserts `Hive::Daemon::DispatchRequestQueue::SCHEMA_VERSION` instead of
a stale hard-coded version number. Read `AGENTS.md`, `.llm-wiki/config.json`,
[[index]], [[decisions]], [[gaps]], and recent compiled [[log]] entries first.
Read-only `qmd search "dispatch-request schema version fixture writer wiki
documentation coverage"` surfaced prior dispatch-request schema context in
[[decisions]] and [[log]]; a targeted search of the configured master wiki path
did not find project-relevant prior guidance.

Inspected the committed diff and current source for
`test/unit/bot/dispatch_request_writer_test.rb`,
`lib/hive/bot/dispatch_request_writer.rb`,
`lib/hive/daemon/dispatch_request_queue.rb`, `lib/hive.rb`,
`schemas/hive-dispatch-request.v1.json`,
`schemas/hive-dispatch-request.v2.json`, and the dispatch-request schema
coverage in `test/unit/schema_files_test.rb`. Also inspected the already-dirty
wiki refresh for commit `c0630426` and left it intact.

No additional wiki page or gap edits were needed for `99fe942d`: the current
dirty wiki pages already document `hive-dispatch-request.v2`,
`DispatchRequestQueue::SCHEMA_VERSION`, strict `unknown_schema_version`
rejection, the `bot|healer` requestor enum, and current schema-file coverage.
Page coverage did not change, so [[index]] was not edited. No new uncertainty
was added to [[gaps]] because this commit only keeps an existing unit fixture
aligned with the queue schema constant and does not change runtime behavior or
verification scope. Did not edit compiled [[log]], and did not run `qmd update`
or `qmd embed`.
