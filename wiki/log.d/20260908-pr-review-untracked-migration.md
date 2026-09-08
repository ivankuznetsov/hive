## Preserve untracked legacy PR reviews during migration

The Webmail PR #3 rollout exposed an untracked legacy task folder. After moving it, Git rejected its old path because no tracked deletion existed. Migration now stages the old path only if Git tracks it, while always committing the new task and preserved history. A real-Git regression reproduces this case; existing tracked-task and failed-commit rollback tests remain in place.
