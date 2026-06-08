## [2026-06-08T16:51:31+01:00] hivebox — post-commit command/API coverage audit

**Action:** Refreshed Hivebox command/API, packaging, and executable-entrypoint
wiki coverage after current `HEAD` (`bc45da35`) restored supervisor process
state and recent parent commits changed the Docker image, gem payload, web
assets, OpenClaw `/hive web` surface, and manual Playwright contract. Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]],
[[gaps]], and recent [[log]] entries first; `qmd search "hivebox web docker
supervisor process state packaged web templates public assets"` and `qmd search
"hivebox web"` returned no indexed hits, while the configured master wiki had
only generic Docker references. Inspected the committed diff plus current
`lib/hive/web/supervisor.rb`, `lib/hive/commands/web.rb`, `lib/hive/web/app.rb`,
`hive.gemspec`, `packaging/docker/Dockerfile`,
`packaging/docker/entrypoint.sh`, `test/unit/web/supervisor_test.rb`, and
`test/e2e/hivebox_happy_path.spec.js`.

Corrected wiki coverage to match source: Docker agent CLI npm install is now
fail-closed, not best-effort; `hive.gemspec` packages Hivebox ERB views and
public CSS/JS; Puma is constrained to `~> 7.2`, `>= 7.2.1`; and the Hivebox
Playwright contract fails loudly when `HIVEBOX_URL` is absent. Page count stayed
76, so [[index]] did not need a catalog update. Did not run `qmd update` or
`qmd embed`, and did not edit compiled [[log]].

**Refreshed pages:**
- [[commands/web]]
- [[commands]]
- [[dependencies]]
- [[testing]]
- [[gaps]]
