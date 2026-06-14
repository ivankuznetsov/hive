---
date: 2026-06-14
slug: colima-smoke-gap-refresh
pages: [commands/web, testing, dependencies, gaps]
---

Post-commit wiki coverage refresh after commit `abb62aae` added a
`wiki/gaps.md` note for the release workflow's macOS Colima hivebox smoke
failure. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]],
[[gaps]], recent compiled [[log]] entries, and recent `wiki/log.d/` fragments
first. `qmd search "planning documentation coverage docs plans notes context
wiki refresh"` surfaced existing Hive post-commit refresh patterns, and the
configured master wiki path had no relevant Hivebox/Colima guidance.

Inspected the committed diff plus current `.github/workflows/release.yml`,
`.github/workflows/ci.yml`, `packaging/docker/smoke.sh`,
`packaging/docker/README.md`, `docs/RELEASING.md`, [[commands/web]],
[[testing]], [[dependencies]], and [[gaps]]. Consolidated the new Colima note
into the existing Hivebox golden-path install gap: current CI covers Rails web
tests, the golden-path browser E2E, and the Windows installer harness, but it
does not contain the older push/PR Docker image-smoke job. The release job still
pre-push-smokes amd64 before publishing, while the post-publish macOS arm64
Colima leg is currently an intended verification path, not proven coverage,
because `colima start --cpu 2 --memory 4` can fail when the hosted runner's Lima
VZ VM exits. The prior note says the image itself was separately checked by
multi-arch manifest and local `/health?deep=1` smoke, but no checked-in artifact
proves a hosted Colima retry/fallback or passing v0.3.0 release run.

Also corrected a stale [[dependencies]] standard-library note: current
`Hive::Lock.process_start_time` uses `/proc/<pid>/stat` when available and
falls back to `ps -o lstart= -p <pid>`, with unit coverage in
`test/unit/lock_test.rb`. Page coverage did not change, so [[index]] was not
edited. Did not edit compiled [[log]], and did not run `qmd update` or
`qmd embed`.
