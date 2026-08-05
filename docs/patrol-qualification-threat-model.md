# Patrol installed/live smoke threat model

Status: proposed U3c admission; production mutation is forbidden until an
independent reliability/security review accepts this document and the operator
explicitly approves this exact scope.

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
a different later candidate SHA. The controller is never mounted into the
candidate sandbox. A PR-head or same-SHA bootstrap run may test failure and
custody paths, but it cannot emit the passing status.

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

## Trust boundaries

Trusted for this bounded claim:

- the host-side runner and control checkout at a separately recorded full SHA;
- a manually authorized workflow revision reachable from protected `main`;
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
owners, below the program ceiling of eight files. Tests, one schema, the thin
workflow adapter, and documentation add no runtime owner.

| Projected path | Sole responsibility |
| --- | --- |
| `packaging/patrol_evidence/result.rb` | immutable `not_started`/terminal result vocabulary, canonical bytes, claim fences, and bounded redacted projection |
| `packaging/patrol_evidence/candidate.rb` | exact candidate archive, gem, installed binary, module, and dependency inventory admission |
| `packaging/patrol_evidence/sandbox.rb` | one exact container command, owned mounts, process/resource limits, teardown, and cleanup identity |
| `packaging/patrol_evidence/provider_probe.rb` | one fixed provider request, selected credential/transport custody, and secret-free response digest |
| `packaging/patrol_evidence/runner.rb` | closed phase composition and atomic publication of one result |

Additional admitted paths are:

- `schemas/hive-patrol-installed-live-smoke.v1.json`;
- `.github/workflows/patrol-qualification.yml`, a manual thin adapter only;
- one bounded edit to `test/e2e/lib/patrol_qualification.rb` and its focused
  test so the existing controller can take an explicit candidate SHA while
  loading its catalogue/control bytes from the separately trusted checkout;
- focused `test/unit/packaging/patrol_evidence_*_test.rb` and workflow contract
  tests;
- the required release and wiki documentation plus one wiki log fragment.

The bounded controller edit is required because current main deliberately
asserts that its executing controller equals the archived candidate controller.
It may add only the external-candidate seam; the same-head default and its claim
fences remain unchanged. U3c must not add or copy a second scenario controller.

Dependency direction is one way:

```text
manual workflow / local command
  -> Runner
       -> Candidate
       -> Sandbox -> existing reduced U3b controller in external-candidate mode
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
| Candidate or dependency substitution | Resolve a full candidate commit distinct from the protected-main controller SHA, archive once, hash the archive/gem/installed executable/module manifests/dependency inventory, and verify those exact identities before and after execution. Hosted candidates must be reachable from protected `main`. Never select an executable by filename alone. | `failed:candidate_identity` |
| Archive traversal or special members | Admit only bounded regular files and directories beneath a new runner-owned root. Reject absolute paths, `..`, links, devices, sockets, fifos, duplicate members, and over-limit inventory before extraction. | `failed:candidate_archive` |
| Pre-existing or replaced paths | Refuse every destination that exists before creation. Record device/inode after creation and remove only an unchanged owned identity. A replacement is preserved and cleanup fails closed. | `failed:path_custody` |
| Candidate host access | Run the installed candidate in a dedicated, networkless, read-only-root container with no host procfs, no host home, no Docker socket, no credential, no ambient Git/SSH/provider variables, dropped capabilities, `no-new-privileges`, and only runner-created writable state/output mounts. No unsandboxed fallback. | `blocked:sandbox_unavailable` or `failed:sandbox_contract` |
| Process or resource escape | Give the container an exact label/ID, private PID namespace, whole-container TERM/KILL teardown, bounded pids/memory/CPU/time/output/files, and verify terminal container/process-group state on success, error, timeout, interrupt, and runner exception. | `failed:process_custody` |
| Credential leakage | Select exactly one provider credential in the host probe. Candidate and sandbox environments contain none. Never place the credential in argv, paths, prompts, logs, exceptions, result fields, or uploaded artifacts. Scan retained bytes against exact-secret and generic secret patterns. | `failed:credential_custody` |
| Transport override or exfiltration | Bind one HTTPS endpoint, model, proxy policy, and CA policy before reading the credential. Permit one fixed bounded request and no redirects to an unapproved origin. Retain status/usage and response digest, not response text. | `failed:provider_transport` |
| Provider unavailability, expiry, or quota | Preserve the candidate custody evidence and return typed `blocked` or `failed`; never reuse an old live success for a new head and never convert provider failure into a skip. | `blocked:provider_unavailable` or typed provider failure |
| External effect or target escape | Supply no GitHub/effect credential, deny candidate network, and run no mutating Patrol path. Prepared effect receipts are historical inputs only. Any future live effect requires a separately threat-modelled, repository-scoped readmission. | `failed:effect_forbidden` |
| Self-attested live binding | Execute protected-main controller bytes outside the candidate mount. Resolve the disposable project registration, repository identity/HEAD, installed candidate, module generations/configuration, observation digest, and result path from host-owned inputs before and after execution. Candidate output cannot supply expected bindings. | `failed:authority_binding` |
| Unbounded input or output | Stream inventories before sort/allocation; cap every admitted file, member count, child stream, provider body, result, process count, and campaign deadline. Do not hold two full admitted payloads simultaneously. | typed bound failure |
| Partial or conflicting publication | Persist `not_started` before preflight. Validate a complete terminal replacement in a private staged file, fsync it, and replace only the exact expected prior bytes. An existing different terminal result is a conflict. | `failed:publication_conflict` |
| Workflow authority confusion | `workflow_dispatch` only; validate dispatch actor and triggering actor in every secret-bearing job; reject reruns; pin actions by full SHA; pass untrusted values through environment variables, not interpolated shell. | workflow fails before credential use |

Initial implementation bounds are deliberately conservative: at most 4,096
candidate/dependency members and 256 MiB total admitted bytes; 8 MiB prepared
observations; 1 MiB stdout plus 1 MiB stderr per child; 512 KiB terminal
result; 64 processes, 2 GiB memory, two CPUs, 30 seconds per ordinary child,
180 seconds for the one provider request, and 10 minutes for the campaign.
Changing a bound requires a focused test and an admission-document amendment.

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
2. Required hosted CI and the final independent security review are terminal on
   that unchanged head.
3. The operator freshly authorizes one provider run for that exact head. A head
   change or workflow rerun invalidates the authorization.

The infrastructure PR cannot authenticate or qualify itself. Its merge makes a
trusted controller available; the first passing live smoke necessarily targets
a later, distinct candidate commit under a separate exact-head authorization.

The hostile archive/path/process campaign is opt-in and remains outside normal
CI. Focused deterministic contract tests stay in normal CI. No U3c result
authorizes merge, release, publication, deployment, report-v2 cutover,
rollback, or component promotion.
