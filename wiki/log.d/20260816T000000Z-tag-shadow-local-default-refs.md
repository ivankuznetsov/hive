# Tag shadowing: local default refs are now fully qualified

- 2026-08-16 · `lib/hive/worktree.rb` · patrol fix
  `patrol-same-named-tag-shadows-branch-in-b4a0b100d2`

## What changed

`Hive::Worktree` no longer uses bare short branch names as revision strings
where a same-named tag could shadow the local branch (gitrevisions precedence:
`refs/tags/<name>` beats `refs/heads/<name>`):

1. `freshest_base`'s two local-fallback arms (no origin remote; fetch failure)
   now return `refs/heads/<default>` instead of the bare `<default>`. Before,
   `git worktree add -b <branch> <default>` either failed on git's ambiguity
   error or silently based the new worktree on the tagged commit instead of
   the branch tip.
2. `default_base_refs` now pushes fully-qualified `refs/heads/<default>` for
   the local measurement ref in `empty_placeholder?`. Before, a tag named
   `<default>` sitting at a placeholder's tip made
   `rev-list --count <default>..refs/heads/<branch>` return 0 against the
   TAG, "proving" emptiness for a branch that carried unique commits beyond
   `refs/heads/<default>` — and `create!` then deleted that branch
   (`git branch -D`). This was real data loss for stacked placeholders.

This completes the qualification pattern already used by
`override_local_or_default` (`refs/heads/<prereq>`) and the explicit fetch
refspec.

## Tests

- `test_create_from_local_default_resolves_branch_not_same_named_tag` —
  no-origin creation must base on `refs/heads/master`, not a same-named tag.
- `test_placeholder_survives_when_same_named_tag_shadows_default` — a
  placeholder with unique commits beyond `refs/heads/master` survives when a
  tag named `master` sits at its tip.

## Notes

The deletion path is intentionally non-atomic behind a positive-emptiness
proof; this fix narrows what can count as proof rather than changing the
delete-then-recreate design.
