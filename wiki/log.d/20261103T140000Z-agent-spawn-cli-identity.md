## Preserve the executable selected at agent spawn

Main agent, OpenCode, diagnosis, digest, display-name and native Codex-review
spawns now retain immutable CLI identity and private redacted spawn evidence.
Managed bindings identify the host agent executable separately from the
sandbox launcher. Successful concrete version observations use a bounded,
context-sensitive cache with concurrent coalescing and replacement invalidation.
Diagnostic failures remain nonfatal and minimum-version policy is unchanged.

Integration also covered combined prerelease/build version suffixes, isolated
controller-only overrides, bounded real probe output, and the procfs ESRCH race
when a process disappears during custody enumeration.
