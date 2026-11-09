# Direct v1 credential isolation

This declaration applies to `ruby harness/run_all.rb` and
`ruby harness/pipeline_run.rb` v1-slate runs through `HiveBench::IsolationExec`
and `hb_isolated`. It does not apply to the packaged `generate.md` →
`harness/hive_run.rb` → `HiveDriver` v2 candidate path. That path, including
`env_args`/`auth_mounts` credential forwarding and `hive_stages.sh` materialization
of in-container `auth.json`, is byte-for-byte unaffected.

Pi's first model-provider segment selects one key: `openrouter` selects
`OPENROUTER_API_KEY`, `anthropic` selects `ANTHROPIC_API_KEY`, and `openai`
selects `OPENAI_API_KEY`. Nested model paths and thinking suffixes are retained.
Bare/unknown routes refuse before any subprocess; no provider is inferred from
model family, host keys, profile labels or Pi's host auth file. Claude/Codex
require their configured `auth_path`. Ruby clears both inherited OAuth controls
and supplies only the selected file. Parent `ENV` and profiles are unchanged.

Direct wrapper callers must set `HB_ALLOW_EGRESS=1` and explicitly declare
`HB_API_KEYS`. Unset refuses; exactly one of the three variable names above
permits only that API key, with no OAuth paths. An explicitly empty value
requires exactly one nonempty `HB_CLAUDE_AUTH` or `HB_CODEX_AUTH`, referring to
an existing regular file. Unknown names, whitespace, assignments, multiple
names, dual OAuth and mixed API/OAuth refuse before Docker with exit 70 and a
fixed diagnostic. Values and rejected paths never enter refusal diagnostics.
Docker receives `-e NAME`; a selected key that is absent/empty is omitted and
never replaced by another key. Gate ignores every generator credential control,
forwards no provider credentials, and always uses `--network none`.

For example, with a host key already exported:

```bash
HB_ALLOW_EGRESS=1 HB_API_KEYS=OPENROUTER_API_KEY \
  HB_CLAUDE_AUTH= HB_CODEX_AUTH= \
  bash harness/lib/isolation.sh gen "$PWD/work" 'your runner command'
HB_ALLOW_EGRESS=1 HB_API_KEYS= HB_CODEX_AUTH= \
  HB_CLAUDE_AUTH="$HOME/.claude/.credentials.json" \
  bash harness/lib/isolation.sh gen "$PWD/work" 'your runner command'
```

Qualify a Pi entry in `harness/profiles/slate.rb` `PI_MODELS` to
`openrouter/<verified-id>` only after verifying that route. No id is suggested
for `minimax-3` or `qwen-2.6-coder`. Until both bare entries are qualified,
default unfiltered `run_all.rb` passes park both in `failed` and exit 2.
`harness/profiles/README.md` must be updated with that future migration.
`preflight.rb` checks binary/auth/version only; OK does not prove routing.

## Proofs

Hive's default isolation tests load the packaged runtime. Canonical tests load
`harness/` in hive-bench. They use decoy credentials and fake Docker, proving
exact forwarded names, argv boundaries, mounts, refusals and secret-free Ruby
exceptions. The expensive interpreter and real-container matrices run only via:

```bash
bundle exec rake test:bench_isolation_proof
HB_TEST_BASH_32=/absolute/path/to/bash-3.2 bundle exec rake test:bench_isolation_proof
```

The named `bench-isolation-proof` CI job runs `ubuntu-24.04` and `macos-15`.
The macOS lane must execute `/bin/bash` with `$BASH_VERSION` beginning `3.2`;
missing/wrong versions fail. Linux may record a reasoned 3.2 skip without the
local override. Both lanes record interpreter version provenance and exercise
Pi, gate, Claude and Codex, including all empty-array shapes. Proof files are
excluded from Hive's default suite and all six coverage shards.

The real-container matrix uses stock
`docker.io/library/alpine:3.22.2@sha256:4b7ce07002c69e8f3d704a9c5d6fd3053be500b7f1c69fc0d80990c2ad8dd412`.
It sets `HB_RUNNER_IMAGE` and calls `hb_isolated <mode> <work> sh -c '<probe>'`
with separate argv elements; a production single command string needs the
custom runner entrypoint and is unsuitable for this stock image. Probes check
only credential-related environment names, selected read-only OAuth files and
absence of the other file, with decoys only. Docker daemon unavailability is a
separate skipped result. An image pull/setup failure fails the probe rather
than claiming Docker is unavailable. These proofs make no paid calls and do
not promise network-level provider isolation or protect secrets intentionally
placed in the work tree/image.

## Refresh an existing Hive bench project

Upgrading Hive leaves an existing `.hive-state/bench-runtime` snapshot pinned.
Use the corrected Hive installation to refresh an existing **bench** project.
Do not run these commands in an active campaign. Keep the recorded revisions
and hashes with the campaign evidence. `hive init` is the existing runtime
installation mechanism; `install_runtime!` has no automatic upgrade behavior.

From that project's root, first inspect and resolve unrelated changes, staged
entries or conflicts in both worktrees. Do not reset or discard them:

```bash
git status --short
git -C .hive-state status --short
git -C .hive-state diff --cached --name-only
git -C .hive-state diff --name-only --diff-filter=U
# Continue with clean worktrees/index and an existing default_workflow: bench.
hive --version
bench_old_state=$(git -C .hive-state rev-parse HEAD)
git -C .hive-state log -1 --format=fuller
sha256sum .hive-state/bench-runtime/harness/lib/isolation.sh \
  .hive-state/bench-runtime/harness/lib/isolation_exec.rb
hive init . --workflow bench
bench_refresh=$(git -C .hive-state rev-parse HEAD)
git -C .hive-state show --stat --format=fuller "$bench_refresh"
git -C .hive-state diff "$bench_old_state" "$bench_refresh" -- . ':!bench-runtime'
sha256sum .hive-state/bench-runtime/harness/lib/isolation.sh \
  .hive-state/bench-runtime/harness/lib/isolation_exec.rb
git -C .hive-state status --short
```

On macOS use `shasum -a 256` in place of `sha256sum`. Record the old state OID,
Hive version/source revision, new refresh commit and old/new hashes. Compare the
new hashes with the corrected package's `harness/lib/isolation.sh` and
`isolation_exec.rb` (or the runtime-byte hashes in the delivery evidence).
The diff excluding `bench-runtime` must be empty. An already-current runtime
may produce no commit. If a refresh contains unrelated changes, inspect them
before treating it as the isolated commit described below.

## Recover by reverting only the runtime refresh

If the declaration misfires, inspect the recorded commit and current state
before reverting. Resolve or save unrelated work and conflicts first. Confirm
the recorded commit changes only `bench-runtime/` and is the intended refresh:

```bash
git -C .hive-state status --short
git -C .hive-state diff --name-only --diff-filter=U
git -C .hive-state show --stat --format=fuller "$bench_refresh"
git -C .hive-state diff-tree --no-commit-id --name-only -r "$bench_refresh"
# Continue only when every changed path is under bench-runtime/.
git -C .hive-state revert --no-edit "$bench_refresh"
git -C .hive-state log -1 --format=fuller
sha256sum .hive-state/bench-runtime/harness/lib/isolation.sh \
  .hive-state/bench-runtime/harness/lib/isolation_exec.rb
git -C .hive-state diff "$bench_old_state" HEAD -- bench-runtime
git -C .hive-state status --short
```

If later runtime edits cause conflicts, stop and resolve them deliberately;
`git -C .hive-state revert --abort` cancels an unresolved revert. Verify the
restored hashes equal the recorded old hashes and unrelated state is preserved.
Rollback restores the earlier credential posture as an explicit operator
recovery action. The new implementation has no forward-all fallback.
