## [2026-06-08T12:45:42+01:00] hivebox — refresh Docker web command/API coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after
commit `a4103844` added `.dockerignore` and `packaging/docker/` for hivebox.
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search
"hivebox docker packaging supervisor web entrypoint"` returned no indexed hits,
and the configured master wiki had only generic Docker references. Inspected the
committed diff plus current `packaging/docker/Dockerfile`,
`packaging/docker/entrypoint.sh`, `packaging/docker/README.md`,
`packaging/docker/compose.example.yml`, `.dockerignore`,
`lib/hive/commands/web.rb`, `lib/hive/web/**`, web config validation, web unit
tests, and the manual Playwright hivebox contract. Updated the wiki to cover the
Docker image build path, `/data` persistence boundary, `tini` entrypoint,
custom-argv behavior, `/health` healthcheck, compose environment, best-effort
agent CLI npm install, web runtime gems, and the remaining lack of live
provider/container smoke evidence. Page count stayed 76, so [[index]] did not
need a catalog update. Did not run `qmd update` or `qmd embed`, and did not edit
compiled [[log]].

**Refreshed pages:**
- [[commands/web]]
- [[architecture]]
- [[commands]]
- [[dependencies]]
- [[testing]]
- [[gaps]]
