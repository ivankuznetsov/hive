---
title: 7-artifacts stage
type: stage
source: lib/hive/stages/artifacts.rb
created: 2026-05-22
updated: 2026-07-25
tags: [stage, artifacts, release]
---

**TLDR**: Artifact collection is the agent-backed handoff between autonomous
review and PR finalization. Before spawn, Hive writes a deterministic,
generation-bound `capture-requirement.json`. Visual work must retain a valid
task-local `media/capture-manifest.json`; a bootstrap or recorder failure keeps
the stage in `ERROR reason=required_capture_missing`. Nonvisual work records
`not_applicable`. Autonomous artifact collection never reads or injects
Screenote credentials: external upload is a separate operator-confirmed action.

## Preconditions

1. The task must arrive from `6-review` with `REVIEW_COMPLETE` when using `hive artifacts` as a workflow verb.
2. `artifact.md` may be missing on first run; the runner touches it so marker writes have a target.

## Steps performed (`Stages::Artifacts.run!`)

1. Touch `artifact.md` if it does not exist.
2. Classify applicability from the exact implementation base/head, changed-path
   digest, visual path rules, and explicit requested outcome, then atomically
   write `capture-requirement.json`. If Hive cannot prove the owned worktree,
   base/head, or changed-path evidence, classification fails closed to
   `required`; absence of evidence is never treated as `not_applicable`.
3. If the marker is already `COMPLETE`, accept it only when the requirement is
   `not_applicable` or a matching retained capture manifest exists.
4. Resolve `artifacts.agent`, render the generation-bound local-capture
   contract, and spawn without external-upload credentials or MCP tools.
5. Re-read the marker and validate required capture again. Missing/invalid
   required evidence is replaced with
   `ERROR reason=required_capture_missing` and remediation.

## Media manifest

Required capture writes `<task>/media/capture-manifest.json` using
`hive-artifact-capture` v1. It binds the task slug and clean source SHA, both
lockfile digests, immutable dependency-cache key, exact recorder command,
fixture ids, viewport, accessibility assertions, artifact byte sizes and
SHA-256 hashes, and teardown outcome. A `captured` receipt must contain at least
one retained artifact and match the requirement's implementation head.

The older `<task>/media/manifest.json` remains a display compatibility format
for existing tasks:

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

For new work, applicability is not agent-authored: `not_applicable` is the
classifier result, while required capture failure is a stage error. Promotion
is unrestricted; demotion requires a confirmed generation-bound operator and
rationale. See [[commands/web]].

## Marker -> next action

- Markerless or non-complete `7-artifacts` rows surface as `ready_to_artifacts` with `hive artifacts <slug> --from 7-artifacts`.
- `:complete` rows surface as `ready_to_finalize` with `hive finalize <slug> --from 7-artifacts`.
- Every persisted `ERROR`, including `tmux_session_terminated`,
  `agent_orphaned`, and `timeout`, follows the universal recovery lifecycle.
  After the shared cooldown and safety checks, `RecoveryCoordinator` admits the
  exact marker generation and reruns artifact collection. There is no
  artifacts-only timeout budget or healer clear path.

## Backlinks

- [[stages/review]] · [[stages/finalize]]
- [[state-model]] · [[commands/stage_action]] · [[modules/workflows]]
- [[commands/screenote]]
