## [2026-06-11T21:04:41Z] wiki — refresh patrol native-reviewer documentation

**Action:** Refreshed wiki planning/documentation coverage after inspecting recent source commits `b2e568ba` (native `codex review` reviewer for patrol PRs), `852cc10c` (patrol mode default back to `medium`), and the latest v0.2.3 wiki follow-up commit `0212469b`. Read `.llm-wiki/config.json`, `AGENTS.md`, `CLAUDE.md`, [[index]], [[gaps]], recent [[log]], and the latest `wiki/log.d/` fragments first. Searched the configured master wiki path `/home/asterio/wikis/master/wiki` and checked the default cross-project wiki paths; only the configured master path exists, and it had no Hive-specific patrol reviewer guidance. `qmd search "patrol review reviewers codex native review init config"` surfaced the existing native-reviewer fragment plus stale [[modules/config]] wording.

Verified current source in `lib/hive/config.rb`, `lib/hive/commands/init/prompts.rb`, `lib/hive/reviewers/codex_review.rb`, `templates/project_config.yml.erb`, and focused test coverage. Updated [[architecture]], [[commands/init]], [[commands/patrol]], [[commands/doctor]], [[modules/config]], [[stages/index]], [[stages/review]], and [[gaps]] so they consistently describe `codex-native-review` (`kind: codex_review`) as the patrol PR reviewer default, Codex/Claude CE reviewers as opt-ins, `patrol_reviewers=codex-native-review` in the non-TTY init summary, Doctor's current non-agent reviewer behavior, and the current config default caps. Page coverage did not change, so [[index]] needed no structural update. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[architecture]]
- [[commands/init]]
- [[commands/patrol]]
- [[commands/doctor]]
- [[modules/config]]
- [[stages/index]]
- [[stages/review]]
- [[gaps]]
