---
title: 7-artifacts stage
type: stage
source: lib/hive/stages/artifacts.rb
created: 2026-05-22
updated: 2026-05-22
tags: [stage, artifacts, release]
---

**TLDR**: Artifact collection is the no-agent handoff between autonomous review and PR finalization. It creates `artifact.md`, stamps `<!-- COMPLETE -->`, and gives future release-packaging work a stable stage slot without letting finalize skip the terminal-marker gate.

## Preconditions

1. The task must arrive from `6-review` with `REVIEW_COMPLETE` when using `hive artifacts` as a workflow verb.
2. `artifact.md` may be missing on first run; the runner creates it.

## Steps performed (`Stages::Artifacts.run!`)

1. Touch `artifact.md` if it does not exist.
2. If the current marker is already `COMPLETE`, return without a new commit action.
3. Otherwise append `<!-- COMPLETE -->` to `artifact.md` and return `{commit: "artifacts_collected", status: :complete}`.

## Marker -> next action

- Markerless or non-complete `7-artifacts` rows surface as `ready_to_artifacts` with `hive artifacts <slug> --from 7-artifacts`.
- `:complete` rows surface as `ready_to_finalize` with `hive finalize <slug> --from 7-artifacts`.

## Backlinks

- [[stages/review]] · [[stages/finalize]]
- [[state-model]] · [[commands/stage_action]] · [[modules/workflows]]
