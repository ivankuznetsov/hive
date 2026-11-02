---
title: hive bench submit
type: command
source: lib/hive/commands/bench_submit.rb
created: 2026-06-14
updated: 2026-11-02
tags: [command, bench, corpus]
---

**TLDR**: `hive bench submit SLUG [--project NAME]` extracts a completed
(`9-done`) task into a [hive-bench](https://github.com/ivankuznetsov/hive-bench)
corpus entry and opens a submission PR. A low-friction producer for the
benchmark — it reuses hive-bench's own extractor and runs a local secret-token
preflight, aborting before any PR if a secret is found.

## Usage

```bash
hive bench submit SLUG [--project NAME] [--json]
```

`submit` is the only public bench subcommand. `--project` disambiguates a slug
that exists in more than one registered project; `--json` changes only the
success output.

## Behavior

1. Resolves `SLUG` to a `9-done` task across registered projects (`--project`
   to disambiguate). A missing or ambiguous slug is a USAGE error (64).
2. Verifies the task is extractable by requiring both `worktree.yml` and
   `pr.md`; missing either file aborts before extraction.
3. Runs a local secret-token preflight over any present `idea.md`,
   `brainstorm.md`, `plan.md`, `task.md`, and `pr.md`. The current local scan
   flags private keys, GitHub tokens, `sk-...` API keys, and AWS access keys;
   any finding aborts before a PR is opened.
4. Shells to hive-bench's `harness/extract.rb` (located via `HIVE_BENCH_PATH`,
   default `~/Dev/hive-bench`) to build the entry. The command derives the
   source repo from the project's `origin` remote and requires it to be a
   `github.com` remote.
5. Records the hive-bench checkout's original branch (or detached HEAD),
   resolves the remote default through `Hive::GitOps` (`origin/HEAD` with
   full-ref `origin/main` / `origin/master` fallbacks),
   creates `submit-<slug>` from that remote default, stages the generated
   entry, commits, pushes, and runs `gh pr create -R ivankuznetsov/hive-bench`.
   An ensure path restores the original branch/HEAD even when commit, push, or
   PR creation fails. Success records the exact submission ref and commit SHA;
   the entry locator is repository-relative so it remains meaningful after the
   original checkout has been restored and the entry is no longer present in
   the working tree.

## Notes

- hive depends on hive-bench only as a *producer* here; hive-bench never depends
  on hive. See [[commands]] for the full command list.
- `--json` emits a success document with `schema`, `slug`, `entry`, `pr_url`,
  `submission_ref`, and `commit_sha`; `entry` is relative to the hive-bench
  repository and the ref/SHA identify the checkout that contains it. The
  `schema: "hive-bench-submit"` contract is not currently registered in
  `Hive::Schemas::SCHEMA_VERSIONS`, and failures still use the normal stderr +
  exit-code path rather than a structured JSON error envelope. Injected legacy
  PR-opener seams that return only a URL retain the original fields but cannot
  supply ref/SHA metadata.
- The extractor and PR-opening subprocesses use argv/array-form `Open3` calls.
  The extractor `-I` flag and harness path are separate argv entries; the
  remaining Brakeman ignore for `gh pr create` is documented in [[testing]].
- Tests cover both injected seams and the default seam methods using a stub
  extractor script plus stub `git`/`gh` binaries. Real temporary repositories
  prove success and GitHub failure restore the original branch/HEAD, including
  exact detached-HEAD restoration, and that the reported locator resolves at
  the recorded submission SHA. Live hive-bench / GitHub submission evidence is
  tracked in [bench live proof](#hive-bench-submit-is-unit-pinned-but-not-live-smoked).

## Exit codes and serialization

Text mode is human-readable. `--json` success uses the unregistered
`hive-bench-submit` schema described above; failures remain stderr plus an exit
code rather than a structured error schema. The success producer calls
`JSON.generate` directly, and a serialization failure propagates without a
fallback document.

| Code | Meaning |
|---:|---|
| 0 | The corpus entry was committed, pushed, and submitted. |
| 64 | The subcommand, slug, project selection, source task, secret scan, extractor, Git operation, or PR creation failed its usage contract. |
| 1 | An unexpected non-Hive failure escaped the command. |

The success producer calls `JSON.generate` directly. A serialization failure
is not replaced with text or a fallback JSON document; it propagates as a
failed invocation.

## Examples

```bash
hive bench submit completed-task-260901-abcd --project hive
hive bench submit completed-task-260901-abcd --project hive --json
```

## Known gaps

### Strict benchmark candidate patch history

#### Source S18, lines 352–357: OpenCode live validation (updated 2026-08-21)

Strict benchmark campaigns can now require normal execute completion before
judging. Retrying such a campaign intentionally permits the failed cell's
preserved candidate patch to be replaced; the run tree retains attempt logs,
but Hive does not yet provide a campaign-level archive view of every replaced
patch.

### Ox Alpha benchmark transport and profile evidence

#### Source S18, lines 369–399: OpenCode live validation (updated 2026-08-21)

The Ox Alpha benchmark now supplies authenticated live OpenRouter transport and
has exercised OpenCode `1.18.18` with the Compound Engineering plugin under
parallel load. Repeated exports ending near the same JSON position were traced
to OpenCode issuing one unawaited large stdout write: a controlled reproduction
wrote only 245,760 of 983,152 bytes through a pipe, while regular-file stdout
produced complete parseable JSON. Hive now sends sanitized export stdout to an
unlinked private regular file, enforces the parser's four-MiB bound while
reading it, and still fails closed on malformed evidence. Exports retain a
60-second process deadline, and an inspection failure remains the surfaced task
diagnostic instead of degrading to a generic missing-evidence message. The
strict six-task OpenCode campaign subsequently completed generation, dual
three-sample judging, deliberation, validation, and publication. Its original
token gap is an extraction issue rather than missing provider evidence: Hive
records OpenCode usage in `.hb/hive-home/runtime-control-plane.sqlite3` while redacting raw stream
events. The packaged harness now reads those normalized rows when stream tokens
are absent. The first OpenRouter-backed Sol
deliberation also exposed that the pinned npm Codex entrypoint could see a mise
Node shim but not its active runtime under Hive's narrow agent PATH; the
harness now prepends that pinned entrypoint's own directory for the child only.
The next retry reached OpenRouter but inherited the operator's Codex profile,
project instructions, and tool integrations, turning a one-shot scoring prompt
into a large agent session before OpenRouter rejected the in-flight credit
reservation. OpenRouter-backed Codex judges now run from a private temporary
home and empty working directory with user config, rules, and session
persistence disabled. A real Ox Alpha probe returned the requested score
directly through this boundary. The ChatGPT route now uses the same empty
workspace and ephemeral/config/rules flags while retaining the operator Codex
home only for subscription authentication; a real Sol-ultra probe returned its
score directly there. The separate Pi `all-ox-alpha@max` route is source- and
probe-pinned; its full six-cell campaign remains live evidence until completion.

### Benchmark contamination-risk audit

#### Source S18, lines 400–412: OpenCode live validation (updated 2026-08-21)

An August 26 contamination audit found that earlier local campaigns cloned the
current Hive repository and then reset it to the historical base. That removed
the remote but retained newer objects/refs; one Ox Alpha Pi review command did
run `git log --all`, although its captured output did not include that task's
gold commit. No Pi tool call fetched GitHub or named its own reference PR/hash.
The old OpenCode streams omitted tool payloads, so the same negative audit is
not possible for that row. These rows therefore retain a structural
contamination-risk caveat even without confirmed gold retrieval. New candidate
repositories fetch only the exact base at depth one, and strict campaigns bind
provider-only proxy egress into generation identity. Training-time memorization
of a public solution remains outside container control; post-run patch
similarity and private/newer corpus tasks are still needed for that risk.

### Sealed benchmark replacement campaign evidence

#### Source S18, lines 413–422: OpenCode live validation (updated 2026-08-21)

The first post-audit replacement attempt still exposed a second local answer
surface: the active dogfood Hive checkout was bind-mounted read-only and the
runner's normal gem tree contained the installed `hive-cli` source. Candidate
uid 1000 could read both even though logs show no Pi command opening the active
checkout. Sealed campaigns now use a commit-labelled, root-only Hive control
bundle, remove `hive-cli` from the candidate bundle, and drop Pi/OpenCode to an
uncapable uid 1000 process. A real container proof established that boundary;
the remaining gap is a fresh six-cell Pi/OpenCode generation and judgment run
created after the sealed dogfood deployment.

### OpenCode benchmark shell parity

#### Source S18, lines 423–433: OpenCode live validation (updated 2026-08-21)

The same audit found a separate OpenCode fairness defect in the completed high
campaign: its benchmark config granted only `Read`, `Write`, and `Edit`, while
Pi retained shell access inside the disposable generation container. OpenCode
could change files but could not run tests, inspect repository state through
normal shell diagnostics, or verify its work; all six review attempts ended
without an accepted review patch. The packaged runtime now adds the explicitly
qualified `Bash(*)` permission. The container, exact-base checkout,
provider-only proxy, and sealed controller bundle remain the isolation
boundary. The old OpenCode score is superseded pending a sealed six-cell rerun
with that parity grant.

### Built-in bench installed-daemon retry evidence

#### Source S25, lines 669–683: Current release gap

- The built-in `bench` descriptor, packaged stage instructions, self-contained
  runtime snapshot, and `hive init . --workflow bench` path ship in Hive 0.7.0.
  The live Opus/Fable campaign is now a task in the one registered `hive-bench`
  project and has completed two paid, independently dual-judged cells. Its
  installed pre-fix generate instruction then reproduced an id-less quota
  marker after the earlier one-off migration, parking recovery even after the
  cooldown. Source and focused tests now route that marker through
  `Hive::Markers.set`; an installed-daemon retry still needs to prove the fix
  live. A separate campaign-specific Hive project is no longer an intended
  validation target. Honeycomb is not a dependency of this named-workflow path.
  The DeepSeek and Grok expansion then reproduced a second false-success path:
  a provider process returned while Hive's pre-spawn `AGENT_WORKING` marker
  remained current. Source tests now rewrite that state to a recoverable
  `ERROR reason=agent_exited_without_terminal_marker`; a post-merge retry on the
  shared current-main Hive deployment remains the required live proof.

### `hive bench submit` is unit-pinned but not live-smoked.

#### Source S28, lines 858–858: Open questions about the codebase

44. **`hive bench submit` is unit-pinned but not live-smoked.** Commit `ef47b9c0` adds `Hive::Commands::BenchSubmit` and CLI wiring for `hive bench submit SLUG [--project NAME]`: it resolves completed `9-done` tasks, requires `worktree.yml` and `pr.md`, derives the source repo from a GitHub `origin`, runs a local secret-token preflight over task spec files, delegates extraction to hive-bench's `harness/extract.rb`, then uses `git` and `gh pr create` in the hive-bench checkout. Commit `c4e2cab5` keeps the extractor subprocess argv-only by splitting the `ruby -I` flag/path and records the remaining `gh pr create` Brakeman finding as an array-form `Open3` false positive. Commit `90aa0501` extends `test/unit/commands/bench_submit_test.rb` beyond injected-seam orchestration: it covers the default local secret scanner, JSON/text reporter, `run_git`, extractor invocation against a stub `harness/extract.rb`, and PR opener through stub `git`/`gh` binaries. This refresh did not find an in-tree artifact showing the command against a real `HIVE_BENCH_PATH` checkout, a generated corpus entry that passes hive-bench validation, a real push, or a created GitHub PR.

#### Source S28, lines 862–862: Open questions about the codebase

44. **`hive bench submit` is unit-pinned but not live-smoked.** Commit `ef47b9c0` adds `Hive::Commands::BenchSubmit` and CLI wiring for `hive bench submit SLUG [--project NAME]`: it resolves completed `9-done` tasks, requires `worktree.yml` and `pr.md`, derives the source repo from a GitHub `origin`, runs a local secret-token preflight over task spec files, delegates extraction to hive-bench's `harness/extract.rb`, then uses `git` and `gh pr create` in the hive-bench checkout. Commit `c4e2cab5` keeps the extractor subprocess argv-only by splitting the `ruby -I` flag/path and records the remaining `gh pr create` Brakeman finding as an array-form `Open3` false positive. Commit `90aa0501` extends `test/unit/commands/bench_submit_test.rb` beyond injected-seam orchestration: it covers the default local secret scanner, JSON/text reporter, `run_git`, extractor invocation against a stub `harness/extract.rb`, and PR opener through stub `git`/`gh` binaries. This refresh did not find an in-tree artifact showing the command against a real `HIVE_BENCH_PATH` checkout, a generated corpus entry that passes hive-bench validation, a real push, or a created GitHub PR.

### Sealed benchmark controller hardening awaits a live canary (2026-08-27)

#### Source S70, lines 1619–1632: Sealed benchmark controller hardening awaits a live canary (2026-08-27)

The sweep ran a network-disabled Docker canary through the actual root-controller
origin setup with candidate-created `hive`/`git` shims, a pre-push hook, and a
malicious global `init.templateDir` pointing at the sealed bundle. The shallow
push and actual ManagedGit environment-scrubbing call passed; no hook, shim, or
template copy ran, and uid 1000 could not read the control bundle. Executable
Pi extension checks covered both GLM routes and unchanged other-model payloads.
This is boundary/setup proof, not a complete model-driven offline review cycle.
Keep the full-cycle gap open until that lifecycle has its own packaged canary.
Resumed review also needs verification: recreated offline origins omit prior
published branches, while the existing remote-CI gate rejects local repository
identity before that expected-head path. Setup proof does not establish that
these older offline lifecycle limitations are solved.

### Benchmark egress preflight awaits a live Docker bypass canary (2026-08-27)

#### Source S71, lines 1634–1642: Benchmark egress preflight awaits a live Docker bypass canary (2026-08-27)

Focused tests inject Docker network metadata and prove that strict topology is
checked before the parallel campaign matrix starts. The 2026-09-09 sweep also
ran real Docker network inspection: an internal network with only the named
proxy container was admitted, and adding a peer was rejected. That proof used
inert containers; it did not run the packaged CONNECT proxy or attempt direct
HTTPS from a candidate. Keep this gap open until the packaged CI gate proves direct egress
fails while the allowlisted proxy route still succeeds end to end.

### Resolved

#### Benchmark-only plan-review opt-out live parity proven (2026-08-22)

##### Source S66, lines 1538–1548: Benchmark-only plan-review opt-out live parity proven (2026-08-22)

The local benchmark runtime can now grant an explicit process-local exception
for projects that serialize `plan_review.enabled: false`; ordinary Hive loads
still reject that configuration. The completed Ox Alpha campaign proved the
grant and replacement transition live across six Pi cells and six OpenCode
cells: all 12 reached generated terminal results without plan-review dispatch,
pending rows, or failed rows. Focused coverage continues to pin that disabled
review bypasses prepare, locked verification, and execute entry as well as
policy dispatch. Keep the exception benchmark-local; the parity-evidence gap
itself is closed.
