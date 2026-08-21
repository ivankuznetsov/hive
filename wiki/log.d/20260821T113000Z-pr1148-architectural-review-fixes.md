# PR 1148 architectural review fixes

Provider failure extraction now emits typed limit, rate-limit, output-limit,
and generic provider errors; trusted completion evidence wins over transient
mid-stream provider errors. Agent signal handlers chain cooperative shutdown.

Artifact custody uses one exact-inventory manifest with a configurable 128
default and a 4096 hard ceiling. Plan reviewers run in detached disposable Git
worktrees with repository, shell, and network access while the live checkout
remains structurally separate. Stable failed reviewer capability probes park
without repeatedly buying expensive attempts.

Review guardrail exceptions are exact `(pattern, SHA-256(full match))` waivers,
not path/value allowlists or a global bypass. Applied waivers emit task events.
Legacy attributed dirty-worktree waits moved from the daemon tick loop into
one-shot migration.

Recovery requests retain stage-scoped failure fingerprints, consecutive counts,
and bounded attempt history. Changing failures retry freely; repeated failures
surface degraded state; proven repeats at the retry-ladder ceiling park as
`deterministic_failure`. Terminal cleanup is stage-scoped, attempt-loss pacing
uses the same ladder, and deleted-task observations are not left pending.

Plan-review identity now includes adapters and reviewers but excludes timeout
and retry tuning. Plan-review attempts receive a semantic owner progress token,
stranded regenerable patrol effects remain as terminal `abandoned` audit rows,
and council max-round exits share one consistent terminal path.
Reviewer prompts now reserve finding-lifecycle transitions for Hive and require
every newly emitted finding to start at `open`; this removes an ambiguity that
caused a successful Ox review to be rejected after it described a finding as
closed.

The in-repo agent-cli-runtime candidate is 0.2.3. This change prepares its
version, changelog, lockfile, mirror, and package assertions; publication is a
separate release action.
