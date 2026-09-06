---
title: Hive::WorkflowPackage
type: module
source: lib/hive/workflow_package/
created: 2026-08-13
updated: 2026-08-16
tags: [module, workflow-package, honeycomb, registry, permissions, disclosure, managed-store]
---

<!-- documentation-owner: managed-honeycomb-policy -->

**TLDR**: Reviewed Honeycomb packages cross a stricter trust boundary than owner-authored workflow descriptors. Hive verifies immutable catalog and package identity, stores digest-addressed generations and operator configuration snapshots, binds tasks to exact provenance, distinguishes coarse disclosure from exact actor enforcement, installs after informing the operator of declared access, and fails closed when the selected runtime cannot enforce a declared scope. The legacy `hive workflow install|list|update|remove` commands are a compatibility projection over the generalized managed-module lifecycle.

## Managed Honeycomb boundary

Package installation and publication run full security scanning. Reads of an
already installed generation (workflow loading, manifest inspection, integrity
verification, and configuration reconstruction) do not launch Betterleaks or
repeat package security lint. They still check the pinned manifest digest, file
inventory and hashes, filesystem shape, descriptor, and runtime policy. Changed
installed bytes fail integrity verification rather than being silently rescanned
and accepted. This keeps package admission work out of routine status scans.

An unchanged `honeycomb-manifest/v1` package normalizes to a one-workflow,
hook-free `Hive::ModulePackage` with the same immutable identity, mappings,
inputs, and disclosure. That compatibility relationship does not make this
page the owner of native-module hooks, grants, or activation; those belong to
the dedicated [`docs/modules.md`](../../docs/modules.md) module guide. No
package republish is required. Install and update automatically migrate retained
tasks to the selected generation before runtime dispatch resumes.

`Hive::WorkflowPackage` defines a second, stricter trust boundary without
weakening owner-authored descriptor compatibility:

- `Manifest`, `RegistryManifest`, `CanonicalJSON`, `CanonicalYAML`, `Validator`, and `SecurityScanner` enforce
  canonical metadata, full path/hash coverage, safe package filesystem shapes,
  package-name descriptor binding, redacted diagnostics, and objective
  warning/error rules. Scanner documentation negation is fail-closed: only a
  narrowly recognized prohibition or absence statement that directly governs
  the matched behavior suppresses a finding. Exhortations and double negatives
  such as `do not forget`, `never fail`, `not only`, or `without exception`,
  plus affirmative behavior after a comma or semicolon, remain reportable.
- `RegistryClient` consumes canonical `honeycomb-catalog/v2` flat entries,
  applies listed/latest plus exact soft-hidden/yanked and revoked-blocked
  lifecycle semantics, materializes `packages/NAME/VERSION/` only from the
  exact catalog commit, and rejects tree, release fingerprint, source
  provenance, description, or permission metadata that does not bind to the
  canonical `manifest.yml`. Failed git operations include bounded stderr in the
  typed registry error rather than discarding the underlying cause. Review head
  SHA remains audit data; upstream
  `source_sha` remains source provenance, and neither is the install tree.
- `ManagedStore` places immutable generations plus digest-addressed
  `configurations/<sha256>.json` execution snapshots and selects both through
  an atomic lock-schema-v2 pointer. Each snapshot maps stable actor slots to
  operator-selected agent/model/effort identity, mapping role/contract, profile
  fingerprint, and per-actor policy fingerprint. Snapshot construction rejects
  non-null pins that the selected profile cannot express as native arguments;
  unsupported project defaults remain nil. Strict registry metadata may carry
  sorted `mapping_recommendations` for known executable slots, containing no
  agent/model identity and only an optional portable `low`/`medium`/`high`
  effort. Resolution is field-stable: an explicit install override wins, then a
  compatible installed mapping, then the package recommendation, then the
  project default. Unsupported recommended effort is recorded and disclosed as
  unpinned rather than failing or falling through to another default. Automatic agent suggestions also
  fall back to Claude when the project-default profile cannot enforce a
  non-`yolo` actor scope; explicit mappings are preserved for the existing
  fail-closed runtime admission check. Managed council reviewers and
  revisers launch exclusively from their child-slot snapshot identity, so a
  nil child model/effort cannot leak the parent stage's provider-specific
  defaults. Owner-authored unmanaged councils retain their historical parent
  fallback. `TransactionJournal` plus the workflow mutation lock reconcile an
  interrupted activation/removal before Loader or lifecycle access. Opaque
  lock bytes use a base64 envelope, and malformed envelopes fail through the
  same typed `ConfigError` boundary as invalid journal JSON. Selection reads
  participate in that lock. Invalid selected configurations are skipped
  independently with one named warning, so one missing, malformed, or
  digest-tampered snapshot cannot hide itself or suppress healthy siblings.
  Immutable task reads apply their saved mapping without resolving the process's
  current agent profile, so status and retained history survive later profile
  renames, capability changes, and compatible upgrades. Runtime-context
  preparation verifies current pin support and the fingerprint for the exact
  executable slot about to launch; drift therefore remains fail-closed at the
  side-effect boundary without invalidating unrelated or completed task records.
  Configuration-only activation against an
  unchanged package generation compares the selected source, manifest, and
  configuration digests before swapping the pointer. Cleanup is serialized
  with managed task creation and stage moves and aborts on unreadable or
  incomplete managed pin provenance. A legacy pin may omit only its
  configuration digest; workflow, source commit, and manifest digest remain a
  required tuple. `workflow list --json` schema v2 reads the selected
  digest-addressed snapshot back through this store to expose per-slot identity
  and redacted optional-input binding/availability. Diagnostic retained rows
  expose only a pinned configuration digest, when available, so historical
  identity is not confused with the active selection.
  Activation distinguishes "no baseline check" from an explicit "still
  unselected" baseline; selected baselines compare source commit, manifest
  digest, and configuration digest under the mutation lock. The mutation lock
  classifies only acquisition/open failures as contention; I/O errors raised by
  the protected mutation retain their original type and message.
- `Hive::Workflow#executable_slots` is the single actor-topology boundary for
  configuration snapshots, package validation, and runtime admission. The
  configuration object also owns the redacted mapping/input disclosure used by
  lifecycle commands, so JSON surfaces cannot drift from snapshot semantics.
- `Loader` registers selected managed workflows beside built-ins and authored
  descriptors while rejecting id collisions and reloading when its managed
  fingerprint changes. Runtime accepts only the selected source commit,
  manifest digest, and configuration digest. A stale task fails closed with an
  exact `hive migrate` recovery command. `hive migrate` is the only boundary
  that loads the task's old descriptor: it maps the old directory through the
  stable semantic stage name, preflights every destination and task lock,
  renames the stage artifact when its filename changed, and repins the task to
  the selected generation. Install and update coordinate pointer activation
  and retained-task changes in one state commit; failure rolls back both.
  They also remove stale nonterminal delivery requests, while consume-time task
  identity checks fence requests that raced the migration. Unreferenced
  generations and configurations are removed only after the cutover commits,
  and `workflow remove` refuses while retained tasks name the workflow.
  For a legacy lock-schema-v1 selection, task creation derives the compatibility
  snapshot with the effective project agent profiles and writes that
  digest-addressed snapshot before `meta.yml` can pin it. The snapshot therefore
  remains resolvable after an update replaces the selected pointer with schema
  v2; cleanup retains it while any task references its digest.
- `SemanticDiff` reports prompt/descriptor changes by hash (never prompt text),
  dependency and policy set changes, file inventory changes, and semantic
  escalation reasons.
- `Publisher`, `AuthoringMetadata`, and `SourceSnapshot` enforce disjoint
  descriptor/metadata/README ownership and snapshot referenced instructions
  plus declared assets once without following links. `RegistryManifestBuilder`
  emits the immutable Honeycomb version directory and canonical digests;
  `AuthoringLint` runs the pinned pure-analysis policy before publication. Its
  payment-card rule ignores digit runs wholly contained in exact SHA-256 tokens,
  while continuing to reject ordinary Luhn-valid card numbers.
- `PublishStore` retains owner-private immutable bundles and monotonic receipts;
  `RegistrySubmission` journals mutation intent and verifies direct/fork branch,
  commit, package, and PR identity; `PublishResolver` combines exact current
  catalogue evidence with PR state and labels offline prior evidence cached.

Managed locks/generations/configurations are Hive-owned. Lifecycle commands cannot overwrite a
built-in or `<id>.yml` authored descriptor, and task metadata rewrites preserve
all three managed provenance fields.

Honeycomb v2 permission summaries are disclosure data, not executable policy.
Managed execution uses each stage/reviewer/reviser descriptor's exact
`permissions:` block. Install reports explicit `yolo`, scoped shell, and
unqualified scoped file-write actors without adding a second approval gate; a v2
manifest hiding that actor surface behind a narrower disclosure is rejected.
Bounded actors admit only on profiles that enforce the bound. Claude uses its
native tool rules. Codex and Grok may also execute read-only actors through the
portable managed-output adapter: Codex gets a generated named filesystem
profile plus ephemeral user-config/rules isolation, while Pi and Grok get
bubblewrap mount namespaces. All receive a strict JSON output contract, and Hive alone
writes the path-qualified `Edit(...)` targets. Hive validates the complete
response before writing, rolls back already-published companion files on a
later publication failure, and publishes the requested stage/state artifact
last as the completion commit point. Grok returns the schema result on its
terminal `end.structuredOutput` field after streaming human-readable prose;
its profile explicitly declares the `:grok_end` output protocol, so Hive
normalizes that terminal object as the final structured message without
teaching the shape to custom or non-Grok profiles. Parsed and conservatively
recognized unparseable terminal payloads stay out of durable logs, plain
fallback, and quota diagnostics. For managed output, a malformed terminal
value invalidates the preceding stream before host validation, so a
schema-looking prose rendering cannot be published after Grok's terminal
validation failed. Codex executable discovery accepts valid
runtime provenance even when unrelated aggregate doctor checks fail, while a
dedicated bounded probe and executable-path validation remain fail-closed. The
probe uses an ephemeral empty Codex state root, so executable discovery does
not scan the operator's rollout archive or inherit its user configuration. It
also sets `MISE_QUIET=1` so a mise-backed `codex` shim cannot prepend a version
selection notice to the machine-readable doctor JSON.
Exact, non-wildcard `Read(path)` rules are enforced for Codex by granting its
named filesystem profile only the resolved declared targets, without mounting
the task or package root. Targets must remain under a descriptor-declared root,
must exist at launch, and must not resolve outside that root through a symlink;
other portable runners still reject path-qualified reads they cannot enforce.
Pi's namespace mounts only declared read roots plus its immutable runtime and
mode-0600 auth file, exposes read-only Pi tools, disables extensions, skills,
prompt templates, context files, and agent web tools, and keeps the writable
runtime home disposable. Host-owned-output actors also receive a system-level
single-JSON response contract, so a provider cannot mistake an instruction to
produce an artifact for permission to write it directly. The namespace shares the network only because the Pi
process must reach its configured model provider; no shell or web tool is
available to the model.
When a launch is built from typed model/effort selection, its private spawn log
and `agent_start` event record only the normalized model, requested/effective
effort, pin state, and effort-support state. They never serialize the provider
argv or prompt, so short-lived managed reviewers retain an auditable execution
identity without expanding the secret-bearing log surface.
Bare/unbounded file edits and unsupported tools still fail admission. Strict `x-hive`
metadata declares manifest-hashed executable tools, manifest-hashed prompt
assets exposed as absolute paths in the managed prompt preamble, and optional
environment names with authorized stable slots. Package-declared process
control names are rejected before a value can enter a child environment. Git modes survive
catalog materialization and generation placement. Generation directories and
ordinary files are hardened to 0555 and 0444 before same-parent atomic
publication, trusted executable payloads remain 0555, and reuse repairs mode
tampering after content validation. Snapshots store environment variable names
only and inject a current value only into its executing slot. Each actor spawn
loads that immutable runtime context once for both prompt and permission setup;
preset actor compilation is in-memory and does not create empty policy state.
`gh` and `qmd` remain baseline Hive dependencies. New publication is v2-only:
it does not detect, convert, resubmit, or bulk-migrate legacy registry layouts,
and it exposes no separate public status or Hivebox mutation route.

## Publishing and recovery internals

The CLI id must equal the descriptor `id`, and strict SemVer `--version` is
required. Adjacent authored `honeycomb.yml` owns description, author name/URL,
SPDX license, minimum Hive version, immutable source URL and 40/64-hex revision,
and a sorted unique asset list. `README.md` must contain authored
non-placeholder `Behavior`, `Prerequisites`, `Inputs`, `Outputs`, `Permissions
and Risks`, and `Recovery` sections. Only referenced local instructions and
declared regular assets are snapshotted; named `skill:` dependencies become
`x-hive.external_skills` and are never copied.

Optional top-level descriptor `x-hive` authoring metadata owns `tools`,
`prompt_assets`, and `optional_inputs`. Tool and prompt-asset paths must also
appear in `honeycomb.yml`'s closed asset list; only explicitly declared tools
retain executable mode. Optional inputs carry sorted portable names and sorted
authorized executable-slot IDs. Hive removes this authoring block from the
packaged `workflow.yml` and projects its validated values into generated
manifest `x-hive` metadata. Authoring-only `honeycomb.yml` and generated
`manifest.yml`/`workflow.yml` paths cannot enter the package as assets.

The canonical builder emits only `packages/NAME/VERSION/` with generated
`manifest.yml`, packaged `workflow.yml`, authored `README.md`, referenced
instructions, and declared assets. The manifest owns normalized permissions,
the complete registry-relative hash map, and `release_sha256`; the final
manifest byte hash is `package_digest`. The current consumer validator and
pinned Honeycomb lint contract run before remote access. Both import scanning
and authoring lint delegate credential detection to bundled Betterleaks;
authoring lint emits the stable `secret.detected` rule without maintaining a
second credential regex catalog or entropy classifier. Permission, network,
and personal-data lint remain separate checks. The installed gem
ships the pinned Markdown corpus and upstream SafeYAML parity cases as runtime
contract data, so packaged Hive does not depend on the source checkout's test
tree. Bounded safe-file reads treat a zero-byte regular file as empty bytes;
an empty YAML behavior asset is therefore reported as malformed YAML instead
of escaping into the generic scanner-error boundary. The lint receipt
identity binds the upstream policy, fixture corpus, expected output, and local
contract checksums. Dry-run returns
`state: validated`, both digests, and `freshness: not_checked` without durable
publication state.

The real invocation must pass the confirmed full digest through
`--expected-release-digest`. Destination repository/base come only from trusted
`honeycomb.repository`/`honeycomb.base_branch` configuration. Owner-private
receipts and digest bundles under `Hive::Paths.state_home/workflow-publish/v1`
journal fork, push, and PR intent before effects. Retry identity is registry,
name, version, and full release digest; a different digest is an immutable
conflict. The same digest verifies exact fork parent/owner, head
repository/branch, commit parent/OID, package bytes, and non-draft PR head/base
before reuse. An open PR still requires its live branch to resolve to the
immutable recorded head. A merged or closed PR remains observable when GitHub
has deleted that branch, because its immutable PR head and commit/package
evidence remain independently verified; if a terminal PR's branch still
exists, it must not have moved. A branch name is only a locator, so a matching
external PR can be adopted after those authority checks. PR-body metadata is
likewise only a locator: discovery paginates the complete PR set and derives
same-version identity from exact remote package bytes and Git modes. Receipt
steps and observations are monotonic under one per-version lock spanning
discovery through PR verification. Expected-absent pushes use an atomic
absent-ref lease; they never replace an existing branch. No merge,
approval, close, branch/fork deletion, or catalogue edit path exists.

Retained publication Git objects live only under an owner-private, non-symlink
root. Reused and newly cloned checkouts must be real current-user directories
with a real current-user `.git` directory, and checkout mode is narrowed to
`0700` before Git reads. Once a PR has been verified, its disposable retained
checkout is removed best-effort; cleanup failure becomes a warning without
changing the lifecycle result. Exact `listed` observation marks the digest
bundle GC-eligible while retaining the compact receipt indefinitely.

Schema v2 reports `pending_review`, `merged_pending_listing`, `listed`, or
`closed_unmerged`, separately from `freshness: current|cached`. Only a current
exact catalogue name/version/release-digest entry yields `listed`; offline
reconciliation may return a prior state as cached with its original
`observed_at`. A newer blocking lint policy is reported during retained
read-only reconciliation and stops only a still-required remote mutation.
Publication ends at registry review. Hivebox has no publish or
status route, and no legacy conversion/migration command is provided.

## Documentation ownership

This page is authoritative for managed Honeycomb package trust, immutable storage, mapping and input resolution, permission disclosure versus runtime enforcement, and publish/recovery identity. Command syntax and operator-visible output belong to [[commands/workflow]]; owner-authored descriptor semantics belong to [[modules/workflows]]; user-facing permission presets belong to `docs/permissions.md`.

## Backlinks

- [[commands/workflow]] — lifecycle verbs, flags, consent UX, status values, and JSON fields
- [[modules/workflows]] — descriptor, registry, verb, and runner semantics
- [[modules/agent_profile]] — provider capability and model/effort pin enforcement
- [[modules/task]] — managed task provenance pins
