## [2026-07-26T02:41:08Z] Agent Artifact Firewall boundary

**Action:** Promoted the Agent Artifact Firewall to `boundary-ready` behind
`require "hive/artifact_firewall"`. Added immutable manifest, snapshot,
violation, restoration, and report values; typed protected-anchor and
required-output violations; no-follow content/type/mode identity; immutable
in-memory capture with descriptor-bound baseline identity; protected-parent
substitution detection and restoration refusal; realpath-aware output-root
acceptance; bounded injectable redaction; snapshot binding; and verified
non-recursive safe restore.

**Hive dogfood:** Execute, open-PR, finalize, review fix/triage/CI-fix, and the
managed draft-PR worktree now supply stage policy through the facade.
Headless Agent and interactive Claude `:output_file_exists` polling reject
symlinks and non-regular artifacts. `Hive::ProtectedFiles` remains the internal
compatibility engine, and the component contract rejects new production
bypasses.

**Guarantee:** This is same-user application-level artifact custody, not an OS
sandbox, write monitor, filesystem transaction, or replacement for the Safe
Agent Git Gate. Hive still owns path selection, markers, retries, report
meaning, and stage success.

**Docs:** Updated [[modules/protected_files]], [[modules/secret_patterns]],
[[component-boundaries]], [[testing]], [[gaps]], and [[index]]. Did not edit
compiled [[log]].

**Mainline sync:** Replayed the boundary over the delivered-task recovery
changes from #865. Open-PR and finalize retain current immutable PR identity
checks and recovery behavior inside the firewall custody wrapper.

**Hosted-CI follow-up:** Managed-worktree Git control paths are expanded and
deduplicated before manifest construction. This keeps strict duplicate-anchor
rejection in the public firewall while accepting CI environments where
`XDG_CONFIG_HOME` or `GIT_CONFIG_GLOBAL` names the same file already derived
from `HOME`.
