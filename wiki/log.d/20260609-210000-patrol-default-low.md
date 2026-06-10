## [2026-06-09T21:00:00Z] patrol/config — default patrol mode is now `low`

**Action:** Changed `Hive::Config::DEFAULT_PATROL_MODE` from `"medium"` to `"low"`.

This is the mode the `hive init` *prompt* suggests (and writes into `templates/project_config.yml.erb`) when a project opts into patrol and accepts the default. `low` uses the `new_commits` trigger — patrol runs only when there are new commits, rather than `medium`'s every-4h timer — which keeps token spend modest by default; users can still pick `medium`/`high`/`ultrapatrol` explicitly. The opt-in gate is unchanged: a project with no `patrol.mode` stays disabled (`DEFAULT_PATROL_MODE` is only the prompt default, never a config-resolution default). `DEFAULTS["patrol"]["mode"]` stays `"medium"` as the inert placeholder (never applied because patrol is `enabled: false` until an explicit `mode:` is written).

**Refreshed pages:**
- [[modules/config]] — opt-in prose now states `low` is the prompt default and why.
