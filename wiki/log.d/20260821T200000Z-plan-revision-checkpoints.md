# Pi planner revisions start from a durable in-workspace checkpoint

Planner revision now seeds its candidate output with a non-terminal copy of the
immutable input plan and tells the original planner to edit that checkpoint in
place. This gives long-running Pi and OpenRouter workloads durable bytes before
their first replacement write, so a lost provider stream does not also erase
all useful revision context.

The seed has the input plan's trailing `<!-- COMPLETE -->` marker removed and
is written mode `0600` inside the disposable revision worktree. The production
runner accepts or salvages a candidate only when the candidate itself ends in
`<!-- COMPLETE -->`, including when the provider exits successfully, so a
seed-only result remains a bounded retryable failure.

This was reproduced while dogfooding a real 21.5 KB Webmail.sh plan: Ox Alpha
spent minutes actively revising before its first candidate write. The same
late-write shape had already caused repeated Pi plan loss, making a
controller-owned checkpoint preferable to depending on provider timing.
