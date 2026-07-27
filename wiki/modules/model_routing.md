---
title: Hive::ModelRouting
type: module
source: lib/hive/model_routing.rb
created: 2026-07-25
updated: 2026-07-27
tags: [config, models, routing, validation]
---

**TLDR**: `Hive::ModelRouting` is the pure, provider-neutral domain for the
closed built-in model/effort vocabulary. It owns registry enumeration,
project ownership, structural parsing, independent field
precedence, provenance, and reachability filtering. It never selects a
provider or renders provider CLI arguments.

## Registry

The public keys are:

`brainstorm`, `plan`, `execute`, `execute_implementation`, `rebase`,
`diagnose`, `babysitter`, `review`, `review_ci`, `review_reviewers`,
`review_triage`, `review_fix`, `review_browser`, `patrol`, `patrol_review`,
`patrol_fix`, `open_pr`, `artifacts`, and `finalize`.

`execute_implementation`, `rebase`, `diagnose`, and `babysitter` inherit from
`execute`; every `review_*` key inherits from `review`; and every `patrol_*`
key inherits from `patrol`. Other keys are roots. Every key is project-owned;
Hive's former in-process PR digest was removed in favour of standalone
PRDigest, so `digest` is intentionally not a route. `entries` and `keys` are
registry-derived frozen enumerations.

## Structural parsing

`parse` accepts one owner and source path, normalizes stage/field names and
surrounding scalar whitespace, and preserves model/effort absence
independently. Entries may contain only `model`, `effort`, or both. The shared
effort vocabulary is `default`, `inherit`, `none`, `minimal`, `low`, `medium`,
`high`, `xhigh`, and `max`; a later selected-profile validation step narrows
that union to controls the reachable provider actually supports.

## Resolution and validation

For each field independently, `resolve` selects:

1. the exact public key;
2. its registered coarse parent;
3. the caller-provided current fallback;
4. the legacy global fallback; or
5. absence.

Each result carries `exact`, `coarse`, `current`, `legacy`, or `absent`
provenance per field. The already-selected provider is passed through
unchanged. An empty configuration or missing stage context bypasses routing
and does not normalize current/legacy values.

`validate_effective!` projects enabled reachable calls through the resolver
and yields only controls whose effective provenance is exact or coarse.
Disabled calls and fully shadowed coarse fields never reach the capability
callback. This keeps structural errors unconditional while deferring
profile-specific capability errors until reachability is known.

Implementation identity composes these public resolutions into the durable
stage lifecycle. `execute`, `open_pr`, `review.fix`, and `review.ci` resolve as
`execute_implementation`, `open_pr`, `review_fix`, and `review_ci`
respectively. Exact/coarse fields override the current implementation
identity; absent routed fields fall back through the existing current/legacy
chain. The selected provider never changes. The effective values and their
provenance are frozen in the journal before launch, so later reconstruction
does not reread live `models:` configuration. Execute resolves before creating
its reviews directory, worktree, pointer, or task marker. Review Phase 4
resolves before its working marker, phase event, Git preparation, or residue
auto-commit. Unsupported effective controls therefore leave those stage
surfaces unchanged.

Non-durable built-in calls resolve immediately before their trusted launch
seam through `Stages::Base.model_routing_arguments`. This covers brainstorm
(headless and tmux), plan, reviewers (including direct Codex and shared Claude
sessions), triage, browser testing, rebase, diagnosis, babysitter, ordinary
patrol, artifacts, and finalize. Architecture Patrol overlays
`patrol_review`/`patrol_fix` while building its immutable review/fix identities,
so policy snapshots and resumed actions observe the same route. Shared Claude
reviewers group by both resolved permission scope and routing arguments.

`Config.validate_model_routing_capabilities!` constructs the enabled,
reachable call/profile matrix after structural validation and before warnings.
It validates only routed effective fields after exact/coarse shadowing.
Runtime helpers repeat validation at the launch boundary as defense in depth
for callers that construct config hashes without `Config.load`; both layers
use the same immutable resolution and profile-native renderer.
