---
title: 7-artifacts stage
type: stage
source: lib/hive/stages/artifacts.rb
created: 2026-05-22
updated: 2026-08-30
tags: [stage, artifacts, evidence, review]
---

**TLDR**: `7-artifacts` now completes only after Hive publishes a strict,
identity-bound outcome-evidence package. A fresh read-only inference agent maps
the task, plan, and exact committed diff into user-meaningful claims; a separate
producer makes the required proof; and a third fresh read-only reviewer accepts,
targets evidence for recapture, returns repository defects for implementation
rework, or blocks every claim and supported exclusion. Legacy
Hivebox screenshots and recordings remain visible diagnostics but never establish
completion authority.

## Preconditions

1. The task arrives from `6-review` with `REVIEW_COMPLETE` when using
   `hive artifacts` as a workflow verb.
2. The controller-owned task worktree pointer and optional draft-PR receipt must
   agree on the implementation branch, base, worktree, and saved head.
3. The implementation worktree must be clean. Evidence covers only the committed
   `base..HEAD` range; staged, unstaged, untracked, or symlink changes fail closed.
   A compatibility recovery exists only for attempts made by the retired direct
   runtime-directory bind: after the exact `implementation worktree must be clean`
   artifact failure, the daemon may quarantine exclusively untracked regular files
   below `log/`, `storage/`, or `tmp/`. It records a digest journal under the task,
   refuses tracked/staged/other-path/symlink/large residue, and retries normally.
   The files are preserved outside the implementation range rather than deleted or
   auto-committed into the product.
4. The durable attempt must own the current task generation and `7-artifacts`
   stage before the ledger can be opened.

## Controller flow (`Stages::Artifacts.run!`)

1. Resolve the immutable implementation base/head and the exact sorted changed
   paths. The controller re-resolves this identity after every agent role so a
   role cannot change the source behind the evidence. It also materializes the
   exact binary diff once under the immutable generation and supplies
   its path, size, and SHA-256 receipt to both read-only semantic roles; neither
   role needs shell or Git authority.
2. Launch a fresh read-only **inference** context. It reads `task.md`, `plan.md`,
   and the exact diff, inventories every promised outcome and acceptance
   criterion, then returns a bounded set of outcome claims plus justified
   exclusions. Every changed path and promised outcome must trace to at least
   one claim or exclusion. Inference prefers one to three grouped outcomes and
   may return at most five, but grouping cannot omit an outcome and each claim
   must remain narrow enough for one truthful artifact of its selected proof
   kind to demonstrate completely. Each claim chooses exactly one closed proof
   kind: `screenshot`, `video`, `terminal`, or `document`.
3. Persist the immutable requirement under the task's outcome-evidence
   generation. The generation binds project/task, durable task generation,
   controller recovery epoch, base, head, and changed-path digest.
4. Preflight the configured producer and reviewer. A video requirement needs a
   review pipeline that retains temporal video and exposes controller-derived
   ordered frames to the semantic reviewer. Screenshot/video/terminal
   production needs a workspace-sandboxed producer; a document-only producer may
   use Hive's controller-scoped Claude edit boundary.
5. Resolve one controller-owned capture toolkit before production. Web proof
   receives `hive evidence browser`, a closed gateway to the exact pinned
   native `agent-browser` and managed Chrome;
   terminal proof receives Hive's native PTY command; visual proof also requires
   `ffmpeg`, `ffprobe`, and Tesseract. The browser gets one random `.invalid`
   origin mapped through a controller-owned proxy to one issued loopback app
   port, rather than access to every localhost service. Hive launches and
   verifies the exact browser session before production. A controller-managed
   Hive Web runtime is opened immediately; for any other project, Hive verifies
   the browser on `about:blank`, then the producer starts the changed app on the
   issued port before opening the private origin. The producer receives only a bounded
   filesystem mailbox used by `hive evidence`; the raw browser socket,
   controller-private browser state, and media staging stay outside its sandbox.
   For non-Hive visual proof, a Pi producer also receives `hive evidence server`:
   it selects one executable repository command, while Hive runs that command
   on the exact issued port in a credential-free bubblewrap sandbox, proves HTTP
   readiness, keeps it alive for the attempt, and tears it down by exact process
   identity. The project source is read-only except for existing runtime `log/`,
   `storage/`, and `tmp/` directories. Codex's managed network proxy runs in
   limited mode with no admitted domains and local binding enabled, so a producer
   may start the issued application port but cannot connect directly to arbitrary
   loopback services. The closed filesystem policy admits the controller's exact
   Ruby executable, sibling binstubs, runtime libraries, and active gem paths; an
   env shebang therefore cannot silently fall through to a different system Ruby.
   Producers use already-installed locked dependencies and cannot contact package
   registries. The controller executes admitted browser/terminal operations,
   records exact file receipts, and exclusively publishes basename-only PNG/WebM
   media into the evidence root. Controller-side terminal commands use the same
   credential-free project sandbox, while retaining the requested product command
   rather than Hive's sandbox wrapper. Missing capabilities publish a durable
   blocker before the producer starts; a paced daemon retry rechecks it against
   the same immutable requirement rather than replaying a stale capability verdict.
6. Launch a distinct **producer** context with one writable root under the active
   evidence attempt. Source and controller metadata remain read-only. Every proof
   names one retained original, one bounded reviewer representation, and the
   claims it establishes. The controller—not the LLM—adds exact byte counts,
   SHA-256 digests, rendering, and implementation-head source identity.
   A managed PNG or WebM may fill both representation roles from one
   controller-issued capture path; custody transfer creates distinct immutable
   retained copies rather than requiring the producer to duplicate media. This
   is only a task-producer custody-ingress exception: direct ledger admission,
   project-provider evidence, and non-visual evidence still require distinct
   role paths.
   Screenshot, video, and terminal representations must match a controller
   capture receipt at handoff; producer-written lookalike media fails closed.
7. Re-admit every retained representation deterministically: safe containment,
   size, hash, declared media type, actual image/video decode, terminal-cast or
   document structure, secret patterns, and provider provenance are checked
   without deciding whether the proof is persuasive.
8. Launch a third fresh read-only **reviewer** context. It must inspect every
   retained representation and return exactly one reasoned verdict for every claim
   and exclusion. For video, Hive keeps the real temporal representation as the
   user-facing proof and derives a six-frame ordered contact sheet directly from
   the admitted video for safe semantic inspection. Uncertainty cannot be accepted.
   Hive records the exact immutable review scope instead of pretending a copied
   hash list is a per-tool access log.
9. `accepted` publishes the append-only attempt and atomic `current.json`, then
   writes `COMPLETE`. `revise` requests only replacement proof for failed
   claims, preserves already accepted evidence, and permits a bounded attempt
   to improve any nonempty subset of requested claims. Unaddressed claim
   evidence is retained; Hive reassembles the full package and sends it through
   a fresh review. `rework` means the reviewed source, configuration, tests, or
   repository documentation must change. Hive publishes a digest-bound rework
   pointer and semantic `ERROR`; the daemon then dispatches the exact
   controller-owned `hive evidence rework` transition back to `4-execute`.
   Reviewer targets and reasons enter the implementation prompt as untrusted
   repair context, while the reviewed package and append-only authorization
   receipts stay protected. The distinct `outcome_evidence_rework` action is
   routed through its exact digest-bound command by daemon, Web, Telegram, and
   operational adapters. An unchanged implementation tree cannot return to
   artifacts, even when the implementer creates an empty commit. `blocked` is
   reserved for an operator-owned credential,
   environment, or decision that repository work cannot solve. Invalid
   exclusions, missing capability, exhausted recaptures, or exhausted
   implementation reworks publish an operator-visible blocked pointer and
   semantic `ERROR`.

The default is one initial attempt plus at most two targeted recaptures. Project
configuration may reduce recaptures to zero or one, but cannot exceed two.
Implementation rework has a separate fixed bound of two reviewed returns to
`4-execute`; the third request becomes `reworks_exhausted` rather than looping.

## Proof selection

- Use `screenshot` for one stable web/interface state, or a coherent set of
  stable screens establishing one outcome.
- Use `video` for a flow, transition, timing, ordering, or behavior across
  states. A pair of screenshots or storyboard does not replace temporal video.
- Use `terminal` for CLI/TUI behavior. The retained original is an asciinema
  v2-compatible cast and the reviewer representation is bounded plain text.
  `hive evidence terminal NAME -- COMMAND...` produces both through a Ruby PTY
  under Linux subreaper custody, without asciinema, VHS, a shell, or terminal-GIF
  conversion. Success, nonzero exit, timeout, and output overflow all reap the
  complete descendant tree; a detached child invalidates the capture.
  Source checkouts that load `agent-cli-runtime` directly from the monorepo
  component remain supported: the custody worker carries the exact loaded
  feature path even when no RubyGems specification was activated.
- Use `document` for invisible/refactoring outcomes, using safe text, Markdown,
  JSON, or static image material that explains the resulting contract, schema,
  or architecture. Active HTML, SVG, and PDF are not admitted. Static images
  and video up to 30 seconds are OCR-scanned for secret-shaped content before
  review.

This semantic selection is intentionally agent-inferred from task intent and the
exact diff. Controller code validates closed structure, integrity, custody, and
traceability; it does not guess user meaning from filenames.

Web capture has one producer interface: the controller-issued `hive evidence
browser` gateway to the pinned native `agent-browser` CLI. Producers do not
receive the raw daemon socket and do not discover or choose Firefox,
Playwright, Puppeteer, QML, or ImageMagick. Stable interface state uses a
screenshot; navigation, ordering, timing, and state transitions use temporal
video. The gateway accepts only the issued origin, a closed interaction
vocabulary, and basename PNG/WebM output. It stages media privately and
publishes it no-follow/exclusive into the writable attempt root.
The controller probes each stopped recording before publication and rejects an
over-30-second take immediately, clearing the stopped session so the producer
can capture a shorter replacement in the same attempt. This keeps the capture
tool's acceptance boundary aligned with final proof admission instead of
discovering the duration error only after the producer exits. Hive closes
the named browser session before it cleans the managed app/proxy and producer
process group. Playwright remains a web-system-test dependency, not an
outcome-evidence capture interface.

The typed Pi `evidence_browser` tool accepts one complete action `argv`, with
the action verb as its first element (for example `open, ISSUED_ORIGIN` or
`snapshot, -i`). It has no parallel `command` field. Keeping one argv matches
the prompt's command examples and prevents the extension from duplicating an
already-present verb into `open open URL` before the exact-origin gateway.

The capture proxy keeps the application-facing `Host` on the exact issued
loopback port, preserving development host allowlists. At that boundary it
maps only the controller-issued browser origin in `Origin` and `Referer`
request headers to the same loopback endpoint, so framework CSRF/origin checks
see metadata consistent with `request.base_url`; foreign values pass through
unchanged for the application to reject. Exact loopback absolute redirects
are translated back to the issued browser origin.

When Hive is not itself the reviewed application, Pi visual producers receive
a second controller-issued capability, `evidence_server`. The producer calls it
once with a repository executable and arguments that bind to the issued port;
it never starts a long-lived process through terminal capture or a detached
shell. Hive validates that exact executable beneath the frozen source root,
starts it with a closed environment and bounded diagnostics, waits for the
issued HTTP endpoint, and owns teardown. Other producer profiles retain their
existing workspace sandbox behavior.

Inside a durable explicitly routed attempt, that admitted provider/model/effort
is authoritative for all three fresh role processes and is what actor receipts
report. Per-role agent/model settings remain an unrouted compatibility fallback;
fresh context identity, read/write scope, and semantic responsibility stay
distinct even when one admitted provider route executes all roles.

Each evidence role starts with an isolated child environment containing only
reviewed runtime, locale, provider-session, and desktop-session keys. Arbitrary
project credentials are not inherited. Before that environment is cleared,
Hive resolves a bare provider command past tool-manager launchers to a concrete
executable; opaque tool-manager session variables are never copied into the
role. OpenCode inference and reviewer roles receive their read-only access
through OpenCode's typed per-run permission input; Hive never forwards the legacy
`allowed_tools` or `disallowed_tools` channels to those launches. Producer
paths are task-relative, must begin with the controller-issued
attempt root, and cross a no-follow, hash-checked custody copy before the
reviewer starts. Raw producer workspace files are removed after admission or
failure. The reviewer reads the original task, plan when present, and exact
frozen diff as well as the validated requirement.

The producer contract names the exact representation shape and media types, but
it does not lower the semantic bar to whatever can be rendered. Generated
slides, terminal-styled composites, narrated summaries, diagrams, and pictures
of test output do not establish actual screenshot, flow, or terminal behavior.
Public CLI/TUI claims must record the shipped entrypoint itself; custom evidence
scripts, simulations, and test runners remain supporting diagnostics rather
than substitutes for the user-visible command. Focused tests may prove an
internal claim only when the claim is bounded to the behavior they exercise.
The independent reviewer must reject those substitutes and request a targeted
recapture of the real product surface or transition.

## Ledger and recovery

The append-only requirement and attempts live under
`<task>/outcome-evidence/generations/<generation>/`; the same generation also
contains its append-only `implementation.diff`. Only
`<task>/outcome-evidence/current.json` is replaceable. Hivebox validates the
pointer and immutable document digests when listing a package without rerunning
OCR/ffmpeg across every retained representation. A representation request then
revalidates that selected file's exact size and digest before streaming it.
Write admission and publication remain responsible for complete media decoding,
OCR, retained-proof validation, and independent review.

Reviewer and recapture-exhaustion blockers suppress ordinary daemon retry.
Capability blockers preserve the same audit package but are re-probed on a
paced ordinary retry, so restored controller tools do not require an operator
acknowledgement. The task page, status diagnostic, and run output still expose
an exact command containing the blocked generation and recovery digest:

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

Implementation rework is not an operator acknowledgement and does not use the
recovery epoch. The current pointer binds the exact reviewed generation and
recovery digest; `TaskAction` projects those values into `hive evidence rework`,
and the daemon's ordinary ready-action path runs that controller-only command.
The transition appends one of two task-level authorization receipts, rearms the
coding workflow from `7-artifacts` to `4-execute`, and leaves the rejected
evidence generation immutable for audit.

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
- An implementation-rework pointer is a semantic `ERROR` that surfaces the
  exact digest-bound `hive evidence rework` command. The daemon dispatches it
  automatically without provider-route admission, returning the task to
  `4-execute`; it is not handled by the same-stage stale-error healer.
- Capability, review, and recapture-exhaustion blockers are durable `ERROR`
  rows with the exact `hive evidence recover` command. Paced automated recovery
  re-probes capability blockers in the same generation. It does not clear an
  independent review block or exhausted recapture decision.
- Integrity, role-launch, source-drift, or malformed-output failures use
  `ERROR reason=outcome_evidence_invalid` and retain their bounded diagnostic;
  they remain ordinary recoverable stage errors.
- The daemon bridges residue from the old direct-bind artifact runtime only for
  the exact clean-worktree diagnostic and only through the bounded, recoverable
  quarantine described above. Current capture commands use private runtime
  overlays, so successful teardown leaves no source residue to recover.
- A role process that returns a typed provider failure keeps that envelope at
  the controller boundary. Quota and credit failures publish
  `ERROR reason=limits_reached provider=<profile> retry_after=<iso8601>` and
  return `commit=limits_reached`, so daemon recovery observes the normal
  provider cooldown instead of immediately replaying an expensive inference,
  producer, or reviewer prompt. Other typed provider failures retain
  `reason=provider_error`, the provider, status code when supplied, and a
  bounded message rather than being mislabeled as invalid evidence.

## Backlinks

- [[stages/review]] · [[stages/finalize]]
- [[state-model]] · [[commands/evidence]] · [[commands/web]]
- [[modules/config]] · [[modules/workflows]]
