## [2026-06-14T11:08:49Z] wiki — audit status-race refresh commit references

**Action:** Audited the status-race wiki refresh after HEAD became `f1a094a8` (`docs(status): refresh race follow-up wiki`). Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "status stage move race duplicate vanished folder state file TOCTOU"` returned no indexed hits, while direct wiki search found the existing status/TUI/testing/gaps coverage, and the configured master wiki path had no relevant project-specific hit. Inspected `git log --oneline`, the committed diff for `f1a094a8`, the source/test commits through `f6f03c59`, current `lib/hive/commands/status.rb`, `test/unit/commands/status_test.rb`, [[commands/status]], [[commands/tui]], [[testing]], and [[gaps]]. Corrected the status-race gap and previous log fragment to cite the branch's actual ancestor commits (`586b9d31`, `a274bf42`, `52585bc7`, `0976c9ee`, `02ebf151`, `85e76754`, `c6543d8f`, `b018341b`, and `f6f03c59`) instead of non-ancestor ids. Command/API page coverage already matched the source, page coverage did not change, and the missing live daemon/TUI polling artifact remains recorded. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[gaps]]
- [[log]]
