## [2026-07-13T21:45:00Z] workflows/daemon — preserve quota retry semantics in generic agent stages

**Action:** Fixed `Hive::Stages::Agent` treating every `{status: :error}` spawn
envelope as `agent_preflight_failed`. A live built-in benchmark extract stage
hit Claude's session wall; `Hive::Agent` correctly wrote
`ERROR reason=limits_reached retry_after=...`, but the generic runner immediately
overwrote it with the permanent preflight marker, preventing the daemon's quota
cooldown healer from retrying the task. The runner now preserves an existing
quota marker, recognizes provider-limit text in markerless error envelopes,
stamps the selected profile when it owns the marker, and returns the distinct
`limits_reached` commit action. Genuine version/preflight failures keep their
existing `agent_preflight_failed` behavior. Added focused regression coverage
for both the marker-preserving and markerless-envelope paths. The built-in
benchmark descriptor now also pins its shell-control stages to Codex
and gives generate/judge seven-day timeouts (extract/publish retain one hour),
so a deliberately serialized multi-cell campaign neither consumes the Claude
account merely to launch scripts nor dies at the generic one-hour ceiling.
