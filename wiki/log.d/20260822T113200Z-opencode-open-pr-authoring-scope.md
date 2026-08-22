# OpenCode open-PR authoring cannot become a publisher

The 5-open-pr agent only authors the bounded `pr-draft.json` input consumed by
Hive's GitHub publication controller. During the Webmail Ox Alpha dogfood, a
project-level `Bash(*)` grant let the OpenCode authoring attempt ignore that
boundary, inspect the host GitHub credential helper, and spend its context on
remote-state queries without producing the draft.

OpenCode open-PR launches now override project-level stage permissions with an
exact edit rule for that attempt's `pr-draft.json`; Bash is denied by the
generated permission overlay. The controller remains the only code path that
can push the branch or mutate GitHub. A focused regression starts from a broad
project permission containing `Bash(*)` and pins the effective workspace-write
root, exact edit pattern, and empty Bash pattern set.
