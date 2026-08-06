---
title: Release Candidate Evidence
type: reference
source: bin/hive-release-candidate, packaging/release_candidate/, packaging/managed_web_archive.rb, .github/workflows/{release-candidate,release}.yml
created: 2026-07-27
updated: 2026-08-06
tags: [release, candidate, evidence, packaging, safety]
---

**TLDR**: `bin/hive-release-candidate` is a local-first, evidence-only
candidate surface. It resolves one full committed SHA, exports committed bytes
with `git archive`, builds the gem/source/agent-skill/managed-web artifacts once,
and stores immutable artifacts plus append-only attempt evidence under the
gitignored `tmp/release-candidates/<sha>/` root.

The managed-Web subtree archive pins every entry to the candidate commit
timestamp. Archiving `<sha>:web` without that explicit timestamp would use the
wall clock for the tree object and make repeated exact-SHA builds produce
different bytes.

Candidate `builder_revision` hashes stable repository-relative labels plus the
exact committed bytes for `proof.rb`, the Workflow Creator bundle/Core/
contract/execution/Values/TextSafety sources, `build.rb`, and
`packaging/managed_web_archive.rb`. Verification re-derives that identity from
the retained source archive with bounded compressed size, entry count,
expanded bytes, and per-input bytes. Missing, duplicate, case/noncanonical,
wrong-type, linked/unsupported, oversized, or drifted closure entries fail
closed; this is narrow exact-input admission for the builder closure, not a
generic archive extraction subsystem. The managed-Web helper runs in an
isolated Ruby process from that exported candidate source with only an
allowlisted path/locale environment. Parent Ruby, Bundler, and coverage startup
hooks cannot alter helper loading, so the executed implementation and the
recorded builder identity cannot diverge when a local checkout or process
environment differs from the requested candidate SHA.

`plan` is the default and is read-only. `list` and `inspect` are observational.
`run`, `resume`, and `rerun` are explicit local mutations; local attempts use
the candidate SHA plus attempt ID, refuse identity drift, and take a nonblocking
candidate lock. A rerun accepts exactly one selector mode (`--failed`,
`--missing`, or named `--gate` entries). Effective gates reference predecessor
attempt results rather than copying or rewriting terminal evidence.

Local evidence keeps `trust_scope`, `scope_status`, and `qa_status` separate. A
passing requested local scope exits successfully but remains `qa_blocked` on
`remote_validation_required`. The v0.7.0 development candidate is newer than
the reviewed v0.6.9 baseline, so `candidate_not_newer` no longer applies; the
command does not choose a version or print/perform a release action. `dispatch`
is the sole explicit GitHub-writing verb and
`collect` is read-only. Both bind a request ID, candidate/workflow SHA,
action-lock digest, exact run/attempt, and artifact ID/digest. Dispatch either
resolves that request-bounded run or returns `dispatched_unresolved`; collect
reports queued, running, terminal, not-found, ambiguous, or bounded timeout.

The candidate root and every path component are current-user-owned,
non-symlink directories. Candidate files are manifest-bound by size and
SHA-256, unmanifested or substituted files are rejected, input manifests are
immutable, attempt directories are append-only, indexes use atomic replacement,
and INT/TERM interruption records a partial attempt before returning a
retryable exit.

## CLI side effects and evidence

The CLI deliberately separates observation, local evidence, and remote writes:

| Verb | Side effect |
|------|-------------|
| `plan` | Default, read-only checkout/cache inspection. Resolves a full committed SHA and returns blockers, exact `fetch_argv`, local run argv, and no release actions. |
| `list`, `inspect` | Read existing local evidence for the required `--sha`; neither creates an attempt. |
| `run` | Builds committed candidate bytes once, writes immutable candidate inputs/artifacts, and appends one local attempt. Optional repeated `--gate NAME` narrows the requested local scope. |
| `resume` | Appends a successor attempt for the incomplete local gates of one immutable `--attempt`. |
| `rerun` | Appends a successor selected by exactly one of `--failed`, `--missing`, or repeated `--gate NAME`; predecessor evidence is referenced, not rewritten. |
| `collect` | Read-only GitHub observation by exact `--workflow-run` plus `--attempt`, or by `--request`; `--wait --timeout SECONDS` remains bounded. |
| `dispatch` | The only GitHub write. A new `--sha` dispatch or an exact predecessor retry dispatches the trusted workflow, but never tags or releases. |

Every verb accepts `--json`. Local terminal attempts conform to
`schemas/hive-release-candidate-evidence.v1.json`; they carry immutable identity
digests, selected/effective gates, artifact manifests, coverage and baseline
inputs, scope/trust/QA status, blockers, and a non-authoritative next action.
`scope_status: passed` means only the requested local scope passed. It cannot
turn local `trust_scope` into `trusted_remote` or clear
`remote_validation_required`.

## Orchestration boundaries

`Runner` is the stable public façade and composition root. `Repository` owns
committed candidate inputs and Git identity; `BaselineCache` performs only
cache authorization and observation; `GateExecution` returns gate results
without persistence; `LocalAttempt` owns candidate locking, attempt selection,
artifact/input preparation, interruption capture, and evidence publication;
and `RemoteRun` owns dispatch/retry/collection orchestration while retaining
`RemoteWorkflow` as the protected-main and remote-payload boundary. These are
internal collaborators: none constructs or requires `Runner`, and no new
public component contract is implied.

## Reviewed release baselines

`packaging/release_candidate/baselines.yml` is the reviewed, non-floating
baseline catalog. Its `latest-stable` alias is pinned to v0.6.9. The initial
historical `legacy-bench-v041` row binds the real v0.4.1 producer and v0.4.2
collision observer. Every package and checksum/signature/certificate asset has
one canonical HTTPS release URL, exact filename, byte size, and SHA-256. Rows
also name their owner, review date, rationale, retirement rule, supported
platforms, before/transition/after/idempotency oracles, tagged `Gemfile.lock`
digest, and required no-network offline runtime-closure manifest.

Catalog parsing is strict: unknown or omitted keys, duplicate rows, unsupported
platforms, tag/version drift, unsafe filenames, noncanonical URLs, incomplete
authentication, malformed locks, and a non-exact offline closure fail closed.
Candidate identity records the exact catalog digest and a separate normalized
catalog dependency-closure-policy digest. Attempt identity separately
fingerprints current cache status, authenticated release assets, and verified
cache closures without rewriting the immutable candidate-root inputs. A fresh
run may therefore record newly staged inputs, while resume/rerun rejects a
changed cache fingerprint as stale evidence. Gate details retain the two cache
digests for audit. Hosted freshness may compare a supplied non-prerelease tag
to the tracked alias and report `baseline_catalog_stale`, but it never floats or
rewrites the run input.

`plan` inspects the candidate-bound catalog and tag-scoped cache roots under
`tmp/release-candidates/baseline-cache/` without creating them. v0.6.9,
v0.4.1, and v0.4.2 have separate directories so their common
`SHA256SUMS{,.sig,.pem}` filenames cannot collide. Availability requires the
gem and all three authentication sidecars plus each row's exact producer lock,
the historical row's separate exact observer lock, offline-cache manifest, and
complete manifest-bound `gems/` directory.
Missing release files remain `baseline_assets_missing` and expose only the
needed exact `gh release download <tag> --repo ivankuznetsov/hive --pattern
<filename> --dir <tag-cache>` argv. Planning never executes those argv.

Cached bytes are accepted only as current-user-owned, single-link regular files
with exact size and digest. The authenticated checksum must bind the package
exactly once. Closure manifests declare the exact locked runtime transitive
closure, no-network posture, and unique filename/size/SHA-256 entries; missing,
extra, substituted, or linked cache entries fail closed.

The reviewed closure inventories are checked in at
`packaging/release_candidate/baseline_manifests/`. When a closure is absent,
`plan --json` includes this explicit, separately reviewed materialization argv
alongside the release-asset fetch argv:

```bash
ruby packaging/release_candidate/materialize_baseline_cache.rb \
  "$candidate_sha" \
  "$PWD/tmp/release-candidates/baseline-cache"
```

Operators should execute the exact `baseline_cache.fetch_argv[]` returned by
the plan rather than reconstructing it. The materializer reads the catalog,
tagged lockfiles, and manifest bytes from the candidate commit, downloads only
manifest-listed RubyGems files, verifies every size/SHA-256, and refuses to
replace an invalid cache entry. Candidate execution does not invoke it, and
installed package code starts only after all authenticated inputs are staged
and network access is disabled.

## Installed targets and containment

Upgrade code does not accept arbitrary executable paths. A trusted installer
contract installs every manifest-listed dependency from an authenticated
offline cache with RubyGems `--local --ignore-dependencies`, installs the
package into a separate role root, and binds a verified agent-skills archive to
a role-owned import root. Only `baseline`, `observer`, and `candidate`
manifests can resolve an executable, and it must be an owned executable regular
file beneath that root. Equal semantic versions remain distinguishable by
root, wrapper, gem, and skills digests.

Hosted fetch evidence retains the producer namespace's absolute cache roots,
but those paths are not executable authority. Install validates the exact
closed role set and each embedded role identity, then derives an in-memory
closure root beneath the consumer's current `HIVE_RC_CACHE_ROOT`. This keeps
the staged JSON immutable while allowing the Linux host cache to be consumed
through its read-only `/cache` mount; baseline and observer share their
reviewed row root, while candidate dependencies remain separately rooted.

Installed processes receive a closed environment: only locale and time-zone
values may survive from the host. `HOME`, `HIVE_HOME`, XDG roots, gem roots,
and `PATH` are rebuilt beneath isolated state/target roots; Bundler, checkout,
Git, credential, provider, loader, socket, and host Hive variables do not cross
the boundary.

The local sandbox seam accepts reachable Podman or Docker engines and emits an
invocation contract with a digest-pinned image, read-only root, read-only
repository and authenticated-cache mounts, one writable run mount, network
disabled, all capabilities dropped, no-new-privileges, a PID ceiling, and no
host socket/device/credential mounts. Engine-specific user isolation uses
Podman `--userns=keep-id` or Docker's explicit current uid/gid. No container is
pulled or started by planning. If neither supported engine is usable, the gate
is `unavailable` with the exact separately authorized
`bin/hive-release-candidate dispatch --sha <full-sha>` next action.

## Upgrade-survivor oracles

`latest_stable_upgrade` and `legacy_bench_v041_upgrade` are blocking candidate
gates. The default local CLI deliberately has no production upgrade executor:
both remain `unavailable` with
`compliant_local_upgrade_executor_unavailable`, even when the authenticated
cache and sandbox invocation contract are available. Preflight returns the
exact candidate-SHA hosted dispatch argv and does not begin a producer. Focused
tests can inject the trusted fixed executor seam, but that fixture success is
not release evidence. Only the trusted hosted aggregate can execute and promote
the real upgrade results.

Inside the disposable sandbox,
`packaging/release_candidate/hosted_upgrade_lane.rb` resolves only reviewed row
and platform identifiers. It loads `baseline`, optional `observer`, and
`candidate` role manifests from runner-owned roots. The fixed executor creates
a disposable Git project, runs the installed baseline binary, and captures
named before/transition/after/second-run snapshots. The historical producer
uses v0.4.1 to initialize state, installs the exact pinned legacy `bench.yml`
and four instruction files, then uses that old binary to create the task.
v0.4.2 must emit the exact `workflow_id_collision:bench` observation before the
candidate migration runs.

Snapshots name registry, config/default workflow, task identity/content/stage,
dependencies, markers, durable attempts, dispatch receipts, channel sidecars,
managed-web data, inert service definitions, status JSON, doctor JSON, and
installed bytes. Status/doctor comparison removes version, binary path,
PID/timing, schema-version, and array-order noise. It also omits the candidate's
version-owned managed-skill `expected` projection and treats newly emitted
empty task defaults (`closure: null`, `outcomes: []`, and a zero hidden archive
count) as equivalent to their absence. Observation mtimes are also volatile.
Observed managed-skill state and persisted task or archive values remain
protected. Every other state change appears as a normalized JSON-pointer diff.
The v0.4.1 transition explicitly permits the legacy archive/runtime install,
the candidate install identity, the bench default binding, the one-time project
registry identity rewrite, the doctor v1-to-v2 envelope replacement, and only
the named additive task-condition projection fields emitted by current status.
Core task identity, contents, stage, dependencies, and markers remain outside
the allowlist. A second candidate run accepts no changes.

Each command has bounded stdout/stderr and a process group. Teardown fails for
any surviving daemon, TUI, web, producer, observer, candidate, or inert service
stub. The channel phase first clones and records the authenticated baseline
prefix, then invokes the installed candidate's real `hive update` command
against an offline reviewed seam: a fixed curl/download shim on Linux and a
fixed local-formula Homebrew shim on macOS. The updater receives a dedicated
empty `HIVE_HOME` beneath the lane run root, so representative phase state
cannot shadow the reviewed prefix's channel marker or participate in the
channel-only migration. It verifies the candidate gem
digest, wrapper role, sidecars, dependency closure, exact active inventory, and
absence of stale baseline files. AUR remains in its incumbent post-release
gate.

`UpgradeSurvivor` is the stable coordinator for preflight, fixed phase order,
invariant comparison, channel verification, and teardown. Channel-prefix
verification, the reviewed channel updater, channel execution, state capture,
and phase execution live in focused collaborators under
`packaging/release_candidate/upgrade_survivor/`. The extraction preserves the
existing class names, command/environment contracts, and evidence shape; the
candidate tool-input digest includes every collaborator source.

Focused tests use a deterministic fake installed binary, which is explicitly
not acceptable producer evidence. This implementation did not execute the real
v0.6.9/v0.4.1/v0.4.2 packages or a container; those authenticated platform
results remain a hosted pre-release requirement.

## Trusted hosted proof

`.github/workflows/release-candidate.yml` accepts one full protected-main SHA
and request ID. Candidate and release Action references participate in a
deterministic action lock and must use full commit pins. One manifest-bound
candidate artifact is built before fan-out. Every blocking cell first runs the
gate verifier from a separate checkout of the trusted workflow revision,
records the exact producer workflow/run/attempt, candidate-artifact
ID/digest/original producer, action lock, SHA, and manifest filenames, and
uploads that receipt before candidate code executes. Retry preflight re-queries
and verifies the exact source run, run-name request, artifact, workflow, action
lock, terminal evidence digest, and digest-bound aggregate Check.
Candidate/evidence artifacts retain for 30 days and blocking jobs receive no
provider credentials.

The workflow keeps GitHub expressions, permissions, dependencies, the initial
protected-main trust bootstrap, and the checkout-free Check publisher in YAML.
After the bootstrap proves `workflow_sha == GITHUB_SHA`, it archives the exact
committed `packaging/release_candidate/` tree, digest-checks the archived
dispatch validator against `git show`, and runs that validator only from the
trusted archive. The attestation job's exact-workflow checkout runs two small
committed scripts for job/ordinary-CI queries and receipt/predecessor
collection. These three private workflow scripts are part of candidate tool
identity; candidate construction, platform sandbox commands, aggregate
construction, and publication remain at their existing review surfaces.

Catalog integrity uses a full-history candidate checkout because its focused
contracts read the reviewed historical tags. Managed-Web verification passes
the helper's documented `--name=value` arguments. The macOS upgrade cell keeps
a deny-default sandbox and permits read-only `sysctl` calls needed by the
hosted Ruby runtime plus writes to the literal `/dev/null` device used by
RubyGems. Its scrubbed process environment fixes `LANG` and `LC_ALL` to
`en_US.UTF-8`, so installed historical and candidate processes receive a
deterministic UTF-8 external encoding instead of macOS's US-ASCII fallback.
Network remains denied, every other write remains confined to the run root,
and Mach service lookup is not allowed. Install smoke starts Ruby, verifies
that exact external encoding, and opens `/dev/null` for writing under the same
profile on every PR. Constant-size checkpoint and exit-status lines identify
install, each required attestation, and upgrade-lane failures without provider
credentials.

Historical packages, dependency closures, and candidate bytes are downloaded
and authenticated before installed package code runs. Installation and the U4
lane then run with a scrubbed environment and network disabled. Linux uses a
full-manifest-digest-pinned Ruby image as an unprivileged, read-only container:
all capabilities are dropped, no-new-privileges and a PID ceiling are set,
only the trusted control repository and authenticated cache are mounted
read-only, and the run root is the sole writable mount. macOS uses a
deny-network sandbox on its ephemeral runner with the same trusted-control,
read-only-cache, and writable-run split. Captured subprocess diagnostics are
bounded and normalized to valid UTF-8 before they enter JSON evidence, including
when a byte limit cuts through a multibyte sequence.

Every blocking cell compares its candidate-controlled harness paths
byte-for-byte with the separately checked-out trusted workflow revision before
execution. The reviewed runtime closure includes the exact Bundler gem even
though Bundler omits itself from its lockfile parser output. Hosted receipts
and the final aggregate validate the strict `trusted_remote` branch of the
shared evidence schema; local evidence validates the separate strict `local`
branch. An absent latest-stable version is represented as JSON `null`, never a
truthy sentinel that could accidentally satisfy the version gate.

A non-writing attestation job queries exact current-run jobs and protected
ordinary CI, downloads the immutable per-cell receipts, and executes the closed
aggregate from the trusted workflow revision. Named, failed, and missing retry
selectors resolve an exact required display-name set. Only those replacement
steps execute; source effective rows retain their original run provenance, so
chained retries do not rewrite history. Missing, duplicate, substituted,
skipped, cancelled, or failed cells produce retained `qa_blocked` evidence.
The final `aggregate` job checks out no code, verifies terminal evidence by
SHA-256, and alone receives `checks: write`; its stable success or failure
Check Run external identity includes the evidence digest. Live-agent proof
remains advisory. Retry admission and release selection both ignore the Check
Run details URL because GitHub rewrites it after creation. They bind the
candidate SHA, GitHub Actions app, terminal state, and exact external identity,
then independently revalidate the referenced run, jobs, evidence artifact, and
evidence body.

The post-U8 protected-main campaign ran on 2026-08-05 against exact
candidate/workflow SHA `f113b6a238c0922e60ceafb091a9b215ce7c451e` as run
`31014105054`, attempt 1. It retained candidate artifact `8933713266` with
digest
`sha256:1a947e62ab4971c30db56523080397b552286be9665ce9e7b41423c3445ae3e7`
and terminal evidence artifact `8934052738`. The aggregate was correctly
`qa_blocked`: seven of fourteen required gates passed and seven failed. This
was dogfood evidence, not release authority, and no release action occurred.

That run also exposed two remote-edge response shapes. GitHub's compare API
can report identical full SHAs while omitting `head_commit`; the CLI normalizes
that exact response to the verified base SHA before protected-main identity
validation. GitHub also canonicalizes a newly created Check Run's requested
workflow-run details URL to `/runs/<check-id>`. Retry admission therefore binds
the separately verified source run/attempt and artifact to the exact candidate
SHA plus the Check Run's GitHub Actions app, terminal conclusion, and signed
external ID/evidence digest; it does not treat the mutable details URL as an
identity field.

Post-fix named retry `31015265841`, attempt 1 selected only `Candidate version
newer`. Its terminal evidence artifact `8934240492` binds predecessor run
`31014105054`, source evidence digest
`8b955774619c938f1ddefb7c230d7c0c14f1b9f67dde3a42e9e7c09b5ddd8750`,
and replacement set containing exactly that gate. The effective set takes that
one row from the retry and every other row from the source run, while reusing
the original candidate artifact ID, name, producer run/attempt, and digest.
The version gate still failed as expected because 0.6.9 is not newer than the
reviewed 0.6.9 baseline, so the retry remained `qa_blocked`; it nevertheless
proves selected-gate execution and immutable predecessor reuse.

The explicit hosted command sequence is:

```bash
bin/hive-release-candidate dispatch --sha "$candidate_sha" --json
bin/hive-release-candidate collect --request "$request_id" \
  --wait --timeout 7200 --json
```

A targeted successor uses the exact terminal source run and attempt with one
closed selector, for example:

```bash
bin/hive-release-candidate dispatch \
  --retry-workflow-run "$source_run_id" \
  --retry-attempt "$source_run_attempt" \
  --failed --json
```

`--missing` or repeated `--gate "Required display name"` are the alternatives.
The new evidence run/attempt identifies the retry and aggregate; the candidate
artifact retains its original producer run/attempt/name/ID/digest. This split
is required for chained retries and is revalidated by collection and tag-time
selection.

All deterministic required cells are blocking. Provider-backed live-agent
results may be linked only as `class: advisory`; absence, failure, or prose
from that diagnostic cannot weaken or replace a required deterministic row.

## Exact-byte tag handoff

The explicit `vX.Y.Z` tag remains the only release trigger. Before any
publication job starts, `.github/workflows/release.yml` resolves the tag target
to a full SHA and selects exactly one successful `hive-release-candidate`
Check Run for that SHA. The pure release selector revalidates the repository,
workflow revision/path, protected-main dispatch identity, request ID,
run/attempt, required attestation and aggregate jobs, action lock, exact
ordinary-CI run, trusted-remote `qa_ready` evidence, effective gate lineage,
and both the terminal-evidence and original candidate artifact identities.
Targeted retries may therefore supply the final evidence run while retaining
the original candidate producer run and bytes.

The workflow downloads both Actions archives by server artifact ID, verifies
their server-reported SHA-256 digests before safe extraction, and verifies the
evidence JSON digest from the aggregate Check Run external ID. The candidate
manifest must contain exactly the expected gem, internal committed-source,
agent-skill, and managed-web filenames for the tag version and target SHA. The
source archive must declare that version through the canonical
`lib/hive/version.rb` source, and it must remain newer than the catalog-pinned
latest stable version already proven by the blocking candidate gate.

Only the manifest-bound gem, skill, and web bytes are restaged for native
install and publication. The source archive stays an internal retained QA
input. The tag workflow has no gem, source, skill, or web build and no fallback
dispatch or rebuild: missing, expired, mixed, stale, or substituted proof fails
before the existing GitHub Release, Homebrew, AUR, Docker, and post-release
graph can begin.

`qa_ready` is evidence, not release authority. Only a maintainer's separate,
explicit decision to create and push `vX.Y.Z` may start `release.yml`. The
candidate CLI and trusted aggregate never choose a version, create a tag,
publish, deploy, or release.

The checked-in source metadata is prepared as 0.7.0 while the reviewed
latest-stable alias remains v0.6.9, clearing only the candidate-version
comparison. Previous hosted evidence belongs to its exact older candidate SHA
and cannot qualify these bytes; a fresh trusted remote campaign is still
required. No release action was authorized or performed.
