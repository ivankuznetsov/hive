## [2026-07-20T14:31:28Z] operations — add an agent-first Hive control plane

**Action:** Added the additive `hive-operational-status.v1` projection while
preserving `hive-status.v6`, made concise operational status the human default
with `--full` compatibility, added bounded semantic `hive watch` JSON Lines and
fresh tokenized `hive act`, and joined task state to a coherent owner-private
daemon scheduler snapshot. Status remains read-only and never performs daemon
reconciliation.

**Agent skills:** Established `skills/hive/` as one canonical operating policy
projected to OpenClaw `/hive`, Claude `/hive`, Codex `$hive`, and Pi
`/skill:hive`. Added provenance/digest validation, safe whole-directory atomic
publication for Claude/Codex/Pi, read-only OpenClaw/ClawHub diagnosis, and
agent-skills-first normal setup with one consent boundary. JSON/non-TTY setup
without `--yes` now refuses before diagnostics or native discovery, preventing
nominally read-only upstream probes from initializing user state.
The canonical progressive setup reference preserves the current OpenClaw
v0.1.3 consent rules: package-manager confirmation remains interactive, core
provisioning uses approved `setup --no-init`, project enrollment stays in the
user's real terminal, and agents never patch installed runtimes or service
overrides directly.

**Release proof:** Added a protected exact-SHA workflow that builds the
candidate gem/source/four-platform skill archive once, requires authenticated
native discovery and bounded status/watch use on all four agents, retains only
secret-scanned structural evidence, and creates a candidate-bound Check Run.
The tag workflow now verifies that Check Run, run attempt, required jobs,
Actions artifact digest, attestation, and candidate provenance, then publishes
the exact proven gem/skill archive without rebuilding them.

**Coverage and compatibility:** Added operational status/action/watch, daemon
snapshot, canonical projection/publisher, setup/doctor/OpenClaw, four-agent
smoke, proof builder/attestor/verifier, and release-contract coverage. Updated
the README, release guide, command/API/operating/testing/module pages, and this
index; the compiled `wiki/log.md` is intentionally untouched in this feature
branch. The legacy full JSON graph and existing daemon/bot/TUI consumers remain
unchanged.

**Read-only diagnosis:** Doctor now derives Claude, Codex, Pi, and OpenClaw
package/provenance evidence entirely from durable filesystem state and records
`inventory_source: filesystem` with an empty command audit. This closes the
case where upstream version/list commands initialized config, identity, backup,
or database state during diagnosis. Setup retains refreshed native discovery
only behind its explicit consent boundary; disposable-home tests and a real CLI
probe prove Doctor leaves the home byte-identical.

**Current-head review hardening:** Revalidated the feature after rebasing and
discarded the earlier review as stale. Dependency-blocked tasks now project as
scheduler waits instead of idle; daemon snapshots and later status joins bind
decisions to marker attrs, mtime, action, dependency, blocked, and admission
policy; task capacity excludes separately budgeted patrol/digest workers; and
markerless generic action tokens use stable task metadata so their own lock
cannot invalidate them. Doctor's OpenClaw adapter is now filesystem-only by
construction, managed-skill Doctor tests are split from legacy checks, all
three real operational executor branches are covered, and the live proof's
audited shim delegates status/watch to the exact candidate instead of emitting
fixture payloads.

**Uncertainty:** The authenticated protected workflow has not yet been
dispatched for this candidate. Until all four native jobs and attestation pass
and the exact-SHA Check Run exists, the implementation is locally validated
but not release-proven. No tag, package release, ClawHub publish, or deployment
was performed.
