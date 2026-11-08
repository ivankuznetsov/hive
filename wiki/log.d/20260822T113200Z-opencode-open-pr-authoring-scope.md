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

The same live attempt wrote all durable output and then remained CPU-active in
an empty trailing provider turn. OpenCode output-file actors can now supply a
controller validator as a completion probe. For open-PR authoring, a strict
`pr-draft.json` parse starts a five-second normal-exit grace; Hive then stops a
still-running CLI and accepts the validated output. A lifecycle regression
uses a real sleeping child to prove the trailing turn is reaped, the attempt is
not marked timed out, and sanitized export is not required after controller
completion.

The probe keyword is emitted only for OpenCode launches. The first hosted
full-flow run exposed that passing `completion_probe: nil` through the Claude
open-PR path violates its strict launcher signature before authoring starts;
provider-specific controller probes now stay out of shared launch kwargs.
