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

The fixture corpus pins the sanitized real event shape, and lifecycle coverage
pins the resulting task marker. No provider fallback or model substitution is
introduced.
