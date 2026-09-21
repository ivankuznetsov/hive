# Bench campaign contract shared across generation and judging

**Fix:** Packaged benchmark generation had its own partial copy of the judge
configuration contract. It omitted the Codex provider/provider-model flags,
ignored OpenCode candidates when deciding whether to preflight OpenRouter, and
kept relative campaign sources relative after changing directories. Generation
could therefore use a different judge transport than backfill, spend before an
OpenCode credential failure, or fail to write a quota marker through the
campaign runtime.

**Action:** Added `HiveBench::CampaignContract` as the single validator and
argument compiler used by `generate.md`, `judge.md`, and `JudgeSlate`. Campaign
sources are canonicalized against the benchmark repository and checked for the
marker runtime before generation; historical judge backfill validates only the
durable fields it consumes. OpenRouter admission now covers standalone and
Codex-routed judges plus both Pi and OpenCode candidates. Strict egress now
inspects the internal Docker network once, before parallel cells attach, and
requires the named CONNECT proxy to be its only existing peer.
