## [2026-06-08T12:02:43Z] config/patrol — add patrol.mode and patrol token attribution

**Action:** Added the `patrol.mode` frequency dial (`ultrapatrol`, `high`, `medium`, `low`, `off`) and documented that `Config.load` resolves it on raw YAML before defaults merge so explicit granular scheduler keys still win. Fresh `hive init` now prompts for the mode, writes only `patrol.mode` for scheduling, and includes `patrol_mode` in the init JSON contract. Patrol reviewer/fixer agent wrappers now record usage rows tagged `patrol-review` / `patrol-fix`, and token usage aggregation exposes a scoped `patrol` attribution bucket rendered in the TUI token matrix.

**Refreshed pages:**
- [[modules/config]]
- [[commands/init]]
- [[modules/patrol]]
- [[token-usage]]
