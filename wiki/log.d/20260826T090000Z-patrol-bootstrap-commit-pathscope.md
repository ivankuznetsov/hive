---
title: Scope project-root bootstrap commits to their own paths
type: fix
tags: [patrol-fix, git_ops, init]
---

Patrol found that `GitOps#add_hive_state_to_master_gitignore!` and
`commit_llm_wiki_bootstrap!` ran `git commit -m <msg>` with no pathspec in
the project root, committing the whole index — any file the user had already
staged rode along under hive's bootstrap message. The llm-wiki
staged-emptiness check (`git diff --cached --quiet`) likewise inspected the
whole index.

Both commits are now pathspec-limited to exactly the paths each helper just
staged, and the emptiness check is scoped to the same pathspecs. The user's
staging area is untouched afterwards. Regression tests cover both helpers.
