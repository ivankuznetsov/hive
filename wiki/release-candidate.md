---
title: Release Candidate Evidence
type: reference
source: bin/hive-release-candidate, packaging/release_candidate/, packaging/managed_web_archive.rb, .github/workflows/{release-candidate,release}.yml
created: 2026-07-27
updated: 2026-09-09
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
`remote_validation_required`. The v0.7.2 development candidate is newer than
the reviewed v0.7.1 baseline, so `candidate_not_newer` no longer applies; the
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
baseline catalog. Its `latest-stable` alias is pinned to v0.7.1; historical
Bench producer/observer rows have been retired. Every retained package and
checksum/signature/certificate asset has one canonical HTTPS release URL, exact filename, byte size, and SHA-256. Rows
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
`tmp/release-candidates/baseline-cache/` without creating them. Each retained
tag has a separate directory for its gem and `SHA256SUMS{,.sig,.pem}` files.
Availability requires those authentication sidecars, the exact producer lock,
offline-cache manifest, and complete manifest-bound `gems/` directory.

The explicit cache materializer downloads each baseline's tagged
`Gemfile.lock` as immutable bytes and verifies its reviewed SHA-256 before using it. It does not fetch or
archive tags through the Actions checkout, because mutating a shallow checkout
can race Git's shallow-file maintenance. Package assets and dependency gems
are fetched only by the separately authorized materialization step.
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
replace an invalid cache entry. Candidate execution does not invoke the
materializer automatically.

## Current installation proof

The hosted candidate workflow installs the exact candidate gem on Linux x86-64,
Linux ARM64, and macOS ARM64 through
`packaging/live_agent_skills/install_candidate_gem.sh`, then verifies the
installed binary. Managed-Web setup is a separate required job. These jobs
retain exact candidate-artifact receipts before executing candidate code.

Historical upgrade-survivor executors, baseline/observer phase snapshots,
channel-update replay and their Linux/macOS sandbox jobs have been removed.
The local gate registry contains artifact integrity, coverage catalog, baseline
catalog and candidate-version checks, plus the reserved trusted-remote gate.
Baseline identity, cache authentication, catalog freshness and version ordering
remain release requirements; they do not promise compatibility with old runtime
storage. See `docs/guides/current-format-migration.md` for that separate offline
conversion.

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
identity; candidate construction, platform installation commands, aggregate
construction, and publication remain at their existing review surfaces.

Catalog integrity uses a full-history candidate checkout because its focused
contracts read reviewed release tags. Managed-Web verification passes the
helper's documented `--name=value` arguments. Native install jobs run on their
named platform runners and verify the installed candidate version; the deleted
historical upgrade sandbox is not part of these current proof jobs.

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
The tag selector also reads that dependency-free version leaf with RubyGems
disabled before candidate selection; it does not load the top-level Hive
runtime or require installed runtime dependencies merely to compare the tag.
Tag-time source inspection accepts the optional single canonical PAX global
header emitted by `git archive` for the exact candidate SHA. It independently
rejects duplicate or malformed global metadata and still rejects links and
every other special archive entry.

Only the manifest-bound gem, skill, and web bytes are restaged for native
install and publication. The macOS and Linux ARM install gates count the
selected gem with a shell glob array and require its sole entry to be non-empty;
they do not parse platform-specific, padded `wc` output. The source archive
stays an internal retained QA input. The tag workflow has no gem, source,
skill, or web build and no fallback
dispatch or rebuild: missing, expired, mixed, stale, or substituted proof fails
before the existing GitHub Release, Homebrew, AUR, Docker, and post-release
graph can begin.

`qa_ready` is evidence, not release authority. Only a maintainer's separate,
explicit decision to create and push `vX.Y.Z` may start `release.yml`. The
candidate CLI and trusted aggregate never choose a version, create a tag,
publish, deploy, or release.

The checked-in source metadata is prepared as 0.7.2 while the reviewed
latest-stable alias remains v0.7.1, clearing only the candidate-version
comparison. Previous hosted evidence belongs to its exact older candidate SHA
and cannot qualify these bytes; a fresh trusted remote campaign is still
required. No release action was authorized or performed.
