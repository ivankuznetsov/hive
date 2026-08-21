# OpenCode preserves upstream timeouts as transient outcomes

A real Ox Alpha planning run through OpenCode survived internal retries for 43
minutes, wrote a useful partial plan, and then exited nonzero with OpenRouter's
typed 504 `Upstream idle timeout exceeded` event. OpenCode's strict result
normalizer reduced that event to generic `cli_failure`, hiding that the failure
was provider-transient from Hive's marker and recovery surfaces.

The OpenCode result parser now recognizes the observed upstream timeout shape
and returns `timed_out`. Hive maps that normalized outcome to agent status
`timeout` and the existing marker reason `timeout`, including the provider and
bounded diagnostic. Controller-owned plan checkpoints remain in place, so the
daemon can retry from useful bytes instead of treating the transport failure as
a deterministic implementation defect.

A subsequent retry exposed the sibling zero-exit shape: OpenCode can emit an
empty terminal assistant message after file-tool work. Hive now lets a current
terminal state-file artifact beat that malformed chat transcript, matching the
existing completion-over-provider-error rule. A partial or markerless artifact
still fails and retries; the dogfood attempt that exposed the shape did not
receive false completion authority.

The fixture corpus pins the sanitized real event shape, and lifecycle coverage
pins the resulting task marker. No provider fallback or model substitution is
introduced.
