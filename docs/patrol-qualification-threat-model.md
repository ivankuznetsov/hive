# Patrol installed/live smoke threat model

Status: reduced U3c infrastructure candidate. Credentialed execution remains
forbidden until this exact infrastructure head is merged, hosted checks are
terminal, and the operator separately authorizes one later candidate invocation.

Design base: `3b8b6fc9b037359b3d0c3a6f7b8a8e3c0c33ef32`

## Decision

The merged reduced U3b harness is a prepared-record installed-CLI smoke. It
does not freshly drive the ordinary and Architecture Patrol schedulers through
the complete fault matrix, and its controls come from the same candidate head.
U3c therefore cannot truthfully produce the report-v2 `installed_live`
qualification lane or `evidence_ready_for_operator` from that input.

The proposed U3c scope is narrower: prove that exact candidate and dependency
bytes can run both first-party modules through the reduced smoke inside a
bounded installed sandbox, and prove provider authentication and transport in
a separate host-owned probe without exposing its credential to candidate code.
A passing result is `installed_live_smoke_verified`. It is useful custody
evidence, not Patrol qualification evidence.

The controller and candidate are separate authorities. U3c infrastructure must
first merge to protected `main`; only that recorded controller SHA may evaluate
a different later candidate SHA. The credentialed probe runs only from an
operator-invoked local command at that exact controller SHA; hosted workflows
never receive the credential and cannot emit the passing status. The candidate
checkout is untrusted input, and the controller is never mounted into its
sandbox. A PR-head or same-SHA bootstrap run may test failure and custody paths,
but it cannot emit the passing status.

Every retained success must carry these claim fences:

- `not_full_u3b`
- `prepared_records_not_fresh_scheduler_matrix`
- `controller_does_not_supply_full_independent_matrix`
- `not_report_installed_live_qualification`
- `provider_probe_not_patrol_decision`
- `not_evidence_ready_for_operator`
- `not_cutover_or_promotion_authority`

The full fresh scheduler/fault matrix and a provider-backed Patrol decision are
deferred until an observed defect or an explicit operator readmission justifies
their architecture cost. Removing a claim fence is a new architecture decision,
not a compatible U3c extension.

## Result contract

The runner first persists one canonical, mode-`0600` `not_started` result, then
atomically replaces those expected bytes with exactly one terminal result:

- `installed_live_smoke_verified`: the exact installed candidate passed the
  reduced prepared-record smoke, the one-call provider transport probe passed,
  both first-party modules were revalidated, the controller and candidate SHAs
  were distinct, and every custody check passed.
- `not_started`: durable preflight receipt; never a successful terminal result.
- `blocked`: manual authority, a compliant sandbox, an installed dependency,
  the selected credential, or provider availability was absent. Blocked is
  retryable evidence and never a green skip.
- `failed`: candidate identity, input, sandbox, process, resource, transport,
  redaction, cleanup, or result validation failed.

The result is a separate `hive-patrol-installed-live-smoke` v1 artifact. It may
record digests of the existing U3a report and reduced U3b proof, but it must not
write the migration report, construct a `PatrolQualification`, or call the
report-admission facade.

Each run receives one new runner-owned mode-`0700` result directory beneath an owned
mode-`0700` local evidence store. The runner refuses a pre-existing run
directory, persists mode-`0600` `not_started` until terminal replacement,
retains the resulting file for at least 30 days, and never deletes evidence
automatically. The store admits at most 128 result files and 64 MiB in
aggregate; saturation returns
`blocked:evidence_store_full` without deleting old evidence. Explicit operator
cleanup after that minimum age may remove only a selected mode-`0600` regular
file whose owner and recorded device/inode still match, followed by its
unchanged empty run directory. Evidence otherwise remains until that cleanup.
Candidate archives, admitted source, container IDs, and controller scratch data
live in a separate runner-owned transient workspace that is identity-checked and
removed before credential access. They never enter the retained result directory.

## Trust boundaries

Trusted for this bounded claim:

- the host-side runner and control checkout at a separately recorded full SHA;
- an operator-invoked local command from the accepted full controller SHA on
  protected `main`;
- the host kernel and the admitted container engine/runtime;
- the configured TLS trust roots and the selected provider endpoint;
- the operator-created disposable input project and prepared observation file.

Untrusted or candidate-controlled:

- candidate source, gem contents, module packages, subprocess output, archive
  members, filenames, symlinks, and runtime behavior;
- prepared records as claims about current authority until the host binds their
  exact project, repository, candidate, configuration, and artifact identities;
- provider response text;
- every pre-existing destination and every path after creation if its recorded
  device/inode identity changes.

Out of scope:

- compromise of the host kernel, container runtime, protected GitHub ref, or
  provider itself;
- a coherent malicious process already running as the host runner's OS user;
- long-lived provider, credential, repository, or environment drift after the
  retained result;
- Homebrew, AUR, `install.sh`, release, cutover, rollback, component promotion,
  and any external Patrol effect.

The same-user limitation must appear in retained evidence. The sandbox blocks
candidate access to host procfs and credentials, but it is not a claim that a
separate already-compromised same-UID host process cannot inspect or alter the
runner.

## Projected ownership and dependency map

U3c is capped at five packaging runtime Ruby files and five responsibility
owners, below the program ceiling of eight files. Tests, one schema, the bounded
existing-controller seam, and documentation add no packaging runtime owner.

| Projected path | Sole responsibility |
| --- | --- |
| `packaging/patrol_evidence/result.rb` | immutable `not_started`/terminal result vocabulary, canonical bytes, claim fences, and bounded redacted projection |
| `packaging/patrol_evidence/candidate.rb` | exact candidate archive, gem, installed binary, module, and dependency inventory admission |
| `packaging/patrol_evidence/sandbox.rb` | one exact container command, owned mounts, process/resource limits, teardown, and cleanup identity |
| `packaging/patrol_evidence/provider_probe.rb` | one fixed provider request, selected credential/transport custody, and secret-free response digest |
| `packaging/patrol_evidence/runner.rb` | closed phase composition and atomic publication of one result |

Additional admitted paths are:

- `schemas/hive-patrol-installed-live-smoke.v1.json`;
- one bounded edit to `test/e2e/lib/patrol_qualification.rb` and its focused
  test to add an explicit read-only `external_smoke` mode. That mode takes a
  distinct candidate SHA, loads catalogue/control bytes from the separately
  trusted checkout, runs candidate build/install/CLI work only through the
  admitted sandbox, stops after receipt and module validation, and proves the
  migration report bytes are unchanged. It never calls `admit_qualification`,
  constructs a qualification, writes U3b evidence, or publishes a report;
- focused `test/unit/packaging/patrol_evidence_*_test.rb` and command contract
  tests;
- the required release and wiki documentation plus one wiki log fragment.

The bounded controller edit is required because current main deliberately
asserts that its executing controller equals the archived candidate controller,
and its normal `run!` path unconditionally admits a qualification report. It may
add only the closed `external_smoke` entry point above. The existing `run!`,
`admit_qualification`, report publication, same-head default, and claim fences
remain unchanged and are not reachable from this mode. U3c must not add or copy
a second scenario controller. This bounded edit is an admitted test-controller
seam, not a sixth packaging runtime owner.

Dependency direction is one way:

```text
manual local command
  -> Runner
       -> Candidate
       -> existing reduced U3b controller in read-only external_smoke mode
            -> Sandbox
       -> ProviderProbe
       -> Result
```

No U3c owner may require or construct a migration store, scheduler, dispatcher,
effect gateway, U5-U7 collaborator, recovery owner, cutover owner, or component
promotion owner. The runner exposes no generic process, archive, container,
provider, or publisher API.

## Threats and required controls

| Threat | Required control | Failure |
| --- | --- | --- |
| Candidate or dependency substitution | Resolve a full candidate commit distinct from the protected-main controller SHA, archive once, safely materialize and hash a read-only source tree, build from a separate writable copy, treat installed gemspecs as opaque bounded bytes, and rehash the archive/gem/installed executable/module/source/dependency inventories before and after execution. Hosted candidates must be reachable from protected `main`. Never select an executable by filename alone. | `failed:candidate_identity` |
| Mutable image or toolchain | Resolve the OCI image by immutable `sha256` digest before the run and prohibit later pulls. Record and reverify the engine identity, image/rootfs digest, Ruby, RubyGems, Bundler, controller script bytes, and the complete installed gem dependency closure before and after execution; the image/rootfs digest binds its native libraries. | `failed:runtime_identity` |
| Archive traversal or special members | Admit only bounded regular files and directories beneath a new runner-owned root. Reject absolute paths, `..`, links, devices, sockets, fifos, duplicate members, and over-limit inventory before extraction. | `failed:candidate_archive` |
| Pre-existing or replaced paths | Refuse every destination that exists before creation. Record device/inode after creation and remove only an unchanged owned identity. A replacement is preserved and cleanup fails closed. | `failed:path_custody` |
| Candidate host access | Run the installed candidate in a dedicated, networkless, read-only-root container with no host procfs, no host home, no Docker socket, no credential, no ambient Git/SSH/provider variables, dropped capabilities, `no-new-privileges`, and only runner-created byte- and inode-limited tmpfs or quota-backed state/output mounts. Constrain every writable layer. Copy only bounded admitted outputs after verified teardown. No unsandboxed fallback. | `blocked:sandbox_unavailable` or `failed:sandbox_contract` |
| Process or resource escape | Give each invocation a unique label/name and owned CID, use one hashed engine executable under a closed environment, private PID namespace, whole-container TERM/KILL teardown by owned ID only, bounded pids/memory/CPU/time/output/files, and verify terminal container/process-group state on success, error, timeout, interrupt, and runner exception. | `failed:process_custody` |
| Credential leakage | Select exactly one provider credential in the host probe. Candidate and sandbox environments contain none. Never place the credential in argv, paths, prompts, logs, exceptions, result fields, or uploaded artifacts. Scan retained bytes against exact-secret and generic secret patterns. | `failed:credential_custody` |
| Transport override, exfiltration, or false success | Before reading the credential, bind one exact HTTPS origin/path, model, proxy policy, and CA policy and reject ambient endpoint, proxy, or CA overrides. Permit one fixed bounded request with redirects disabled. Success requires the expected JSON content type and schema, no error object, the selected model identity, non-empty output, and positive usage. Retain only admitted status/usage and the response digest, never response text. | `failed:provider_transport` |
| Provider unavailability, expiry, or quota | Preserve the candidate custody evidence and return typed `blocked` or `failed`; never reuse an old live success for a new head and never convert provider failure into a skip. | `blocked:provider_unavailable` or typed provider failure |
| External effect or target escape | Supply no GitHub/effect credential, deny candidate network, and run no mutating Patrol path. Prepared effect receipts are historical inputs only. Any future live effect requires a separately threat-modelled, repository-scoped readmission. | `failed:effect_forbidden` |
| Self-attested live binding | Execute commit-matched protected-main controller/support/catalog bytes outside the candidate mount. Resolve and digest the disposable project registration, path identity, repository identity/HEAD, state/configuration tree, observation file identity, installed candidate, and module generations from host-owned inputs before and after each phase. Candidate output cannot supply expected bindings. | `failed:authority_binding` |
| Unbounded input or output | Stream inventories before sort/allocation; cap every admitted file, member count, child stream, provider body, result, process count, and campaign deadline. Do not hold two full admitted payloads simultaneously. | typed bound failure |
| Partial or conflicting publication | Persist `not_started` before preflight. Hold one owner-checked, no-follow lock on a stable recorded inode from the expected-byte read through staged validation, file fsync, atomic replacement, and parent-directory fsync. Recheck path identity while locked. An existing different terminal result or competing writer is a conflict. | `failed:publication_conflict` |
| Artifact accumulation or unsafe deletion | Use one owned evidence root and the retention/count/aggregate-byte limits in the result contract. Refuse new evidence when full. Never delete automatically; explicit cleanup verifies the selected regular file's owner and device/inode through an already-open no-follow descriptor. | `blocked:evidence_store_full` or `failed:evidence_custody` |
| Execution authority confusion | Scrub ambient Git state and require the remote protected-main ref; refuse unless the local controller checkout is clean, equals the explicitly authorized full controller SHA, and every loaded control file equals that commit. The candidate SHA must be distinct and reachable. Require one canonical authorization binding controller/candidate/image/invocation/provider/model/project/observations plus UTC issue/expiry and nonce; atomically reject a retained digest replay before credential access. Hosted workflows remain credential-free and cannot emit success. | command fails before credential use |

Initial implementation bounds are deliberately conservative: at most 4,096
candidate/dependency members and 256 MiB total admitted bytes; 8 MiB prepared
observations; 1 MiB stdout plus 1 MiB stderr per child; 512 KiB terminal
result; 512 MiB and 16,384 inodes across candidate-writable filesystems; 64
processes, 2 GiB memory, two CPUs, 30 seconds per ordinary child, 180 seconds
for the one provider request, and 10 minutes for the campaign. The local
evidence-store limits are 128 results and 64 MiB, and every result remains for
at least 30 days. Changing a bound or retention value requires a focused test
and an admission-document amendment.

## Inherited U3c observations

No inherited observation is rejected or silently redefined.

| Observation | Reduced U3c disposition |
| --- | --- |
| `U3-I03` | Required: host-supplied expected bindings and the no-report-write fence prevent persisted evidence from self-attesting current authority. |
| `U3-I06` | Narrowly addressed only as a packaging-owned live-smoke producer; the missing full qualification producer remains open/deferred. |
| `U3-I09` | Closed by the threat model, wiki gap update, and log fragment once this documentation lands. |
| `U3-I16` | Required: resolve live project registration and repository identity at each phase boundary; do not cache candidate claims. |
| `U3-I17` | Required: bind and reverify installed candidate/module generation and configuration identities. |
| `U3-ARCH-001` | Required: candidate sidecars are never signal authority; container identity and host-owned process custody govern teardown. |
| `U3-ARCH-002` | Required: the candidate always runs in the admitted networkless sandbox; no live bypass exists. |
| `U3-ARCH-006` | Remains open/deferred: the live transport probe plus prepared-record smoke is not full both-lane coverage or authorization-retry proof. |
| Architecture Review 03 item 1 | Required: all candidate-controlled inventories stop at the first over-limit member before whole-set allocation or sort. |
| Architecture Review 03 item 3 | The donor's multi-file lane is not applicable; reduced U3c still proves expected-byte atomic replacement of its one result. |
| Architecture Review 03 item 5 | Required: record bounded typed process evidence before propagating controller/sandbox exceptions. |
| Subordinate process-group gap | Required test: prove the foreground group/container and a detached/double-fork descendant are gone before terminal success or failure. |

The qualification portion of `U3-I06` and all of `U3-ARCH-006` remain visible
gaps. Consequently this reduced U3c cannot complete the original U3c
qualification objective even when its smoke passes.

## Acceptance gates

Before production mutation:

1. An independent reliability/security reviewer must accept this exact threat
   model, ownership map, claim vocabulary, and the two explicitly deferred
   observations.
2. The operator must explicitly sign off on this exact reduced claim.

Before a credentialed run:

1. Credential-free custody and failure-path tests pass on one clean exact head.
2. Required hosted CI and the final independent reliability/security review are
   terminal on that unchanged head.
3. The operator freshly authorizes one provider run for that exact head. A head
   change or second invocation invalidates the authorization.

The infrastructure PR cannot authenticate or qualify itself. Its merge makes a
trusted controller available; the first passing live smoke necessarily targets
a later, distinct candidate commit under a separate exact-head authorization.

The hostile archive/path/process campaign is opt-in and remains outside normal
CI. Focused deterministic contract tests stay in normal CI. No hosted workflow
receives the provider credential. No U3c result authorizes merge, release,
publication, deployment, report-v2 cutover, rollback, or component promotion.
