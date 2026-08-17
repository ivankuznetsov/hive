# A stranded local effect no longer deadlocks its occurrence

`assert_terminal_effects!` required every effect cell to be terminal before an
occurrence could finalize. Combined with `retireable?` requiring `finalized`,
one stranded intent deadlocked its occurrence permanently:

- the effect could not settle — no recovery path covered its sink;
- so the occurrence could not finalize;
- so it could not retire;
- so patrol re-ran it every cycle, raised, exited 78, and respawned, holding
  a dispatch slot the whole time.

Observed on todero `occ-3a2c3bb6…`: 255 of 256 effects `committed`, one
`prepared` since 2026-08-16T06:09:20Z targeting `patches/patch-c7a6496d5614-b94239`,
with zero receipts. That patch file does not exist, so the write never landed.
The intent was stranded by a daemon restart 11 seconds later.

The journal exists to stop an unrepeatable action happening twice. That is
only true of externally visible sinks — `pull_request`, `branch`,
`review_handoff` — which still block. `state` and `finding` products are
derived from the repository: the next scan simply recreates them. A stranded
intent on those sinks is now abandoned at finalization instead of blocking.

This also relieves the `MAX_EFFECTS_PER_OCCURRENCE` (256) cap, which that
occurrence had reached.

See [[modules/patrol]].
