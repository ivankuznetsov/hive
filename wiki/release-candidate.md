---
title: Release Candidate Evidence
type: reference
source: bin/hive-release-candidate, packaging/release_candidate/, packaging/managed_web_archive.rb, .github/workflows/{release-candidate,release}.yml
created: 2026-07-27
updated: 2026-08-01
tags: [release, candidate, evidence, packaging, safety]
---

**TLDR**: `bin/hive-release-candidate` is a local-first, evidence-only
candidate surface. It resolves one full committed SHA, exports committed bytes
with `git archive`, builds the gem/source/agent-skill/managed-web artifacts once,
and stores immutable artifacts plus append-only attempt evidence under the
gitignored `tmp/release-candidates/<sha>/` root.

`plan` is the default and is read-only. `list` and `inspect` are observational.
`run`, `resume`, and `rerun` are explicit local mutations; local attempts use
the candidate SHA plus attempt ID, refuse identity drift, and take a nonblocking
candidate lock. A rerun accepts exactly one selector mode (`--failed`,
`--missing`, or named `--gate` entries). Effective gates reference predecessor
attempt results rather than copying or rewriting terminal evidence.

Local evidence keeps `trust_scope`, `scope_status`, and `qa_status` separate. A
passing requested local scope exits successfully but remains `qa_blocked` on
`remote_validation_required`. The v0.6.9 development candidate is also blocked
by `candidate_not_newer`; the command does not choose a version or print/perform
a release action. `dispatch` is the sole explicit GitHub-writing verb and
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

The candidate `builder_revision` binds the live-agent proof builder, its build
wrapper, and all five U1a creator-contract sources, in addition to the managed
web archive builder. Verification recomputes that identity from the committed
source archive rather than the worktree. A creator vocabulary, schema, bundle,
execution-transaction, or primitive change therefore invalidates an artifact whose
manifest still names the older builder closure.

The source-archive verifier treats those builder inputs and their ancestor
directories as a protected namespace. It case-folds collision keys so Linux
and default case-insensitive macOS reach the same verdict, accepts only each
protected path's one canonical spelling and type, and rejects leading or
embedded dot segments, repeated separators, case aliases, duplicate
destinations, and links at protected paths before reading builder bytes. It
rejects per-entry PAX/GNU rewrite metadata; when Git emits a global PAX header,
only one exact `comment=<candidate SHA>` record is accepted. The scan is capped
at 256 MiB compressed, 16,384 entries, 1 GiB expanded content, and 1 MiB per
protected builder input, so digest recomputation cannot become an unbounded
archive parser.

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
installed bytes. Status/doctor comparison removes only version, binary path,
PID/timing, schema-version, and array-order noise. Every other state change
appears as a normalized JSON-pointer diff; the historical archive/runtime
migration and candidate install identity are the only initial allowlisted
migrations. A second candidate run accepts no changes.

Each command has bounded stdout/stderr and a process group. Teardown fails for
any surviving daemon, TUI, web, producer, observer, candidate, or inert service
stub. The channel phase first clones and records the authenticated baseline
prefix, then invokes the installed candidate's real `hive update` command
against an offline reviewed seam: a fixed curl/download shim on Linux and a
fixed local-formula Homebrew shim on macOS. It verifies the candidate gem
digest, wrapper role, sidecars, dependency closure, exact active inventory, and
absence of stale baseline files. AUR remains in its incumbent post-release
gate.

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

Historical packages, dependency closures, and candidate bytes are downloaded
and authenticated before installed package code runs. Installation and the U4
lane then run with a scrubbed environment and network disabled. Linux uses a
full-manifest-digest-pinned Ruby image as an unprivileged, read-only container:
all capabilities are dropped, no-new-privileges and a PID ceiling are set,
only the trusted control repository and authenticated cache are mounted
read-only, and the run root is the sole writable mount. macOS uses a
deny-network sandbox on its ephemeral runner with the same trusted-control,
read-only-cache, and writable-run split.

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
remains advisory.

No hosted workflow was dispatched during implementation. The workflow and
targeted-retry behavior remain contract-tested source until an explicitly
authorized exact-head hosted run exercises the real matrix.

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

Current implementation evidence is intentionally blocked: the checked-in
source version is 0.6.9 and the reviewed latest-stable alias is also v0.6.9, so
`candidate_not_newer` applies. No real hosted, native-platform, or historical
package candidate run was performed, and no release action was authorized.
