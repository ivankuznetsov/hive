---
title: Hive::ModelRouting
type: module
source: lib/hive/model_routing.rb
created: 2026-07-25
updated: 2026-07-25
tags: [config, models, routing, validation]
---

**TLDR**: `Hive::ModelRouting` is the pure, provider-neutral domain for the
closed built-in model/effort vocabulary. It owns registry enumeration,
project/global-digest ownership, structural parsing, independent field
precedence, provenance, and reachability filtering. It never selects a
provider or renders provider CLI arguments.

## Registry

The public keys are:

`brainstorm`, `plan`, `execute`, `execute_implementation`, `rebase`,
`diagnose`, `babysitter`, `review`, `review_ci`, `review_reviewers`,
`review_triage`, `review_fix`, `review_browser`, `patrol`, `patrol_review`,
`patrol_fix`, `open_pr`, `artifacts`, `finalize`, and `digest`.

`execute_implementation`, `rebase`, `diagnose`, and `babysitter` inherit from
`execute`; every `review_*` key inherits from `review`; and every `patrol_*`
key inherits from `patrol`. Other keys are roots. `digest` is owned by the
global digest config; all other keys are project-owned. `entries` and `keys`
are registry-derived frozen enumerations.

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
does not reread live `models:` configuration.
