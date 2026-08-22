# OpenCode can use its own isolated temporary directory

**Problem:** Live Webmail execution showed OpenCode writing a bounded analysis
file beneath the `TMPDIR` Hive created for that invocation, then denying its
own direct read as an external-directory access. Shell access could work around
the mismatch, but the selected permission overlay contradicted the environment
Hive supplied and cost autonomous turns.

**Change:** OpenCode prepared invocations now admit only their cleanup-bound
temporary directory (and descendants) through `external_directory`.
Workspace-write mode also adds that root to `edit`; read-only mode retains its
global edit and Bash denial. The sibling config, data, cache, state, and staged
credential roots remain unadmitted, and normal invocation cleanup still
removes the whole owner-verified root.

Component and Hive integration tests cover the generated deny-first policy.

See [[modules/agent_profile]].
