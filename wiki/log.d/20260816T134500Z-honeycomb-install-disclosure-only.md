## [2026-08-16T13:45:00Z] workflow — make verified Honeycomb install disclosure-only

**Action:** Removed the redundant `--yes` and `--allow-escalation` gates from
`hive workflow install`. Hive still verifies immutable catalog/package identity
and runtime policy, prints the declared network/filesystem/secret access before
the human-mode mutation, and returns the same permissions in JSON. Update,
remove, publish, and external publication boundaries are unchanged. Updated the
canonical Hive skill so agents run ordinary verified installs directly instead
of inserting preview/approval loops.

**Coverage:** Focused workflow lifecycle tests now prove JSON and interactive
installs proceed without consent flags, including unbounded and high-risk
declarations, while human output contains the access warning and no `[y/N]`
prompt. Public workflow examples, command/module wiki pages, and release copy
match the new CLI contract.
