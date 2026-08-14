---
title: 7-artifacts stage
type: stage
source: lib/hive/stages/artifacts.rb
created: 2026-05-22
updated: 2026-08-14
tags: [stage, artifacts, evidence, review]
---

**TLDR**: `7-artifacts` now completes only after Hive publishes a strict,
identity-bound outcome-evidence package. A fresh read-only inference agent maps
the task, plan, and exact committed diff into user-meaningful claims; a separate
producer makes the required proof; and a third fresh read-only reviewer accepts,
targets for recapture, or blocks every claim and supported exclusion. Legacy
Hivebox screenshots and recordings remain visible diagnostics but never establish
completion authority.

## Preconditions

1. The task arrives from `6-review` with `REVIEW_COMPLETE` when using
   `hive artifacts` as a workflow verb.
2. The controller-owned task worktree pointer and optional draft-PR receipt must
   agree on the implementation branch, base, worktree, and saved head.
3. The implementation worktree must be clean. Evidence covers only the committed
   `base..HEAD` range; staged, unstaged, untracked, or symlink changes fail closed.
4. The durable attempt must own the current task generation and `7-artifacts`
   stage before the ledger can be opened.

## Controller flow (`Stages::Artifacts.run!`)

1. Resolve the immutable implementation base/head and the exact sorted changed
   paths. The controller re-resolves this identity after every agent role so a
   role cannot change the source behind the evidence.
2. Launch a fresh read-only **inference** context. It reads `task.md`, `plan.md`,
   and the exact diff, then returns a bounded set of outcome claims plus justified
   exclusions. Every changed path must trace to at least one claim or exclusion.
   Each claim chooses exactly one closed proof kind: `screenshot`, `video`,
   `terminal`, or `document`.
3. Persist the immutable requirement under the task's outcome-evidence
   generation. The generation binds project/task, durable task generation,
   controller recovery epoch, base, head, and changed-path digest.
4. Preflight the configured producer and reviewer. A video requirement needs a
   reviewer that can inspect actual temporal video. Screenshot/video/terminal
   production needs a workspace-sandboxed producer; a document-only producer may
   use Hive's controller-scoped Claude edit boundary.
5. Launch a distinct **producer** context with one writable root under the active
   evidence attempt. Source and controller metadata remain read-only. Every proof
   carries one retained original and one bounded reviewer representation, exact
   byte count and SHA-256, implementation-head source identity, and the claims it
   establishes.
6. Re-admit every retained representation deterministically: safe containment,
   size, hash, declared media type, actual image/video decode, terminal-cast or
   document structure, secret patterns, and provider provenance are checked
   without deciding whether the proof is persuasive.
7. Launch a third fresh read-only **reviewer** context. It must inspect every
   retained hash, return exactly one reasoned verdict for every claim and
   exclusion, and inspect the temporal video itself for video claims. Storyboards
   are supplemental only; uncertainty cannot be accepted.
8. `accepted` publishes the append-only attempt and atomic `current.json`, then
   writes `COMPLETE`. `revise` requests only the failed claim proofs, preserves
   already accepted evidence, reassembles the full package, and sends the whole
   package through a fresh review. `blocked`, an invalid exclusion, missing
   capability, or exhausted recaptures publishes an operator-visible blocked
   pointer and semantic `ERROR`.

The default is one initial attempt plus at most two targeted recaptures. Project
configuration may reduce recaptures to zero or one, but cannot exceed two.

## Proof selection

- Use `screenshot` for one stable web/interface state, or a coherent set of
  stable screens establishing one outcome.
- Use `video` for a flow, transition, timing, ordering, or behavior across
  states. A pair of screenshots or storyboard does not replace temporal video.
- Use `terminal` for CLI/TUI behavior. The retained original is an asciinema
  cast and the reviewer representation is bounded plain text.
- Use `document` for invisible/refactoring outcomes, using safe text, Markdown,
  JSON, or static image material that explains the resulting contract, schema,
  or architecture. Active HTML, SVG, and PDF are not admitted. Static images
  and video up to 30 seconds are OCR-scanned for secret-shaped content before
  review.

This semantic selection is intentionally agent-inferred from task intent and the
exact diff. Controller code validates closed structure, integrity, custody, and
traceability; it does not guess user meaning from filenames.

Each evidence role starts with an isolated child environment containing only
reviewed runtime, locale, provider-session, and desktop-session keys. Arbitrary
project credentials are not inherited. Before that environment is cleared,
Hive resolves a bare provider command past tool-manager launchers to a concrete
executable; opaque tool-manager session variables are never copied into the
role. Producer paths are task-relative, must begin with the controller-issued
attempt root, and cross a no-follow, hash-checked custody copy before the
reviewer starts. Raw producer workspace files are removed after admission or
failure. The reviewer reads the original task, plan when present, and exact
frozen diff as well as the validated requirement.

The producer contract names the exact representation shape and media types, but
it does not lower the semantic bar to whatever can be rendered. Generated
slides, terminal-styled composites, narrated summaries, diagrams, and pictures
of test output do not establish actual screenshot, flow, or terminal behavior.
The independent reviewer must reject those substitutes and request a targeted
recapture of the real product surface or transition.

## Ledger and recovery

The append-only requirement and attempts live under
`<task>/outcome-evidence/generations/<generation>/`; only
`<task>/outcome-evidence/current.json` is replaceable. Hivebox revalidates the
pointer, every document digest, every retained proof, and the independent review
before rendering claims or serving a representation.

A semantic blocker suppresses ordinary daemon retry. The task page, status
diagnostic, and run output expose an exact command containing the blocked
generation and recovery digest:

```sh
hive evidence recover PROJECT:SLUG \
  --generation <sha256> \
  --recovery-digest <sha256>
```

That command does not rewrite history. It performs a stale-safe compare-and-set,
advances a separate controller recovery epoch once, and leaves the existing
generation intact for audit. Refresh operational status and invoke its guarded
`workflow.retry` action to start a new evidence generation. See
[[commands/evidence]].

## Legacy capture diagnostics

`capture-requirement.json`, `media/capture-manifest.json`, and the older
`media/manifest.json` remain readable for historical compatibility and Hivebox
diagnostics. Project-provider manifests may participate as a proof source only
when they explicitly declare `evidence_role: claim_evidence` and pass the new
proof contract. Built-in synthetic Hivebox media is always diagnostic-only and
cannot be admitted as accepted outcome evidence.

The Hivebox task page leads with the verified outcome claims, proof kind,
representations, verdict rationale, traceability, attempts, agent/model/effort,
and reviewer capability. Legacy media follows in a visibly labelled
`Legacy diagnostic` section.

## Marker -> next action

- A valid accepted pointer is projected as `COMPLETE` and surfaces
  `ready_to_finalize`.
- Capability, review, and recapture-exhaustion blockers are semantic `ERROR`
  rows with the exact `hive evidence recover` command. Automated recovery does
  not clear them.
- Integrity, role-launch, source-drift, or malformed-output failures use
  `ERROR reason=outcome_evidence_invalid` and retain their bounded diagnostic;
  they remain ordinary recoverable stage errors.

## Backlinks

- [[stages/review]] · [[stages/finalize]]
- [[state-model]] · [[commands/evidence]] · [[commands/web]]
- [[modules/config]] · [[modules/workflows]]
