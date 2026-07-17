---
title: 7-artifacts stage
type: stage
source: lib/hive/stages/artifacts.rb
created: 2026-05-22
updated: 2026-07-17
tags: [stage, artifacts, release]
---

**TLDR**: Artifact collection is the agent-backed handoff between autonomous review and PR finalization. It asks the configured `artifacts.agent` to write `artifact.md`, ending with `<!-- COMPLETE -->`, and asks the agent to produce best-effort visual proof under `media/` when the task has an observable UI/TUI/CLI surface. Screenote is now agent-driven: when a valid OAuth credential exists, Claude-backed artifacts runs receive a strict Screenote MCP config and the prompt tells the agent to upload PNG/JPEG stills through `create_screenshot_upload`; when Screenote is missing/expired/unusable, the agent still captures local media and records `screenote_skipped_reason`. The Ruby REST uploader is gone.

## Preconditions

1. The task must arrive from `6-review` with `REVIEW_COMPLETE` when using `hive artifacts` as a workflow verb.
2. `artifact.md` may be missing on first run; the runner touches it so marker writes have a target.

## Steps performed (`Stages::Artifacts.run!`)

1. Touch `artifact.md` if it does not exist.
2. If the current marker is already `COMPLETE`, return without a new commit action.
3. Resolve the Screenote connection state from `~/.config/hive/screenote.json` (or `HIVE_HOME/screenote.json`) plus any per-task `screenote.project_id` override, then render `templates/artifacts_prompt.md.erb` with the task folder, worktree path, target artifact file, and connected/disconnected Screenote context.
4. Resolve `artifacts.agent` through `Hive::Stages::Base.stage_profile`.
5. If the profile is Claude and Screenote is connected, write a mode-0600 ephemeral `.mcp.json` under `Hive::Paths.cache_home`, pass it to Claude with `--mcp-config` and `--strict-mcp-config`, and add the Screenote MCP tools to `--allowedTools`. If disconnected or the profile is not Claude, spawn without Screenote MCP injection.
6. Re-read the terminal marker from `artifact.md`.
7. Return `{commit: "artifacts_collected", status: :complete}` on `COMPLETE`, or the marker-specific action otherwise. The stage no longer mutates `media/manifest.json` after the agent exits.

Screenote processing remains fail-soft, but the fail-soft behavior now lives in the prompt and MCP injection boundary rather than in a Ruby post-processing loop. A missing credential, expired token, missing project, or invalid credential produces a disconnected prompt context; the agent still captures local media and records the reason in `screenote_skipped_reason`. A revoked token can still fail individual MCP calls inside the agent run; the prompt instructs the agent to leave `screenote_url` null and write a concise skip reason instead of failing the stage.

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
      "screenote_url": "https://screenote.ai/...",
      "screenote_skipped_reason": null
    }
  ]
}
```

`status: "skipped"` means the task has no observable surface. `status: "failed"` means boot, driving, or capture tooling failed; hivebox renders the reason as a Demo warning banner. `status: "captured"` renders committed PNG/JPEG/GIF files inline in hivebox through the task media route. `screenote_url` remains the display contract read by hivebox; `screenote_skipped_reason` is an optional writer-side diagnostic. See [[commands/web]] and [[commands/screenote]].

## Marker -> next action

- Markerless or non-complete `7-artifacts` rows surface as `ready_to_artifacts` with `hive artifacts <slug> --from 7-artifacts`.
- `:complete` rows surface as `ready_to_finalize` with `hive finalize <slug> --from 7-artifacts`.
- `ERROR reason=tmux_session_terminated`, `agent_orphaned`, or `timeout` is terminal evidence submitted through `FailureReporter`, just like every other family. The coordinator increments the one task-stage-generation ladder, persists an absolute deadline, and later authorizes a fenced successor through normal capacity. `StaleAgentHealer` only observes liveness and never clears the marker or owns a one-shot budget.

## Backlinks

- [[stages/review]] · [[stages/finalize]]
- [[state-model]] · [[commands/stage_action]] · [[modules/workflows]]
- [[commands/screenote]]
