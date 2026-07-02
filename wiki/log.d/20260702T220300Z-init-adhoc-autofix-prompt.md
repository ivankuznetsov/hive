---
title: Init ad-hoc PR auto-fix prompt
type: log
created: 2026-07-02
tags: [init, review, adhoc, config, wiki]
---

**Action:** Updated `hive init` so the setup questionnaire explicitly asks whether ad-hoc PR reviews created by `hive review --pr` should enter the auto-fix loop. The default remains review-only: `review.github_publish.enabled` is rendered true so reviewer/escalation comments can be posted to GitHub, while `review.adhoc.fix` renders from the init answer and defaults to false.

**Evidence:** `lib/hive/commands/init/prompts.rb` now derives `DEFAULT_ADHOC_AUTO_FIX` from `Hive::Config::DEFAULTS`, records `adhoc_auto_fix` in interactive and non-TTY answers, and includes it in summaries. `templates/project_config.yml.erb` renders `review.adhoc.fix` from that answer. `schemas/hive-init.v1.json` includes the field in both nested `answers` and the top-level success payload. Focused prompt, config-rendering, schema, and integration tests cover the new prompt ordering and JSON contract.
