## Claude review prompts through stdin

Todero 43110 reached the disposable review checkout but failed before Claude
started: its prompt exceeded the OS per-argument limit. The built-in Claude
profile now uses the existing piped-stdin transport; no prompt truncation or
new transport abstraction is needed. Tests cover a 256 KiB real process launch.
The task's diff was 37 MB because an earlier repair removed tracked dependencies.
Review now carries exact Git revisions and the diff digest rather than inlining
the patch; reviewers inspect the complete patch in their disposable checkout.
Publication recovery coverage now exercises adoption failures, consecutive
rebases, CLI dispatch, and revalidation replay. An unreachable old publication
guard was removed; observed PRs already use the revision reconciliation path.

Todero 43103's dependency residue was traced to the 10:38 review on the old
runtime, before disposable review was deployed at 11:58. This was retained
pre-deployment dirt, not evidence of a new disposable-checkout regression.
