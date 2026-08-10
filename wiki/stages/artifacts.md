---
title: 7-artifacts stage
type: stage
source: lib/hive/stages/artifacts.rb
created: 2026-05-22
updated: 2026-08-03
tags: [stage, artifacts, release]
---

**TLDR**: Artifact collection is the agent-backed handoff between autonomous
review and PR finalization. Before spawn, Hive writes a deterministic,
generation-bound `capture-requirement.json`. Visual work must retain a valid
task-local `media/capture-manifest.json`; a bootstrap, provider, or recorder failure keeps
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
`hive-artifact-capture` v2. Its provider-neutral envelope binds the task slug,
clean source SHA, recorder identity and argv, disclosed environment-key names,
artifact byte sizes and SHA-256 hashes, timestamps, diagnostic, and teardown
outcome. Built-in Hivebox evidence keeps its lock digests, immutable cache key,
fixture ids, viewport, and accessibility assertions inside the typed `evidence`
block; project recorders use `evidence.type: project_provider` and bounded
provider-specific `details`. A `captured` receipt must contain at least one
retained artifact and match the requirement's implementation head.

New producers reserve headroom by rejecting the complete serialized receipt
above 240 KiB before publishing any provider media or manifest. Policy and Hive
Web share a 256 KiB consumer ceiling and reject larger files before parsing.
The environment-key disclosure is always nonempty, and failed-provider blank
diagnostics are normalized to an actionable fallback. Project-provider capture
is Linux-only because its custody guarantee depends on child-subreaper support.
Before and after invoking a provider, Hive rejects Git `assume-unchanged` and
`skip-worktree` index entries and revalidates the complete source snapshot. Git
attestation helpers and the provider share bounded output, one monotonic
source-custody deadline, and complete descendant cleanup. Each command runs
beneath a freshly forked subreaper custody root, so caller children outside that
command subtree are never enumerated, signalled, or reaped. Configured commands
always use Ruby's direct executable/argv form, including one-item commands, so
shell punctuation in a tracked executable name remains literal.

Project media must decode as its declared image/video type. Its published name
contains both source and artifact digests, so an identical recapture is reused
while changed bytes at the same source SHA publish under a new name; superseded
task-owned provider media is removed only after the replacement manifest is
durable.

The policy continues to validate retained `hive-artifact-capture` v1 manifests
against the v1 schema and built-in-recorder requirements. New captures emit v2;
the Web reader validates v2 receipts against the complete shared strict schema,
renders valid v1 and v2 receipts, and hides unknown future versions. This is a
read-compatible migration: existing task evidence does not need rewriting.
Syntactically valid non-object receipts fail closed as unsatisfied, and provider
recapture ignores a retained receipt unless both its root and `recorder` are
objects with the expected provider identity.

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
- Every persisted `ERROR` other than exact operator-owned semantic terminal
  errors, including `tmux_session_terminated`,
  `agent_orphaned`, and `timeout`, follows the universal recovery lifecycle.
  After the shared cooldown and safety checks, `RecoveryCoordinator` admits the
  exact marker generation and reruns artifact collection. There is no
  artifacts-only timeout budget or healer clear path.

## Backlinks

- [[stages/review]] · [[stages/finalize]]
- [[state-model]] · [[commands/stage_action]] · [[modules/workflows]]
- [[commands/screenote]]
