---
title: Attached local retries and remote dispatch refusal
date: 2026-11-08
---

Local workflow.retry attaches when effective project daemon.enabled is false;
enabled projects retain queued admission. Manual retries use the same request
admission transaction as the daemon with a post-clear progress fence. Stage
output stays in attempt logs; act returns one refreshed outcome envelope and
failed stages exit nonzero, including keyed replay. Remote retry on disabled
projects changes from successful queued admission to HTTP 503
`dispatcher_unavailable`, with an exact local action command and no recovery
request persisted. Existing AdmissionRefused envelopes and API versions remain.

Real coordinator/repository/admission fixtures cover coding and generic stages,
capacity replay, concurrent consumption, input races, terminal reconciliation,
launch failure, and keyed stage failure. A source-observation timestamp must be
captured after recovery's task lease writes, or admission correctly rejects it
as superseded.
