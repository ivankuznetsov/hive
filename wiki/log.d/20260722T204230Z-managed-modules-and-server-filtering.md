---
title: Refresh queued managed-module, Rails filtering, and focused-test contracts
date: 2026-07-22T20:42:30Z
tags: [wiki, modules, web, patrol, bot, testing, security]
---

Inspected all seven queued commits and every changed-path blob with direct
`git show`. None of the supplied SHAs is an ancestor of the refresh branch.
Patch comparison establishes that Rails resource commit `2fef1f47` is
equivalent to already documented `96b06792`, durable bot test commit
`72b95280` is equivalent to `c0c6c147`, and golden-path test commit
`eb8f6181` is equivalent to `d28377b2`. Brakeman commit `e1c41ea0` changes only
the existing registered-task ignore fingerprint/note, while `33888cc8` adds
test-only coverage to the branch-only patrol line.

Queued managed-module head `071d0d71` adds shared redacted
list/inspect/status, no-repair doctor, and production-evaluator dry-run commands
on top of its branch's preview-bound package lifecycle and durable dispatch
work. New [[commands/module]] records the command and schema surface, secret
redaction, read-only inspection rules, retained activation/uninstall evidence,
module state roots, and explicit current-default integration boundary.
[[architecture]], [[state-model]], [[commands]], [[cli]], [[testing]], and
[[gaps]] now connect that queued control plane to the surrounding Hive model.

Later Rails head `affc392f` moves dashboard project filtering from client-side
DOM mutation to an ordinary URL-addressed GET. Rails renders only the selected
project, redirects unknown names to the unfiltered route, owns active navigation
markup, and lets refresh requests preserve the current URL filter. Stimulus is
reduced to composer synchronization for explicit link choices and Back/Forward;
the broadcaster now sends refresh plus composer replacement, not a second
project rail. [[commands/web]], [[architecture]], [[state-model]], [[testing]],
and [[gaps]] record the resulting ownership and remaining deployed multi-client
smoke boundary.

The durable bot and golden-path test equivalents, patrol branch coverage, and
Brakeman metadata-only refresh are recorded without claiming new production
behavior. Page coverage increases from 94 to 95, so [[index]] includes the new
module command page. Compiled [[log]] was not edited, and QMD was intentionally
not run.

**Refreshed pages:**

- [[architecture]]
- [[cli]]
- [[commands]]
- [[commands/module]]
- [[commands/web]]
- [[state-model]]
- [[testing]]
- [[gaps]]
- [[index]]
- [[log]]
