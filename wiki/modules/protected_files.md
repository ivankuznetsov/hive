---
title: Hive::ArtifactFirewall
type: module
source: lib/hive/artifact_firewall.rb, lib/hive/protected_files.rb
created: 2026-04-26
updated: 2026-07-26
tags: [security, artifacts, custody, integrity, orchestrator]
---

**TLDR**: `Hive::ArtifactFirewall` is the supported application-level custody
boundary around Hive agent spawns. A Hive adapter declares protected anchors,
permitted writable roots, required regular outputs, and a redactor in an
immutable manifest. The facade captures no-follow identities, validates
post-run custody, returns a bounded typed report, and safely restores only
reconstructable anchors. It is same-user detection and recovery, not an OS
sandbox or a filesystem transaction.

## Supported API

```ruby
require "hive/artifact_firewall"

manifest = Hive::ArtifactFirewall::Manifest.new(
  root: task.folder,
  protected_anchors: %w[
    plan.md worktree.yml task.md task-journal.jsonl task-projection.json
  ],
  permitted_writable_roots: [task.folder, worktree_path],
  required_outputs: {"fix-report.md" => File.join(task.folder, "fix-report.md")},
  redactor: Hive::SecretPatterns.method(:redact)
)

snapshot = Hive::ArtifactFirewall.capture(manifest)
# ... Hive performs one agent spawn ...
report = Hive::ArtifactFirewall.validate_and_restore(manifest, snapshot)

report.status          # :clean, :rejected, :tampered,
                       # :tampered_restored, or :restore_failed
report.valid?          # true only for :clean
report.tampered_labels # protected labels that changed
report.restored?       # nil when unattempted, true only when verified
report.diagnostic      # secret-redacted and capped at 512 bytes
```

The public immutable values are:

- `Manifest` — root, labeled protected anchors, permitted writable roots,
  labeled required outputs, and an injectable `#call` redactor.
- `Snapshot` — schema version, spawn-binding id, manifest, immutable in-memory
  captures, pre-run anchor identities derived from those exact captures, and
  protected-parent identities.
- `Violation` — typed kind, bounded label/path, and bounded diagnostic.
- `Restoration` — whether repair was attempted, whether it was verified, and
  a bounded diagnostic.
- `Report` — schema version, status, violations, restoration, and summary
  diagnostic.

The public errors are `Error`, `InvalidManifest`, `CaptureError`, and
`InvalidSnapshot`. Manifest/snapshot binding prevents validating one manifest
and then restoring through a different policy observation.

`validate_required_outputs(manifest)` is the read-only polling seam used by
headless `Hive::Agent` and `Hive::ClaudeLauncher`. It replaces the former
`File.exist? && File.size.positive?` check, so symlinks and directories cannot
masquerade as successful reviewer artifacts. Final stage acceptance still uses
the spawn-bound snapshot when protected anchors are also in scope.

## Typed violations

Protected-anchor violations distinguish:

- `protected_added`
- `protected_changed`
- `protected_deleted`
- `protected_mode_changed`
- `protected_parent_changed`
- `protected_symlink_substitution`
- `protected_directory_substitution`
- `protected_type_substitution`
- `protected_unreadable`

Required-output violations distinguish:

- `required_output_missing`
- `required_output_empty`
- `required_output_symlink`
- `required_output_non_regular`
- `required_output_outside_root`
- `required_output_unreadable`

Regular-file identity includes SHA-256 content and permission mode. Other
identities include file type and only the minimum type-specific evidence
needed for classification. Capture binds the trusted regular-file identity to
the exact descriptor supplying the reconstructable bytes rather than taking a
second baseline read. Parent identity includes resolved path, device, inode,
and mode. A parent change is a custody violation and blocks restoration so an
atomic write cannot be redirected through a substituted directory. Required
output containment checks both lexical placement and the real path of the
parent, so a symlinked parent cannot route an accepted output outside a
declared writable root.

`permitted_writable_roots` records acceptance policy. It does not monitor every
write below those roots and cannot prevent an agent from writing elsewhere.
Protected anchors are the exact paths for which the facade can prove
before/after custody.

## Restoration

`lib/hive/protected_files.rb` is the internal no-follow capture/restore engine
behind the facade. `Hive::ProtectedFiles::ORCHESTRATOR_OWNED` remains the
compatibility source for:

```text
plan.md
worktree.yml
handoff.yml
task.md
task-journal.jsonl
task-projection.json
```

The facade publishes the same set as
`Hive::ArtifactFirewall::ORCHESTRATOR_OWNED`; production Hive consumers use the
facade constant and API.

Capture retains original regular-file bytes and modes in controller memory.
Restore writes regular files atomically, restores their modes, removes a forged
path that was originally absent, and verifies the final structured identity.
It first verifies that the anchor's parent still has its captured identity and
fails closed if the parent was substituted. It never recursively deletes an
agent-created directory. An originally non-regular path is unreconstructable;
if it changes, the report becomes `restore_failed` rather than claiming
rollback. A restored protected anchor still makes the spawn fail stage policy:
restoration repairs custody but does not erase the tampering event.

## Threat contract

This boundary assumes Hive and the spawned agent run as the same OS user.
Therefore it can detect selected before/after changes, reject required-output
shape, and reconstruct selected captured files. It cannot:

- stop a same-user process from writing while the agent is running;
- provide mount, process, network, syscall, or credential isolation;
- detect writes to paths absent from the manifest;
- make a multi-file restore atomic;
- defeat process-memory inspection or monkeypatching by hostile same-process
  Ruby; or
- replace the Safe Agent Git Gate's separate Git configuration and
  exact-publication guarantees.

Use Hivebox or OS-level isolation for stronger containment. The Agent ABI,
Artifact Firewall, and Safe Agent Git Gate remain three separate guarantees.

## Hive adapters

Hive keeps stage semantics above the facade:

- `Stages::Execute` supplies its implementation-owned writable worktree and
  task-control anchors; tampering retains `implementer_tampered`.
- `Stages::OpenPr` and `Stages::Finalize` protect controller task state around
  body-authoring spawns and retain their current error markers.
- `Stages::Review`, `Review::Triage`, and `Review::CiFix` supply pass-specific
  escalation, suppression, guardrail, error, and success anchors. Triage also
  requires a non-empty regular escalations artifact.
- `Stages::AgentWorktree` combines task anchors and named local/global Git
  control anchors in one capture, requires a regular in-root
  `fix-report.md`, and leaves repository/report semantics to
  `AgentReport` and `DraftPrHandoff`.
- `Hive::Agent` and `Hive::ClaudeLauncher` use required-output admission for
  `:output_file_exists` status polling.

The component does not decide which paths a stage owns, what a report means,
which marker to write, whether an agent result succeeded, or whether a retry is
allowed. Adapters validate in `ensure`, so custody recovery still runs when a
provider raises instead of returning its normal error result; the adapter
retains ownership of exception and marker semantics.

## Tests

- `test/unit/artifact_firewall_test.rb` pins typed identity changes, output
  admission, parent-symlink escape rejection, descriptor-bound baseline
  identity, parent-substitution restoration refusal, immutable captures,
  bounded redaction, snapshot binding, verified restoration, and non-recursive
  failure.
- `test/unit/protected_files_test.rb` retains compatibility coverage for the
  internal digest/capture engine.
- `test/unit/agent_profile_modes_test.rb` and
  `test/unit/claude_launcher_test.rb` reject symlinked expected outputs.
- execute, open-PR, managed-worktree, and review tests pin current Hive marker
  and result adapters.
- `test/unit/component_boundaries_test.rb` proves clean loading, allowed
  dependency direction, and that production callers do not bypass the facade
  for `Hive::ProtectedFiles`.

## Backlinks

- [[modules/agent]] · [[stages/execute]] · [[stages/review]]
- [[component-boundaries]] · [[decisions]] (ADR-013)
