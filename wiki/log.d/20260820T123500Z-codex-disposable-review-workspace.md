# Codex plan review starts in disposable workspaces

Codex plan-review launches now include `--skip-git-repo-check` alongside the
existing workspace-write sandbox. Plan review deliberately runs from a
disposable non-git directory containing the immutable plan copy and result;
without the flag Codex 0.147.0 exited before reviewing with `Not inside a
trusted directory and --skip-git-repo-check was not specified`.

This is scoped to Codex plan review. It does not disable the Codex filesystem
sandbox, broaden write custody, or change the other provider profiles.
