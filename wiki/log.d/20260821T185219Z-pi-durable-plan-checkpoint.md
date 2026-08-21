# Pi plan retries retain useful progress

The plan prompt now requires an early non-terminal `plan.md` outline before
extensive research or drafting. The planner refines that checkpoint in place
and writes `<!-- WAITING -->` or `<!-- COMPLETE -->` only on the final update.

This closes a failure reproduced while dogfooding Ox Alpha through Pi on a real
Webmail plan: the model completed substantial repository analysis and composed
a seventeen-unit plan in its response stream, but the upstream stream went idle
before Pi made its first write tool call. Three provider retries therefore left
no durable plan bytes for Hive's workflow retry to resume.

The checkpoint is provider-neutral and keeps the recovery boundary simple: Hive
continues to own retries, the terminal marker continues to own stage completion,
and a retried planner improves the useful partial document already on disk.
