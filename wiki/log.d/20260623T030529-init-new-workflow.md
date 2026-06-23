## [2026-06-23T03:05:29+01:00] init — scaffold and bind custom workflows

**Action:** Added `hive init --new-workflow ID [PROJECT_PATH]` to document the single-command custom workflow bootstrap: init scaffolds the same project-authored descriptor and `work.md` instruction as [[commands/workflow]], binds `default_workflow: ID`, prints the edit paths, and leaves flag-less `hive new` routing through the custom descriptor. Documented mutual exclusivity with `--workflow`, reserved built-in id rejection, already-initialized scaffold+rebind behavior, and the optional `descriptor_path` / `instruction_path` fields on `hive-init.v1`.

**Refreshed pages:**
- [[commands/init]]
- [[commands/workflow]]
