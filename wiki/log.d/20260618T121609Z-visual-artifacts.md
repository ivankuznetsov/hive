---
date: 2026-06-18
slug: visual-artifacts
pages: [stages/artifacts, commands/web, modules/config, dependencies, testing]
---

Added visual artifact capture/display coverage for the artifacts-to-finalize
handoff. `templates/artifacts_prompt.md.erb` now asks the artifacts agent to
write `media/manifest.json` plus committed PNG/GIF evidence when a task has an
observable UI/TUI/CLI surface, or a skipped/failed manifest when it does not.
`Hive::ScreenoteUploader` uses stdlib `Net::HTTP` and global/env screenote
config to upload PNG/JPEG stills after the agent completes, keeping the token
out of prompts. hivebox now streams committed task media through a constrained
task media route and renders captured media or failed-capture warnings on the
task page. Finalize prompts instruct the agent to include screenote Demo links
in PR bodies when enriched URLs exist.

Updated [[stages/artifacts]], [[commands/web]], [[modules/config]],
[[dependencies]], and [[testing]] with the manifest contract, media route
safety boundary, screenote config/env overrides, optional capture tools, Docker
terminal-capture additions, and new test coverage. Added
`docs/visual-artifacts.md`; did not edit compiled [[log]].
