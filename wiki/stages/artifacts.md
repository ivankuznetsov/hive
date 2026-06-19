---
title: 7-artifacts stage
type: stage
source: lib/hive/stages/artifacts.rb
created: 2026-05-22
updated: 2026-06-18
tags: [stage, artifacts, release]
---

**TLDR**: Artifact collection is the agent-backed handoff between autonomous review and PR finalization. It asks the configured `artifacts.agent` to write `artifact.md`, ending with `<!-- COMPLETE -->`, and now asks the agent to produce best-effort visual proof under `media/` when the task has an observable UI/TUI/CLI surface. Still PNG/JPEG captures are pushed to screenote after the agent finishes, using Ruby-side credentials that are never shown to the agent. Capture skips/failures are recorded in `media/manifest.json` and do not fail the stage. When `artifacts.agent` resolves to Claude, the launch path honors project-global `claude.mode`.

## Preconditions

1. The task must arrive from `6-review` with `REVIEW_COMPLETE` when using `hive artifacts` as a workflow verb.
2. `artifact.md` may be missing on first run; the runner touches it so marker writes have a target.

## Steps performed (`Stages::Artifacts.run!`)

1. Touch `artifact.md` if it does not exist.
2. If the current marker is already `COMPLETE`, return without a new commit action.
3. Render `templates/artifacts_prompt.md.erb` with the task folder, worktree path, and target artifact file.
4. Resolve `artifacts.agent` through `Hive::Stages::Base.stage_profile`.
5. If the profile is Claude, call `Hive::Stages::Base.spawn_claude!` with session name `hive-7-artifacts-<slug>`; otherwise call the normal `spawn_agent` path.
6. Re-read the terminal marker from `artifact.md`.
7. On `COMPLETE`, read `media/manifest.json`. If it is `status: "captured"`, upload PNG/JPEG items whose `push_to_screenote` is true and whose `screenote_url` is blank through `Hive::ScreenoteUploader`; write any returned `annotate_url` values back into the manifest.
8. Return `{commit: "artifacts_collected", status: :complete}` on `COMPLETE`, or the marker-specific action otherwise.

Screenote processing is deliberately fail-soft and never turns a completed artifacts stage red. Only invalid manifest JSON, a misconfigured screenote endpoint (`Hive::ConfigError`), individual upload failures, and the outer `StandardError` rescue actually warn. The per-item skips — missing credentials (the whole batch short-circuits), skipped/failed manifests, missing files, non-still GIF entries, and traversal-/symlink-shaped item filenames — are silently skipped.

## Media manifest

The agent writes `<task>/media/manifest.json`:

```json
{
  "schema": 1,
  "status": "captured | skipped | failed",
  "reason": "required when skipped or failed",
  "surface": "ui | tui | none",
  "items": [
    {
      "file": "01-home.png",
      "type": "still",
      "caption": "Home page after load",
      "push_to_screenote": true,
      "screenote_url": null
    }
  ]
}
```

`status: "skipped"` means the task has no observable surface. `status: "failed"` means boot, driving, or capture tooling failed; hivebox renders the reason as a Demo warning banner. `status: "captured"` renders committed PNG/JPEG/GIF files inline in hivebox through the task media route. See [[commands/web]].

## Marker -> next action

- Markerless or non-complete `7-artifacts` rows surface as `ready_to_artifacts` with `hive artifacts <slug> --from 7-artifacts`.
- `:complete` rows surface as `ready_to_finalize` with `hive finalize <slug> --from 7-artifacts`.
- `ERROR reason=tmux_session_terminated` and `ERROR reason=agent_orphaned` are daemon-retryable when no live task lock exists. `ERROR reason=timeout` is also retryable for this stage, but only once: if a tmux-backed artifacts agent wrote or can safely rewrite `artifact.md` yet failed to stamp `<!-- COMPLETE -->` before the wait timed out, `Hive::Daemon::StaleAgentHealer` clears the marker with the shared marker-id guard and the timeout-specific one-shot budget, then the normal daemon dispatch reruns artifact collection. Other timeout stages stay manual unless separately documented.

## Backlinks

- [[stages/review]] · [[stages/finalize]]
- [[state-model]] · [[commands/stage_action]] · [[modules/workflows]]
