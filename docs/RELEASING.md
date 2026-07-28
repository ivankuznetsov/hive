# Releasing hive

Hive ships the `hive-cli` rubygem and managed `hive-web-X.Y.Z.tar.gz` bundle in
one signed GitHub Release. All three native install channels download the same
gem, and `hive setup` authenticates and installs the matching web bundle:

- **install.sh** — already works; auto-resolves the latest release.
- **Homebrew** — `brew install ivankuznetsov/hive/hive` via the
  [`ivankuznetsov/homebrew-hive`](https://github.com/ivankuznetsov/homebrew-hive) tap.
- **AUR** — `yay -S hive-bin` (or `paru -S hive-bin`).

## Releasing `agent-cli-runtime`

`agent-cli-runtime` is independently versioned inside this monorepo. Its
release does not bump, tag, publish, or deploy Hive. Development stays under
`components/agent-cli-runtime/`; Hive remains the primary consumer, and the
released package is installed from RubyGems by downstream consumers.

One-time account setup:

1. Create an active GitHub tag ruleset targeting
   `components/agent-cli-runtime/v*`. Restrict tag creation, update, and
   deletion to the release maintainers, keep the bypass list equally narrow,
   and do not rely on the broader Hive `v*` rule to cover component tags.
2. Create the GitHub environment `agent-cli-runtime-release`. Require at least
   one release-maintainer reviewer, prevent self-review where the repository
   plan supports it, and restrict deployments to tags matching
   `components/agent-cli-runtime/v*`. Those tags are separately protected by
   the component tag ruleset. This environment is the final human approval
   boundary before RubyGems OIDC is issued.
3. Before the first publication, configure a RubyGems pending trusted publisher
   with exactly:

   - gem: `agent-cli-runtime`
   - repository owner: `ivankuznetsov`
   - repository name: `hive`
   - workflow: `agent-cli-runtime-release.yml`
   - environment: `agent-cli-runtime-release`

The environment and workflow names are part of the OIDC identity. Do not add a
long-lived RubyGems API key to GitHub. Before accepting the first component
release as ready, verify the component tag ruleset and environment protection
in repository settings; a protected `main` branch alone is insufficient.

To publish an approved version:

1. Update
   `components/agent-cli-runtime/lib/agent_cli_runtime/version.rb` and its
   package changelog in a package PR. Run the package tests and exact candidate
   verifier.
2. Merge the package PR while leaving `hive.gemspec`, Hive's lockfiles, and
   Hive's dependency loading unchanged. During the temporary duplication
   window, any contract correction shared with Hive's internal implementation
   must land in lockstep and remain covered by package/Hive parity tests.
3. Record the full protected-`main` commit and verify that the version is not
   already present on RubyGems. Confirm the component tag ruleset is active and
   that `agent-cli-runtime-release` still requires the intended reviewers and
   permits only matching component tags.
4. Create and push
   `components/agent-cli-runtime/vX.Y.Z` at that exact commit. The component
   workflow rejects malformed tags, version mismatches, dirty candidates, and
   commits not reachable from `main`.
5. Watch **candidate → install (Linux and macOS) → publish**. Only `publish`
   receives an OIDC token. It downloads the previously built candidate,
   revalidates its checksum, and pushes those exact bytes without rebuilding.
   The candidate is retained for 30 days so an approval delay does not silently
   replace it with rebuilt bytes; every job has a 15-minute execution timeout.
6. From a fresh gem home, install `agent-cli-runtime` at the exact version,
   require `agent_cli_runtime`, run `agent-runtime --version`, and exercise a
   JSON probe. Compare the downloaded gem checksum and metadata with the
   workflow candidate before allowing a Hive dependency cutover.

Ordinary path changes and Hive `vX.Y.Z` tags cannot publish this package.
Component tags cannot enter Hive's root release workflow. If the workflow fails
before `gem push`, fix the source or release machinery and move the component
tag only while no registry version exists. If RubyGems accepted the version,
never overwrite or reuse it: keep Hive's cutover blocked and prepare a
separately approved fix-forward version. Yanking or transferring ownership
requires separate explicit authorization.

### Distribution mirror

[`ivankuznetsov/agent-cli-runtime`](https://github.com/ivankuznetsov/agent-cli-runtime)
is a public, read-only distribution mirror. It gives the gem a focused
description, topics, source browser, and release history without splitting
development across repositories. Hive remains the canonical source, issue
tracker, pull-request surface, and release authority.

The mirror's `main` branch is synchronized one way from
`components/agent-cli-runtime/` by **Sync from Hive monorepo**, on a six-hour
schedule or manual dispatch. Each snapshot records its exact canonical
component commit in `.mirror-source.json`. The sync excludes the component's
`mirror/` administration directory from the public package tree and installs
the canonical workflow, contribution, and security files. The workflow
executes the projector from the canonical Hive checkout, so projector and
administration changes take effect atomically.
New mirror-only administration must first be added to the canonical
`mirror/` allowlist in Hive; unsourced target-only files are removed. Any
missing canonical admin file fails before mutating the mirror.

Both mirror workflows use the repository-scoped private deploy key in the
`MIRROR_DEPLOY_KEY` Actions secret for Git pushes. Its public half must be a
write-enabled deploy key on `ivankuznetsov/agent-cli-runtime`, and the private
half must not be reused by any other repository. This credential is required
because GitHub's generated `GITHUB_TOKEN` cannot update files under
`.github/workflows`, even with `contents: write`. The sync otherwise keeps its
generated token read-only; the release workflow uses that short-lived token
only for ruleset inspection and GitHub release creation.

After an approved component version has been published from Hive, manually run
**Mirror a component release** in the mirror with `vX.Y.Z`. The workflow checks
out the fully qualified protected
`refs/tags/components/agent-cli-runtime/vX.Y.Z` ref and runs the component's
release preflight against canonical `main`. It then verifies the exact version
is already available from RubyGems and constructs an orphan source snapshot
locally. An independent Git archive of the canonical tag, excluding only
`mirror/` and adding the source manifest, defines the expected tree. The
projected tree must match it before the workflow builds and installs the gem and
exercises `agent-runtime --version`. Only then does it push the mirror tag and
create the GitHub release. Existing mirror tags are accepted only when their
complete tree matches the independently reconstructed canonical snapshot.

The mirror repository must have the `MIRROR_DEPLOY_KEY` credential described
above and an active tag ruleset targeting `refs/tags/v*` that restricts updates
and deletion and blocks non-fast-forward movement. Leave initial creation
available to the verified workflow; never add a bypass that can replace an
existing release tag. The workflow checks the live ruleset through the GitHub
API and refuses to create a local release tag when the immutable-tag policy is
absent.

The mirror workflow never pushes to Hive or RubyGems and cannot choose or
publish a version. Do not accept issues, pull requests, independent commits, or
release decisions there. Changes flow through Hive first; running the mirror
jobs is a distribution follow-up, not release authority. Both mirror workflows
pin third-party Actions to reviewed commit SHAs.

## Hive pre-release proof and tag handoff

Hive builds and proves release bytes before a tag exists. From a clean checkout
of the intended protected-`main` commit, first inspect the exact candidate:

```sh
candidate_sha="$(git rev-parse origin/main)"
bin/hive-release-candidate plan --sha "$candidate_sha" --json
```

`plan` is read-only. It reports deterministic blockers, the exact local run
command, release-asset fetch argv, and—when required—the reviewed offline-cache
materialization argv. The closure inventories under
`packaging/release_candidate/baseline_manifests/` pin every RubyGem filename,
size, and SHA-256. Execute only the returned `baseline_cache.fetch_argv[]`; the
materializer stages those bytes before historical code runs with networking
disabled.

The reviewed materializer entry has this shape (copy the plan's exact argv,
including its resolved Ruby and cache root):

```sh
ruby packaging/release_candidate/materialize_baseline_cache.rb \
  "$candidate_sha" \
  "$PWD/tmp/release-candidates/baseline-cache"
```

At the time of this implementation, the source version and reviewed
latest-stable baseline are both 0.6.9. That exact source must report
`candidate_not_newer` and cannot produce `qa_ready` evidence. Preparing a newer
version is a separate reviewed release-prep change; the candidate tool never
chooses or bumps it.

`run`, `resume`, and `rerun` create only local, append-only evidence under
`tmp/release-candidates/<sha>/`. A passing local scope remains `qa_blocked`.
The default local CLI does not run a production historical container lane:
those gates report `compliant_local_upgrade_executor_unavailable` and point to
the exact hosted dispatch. The fixed executor is injectable for focused tests;
real blocking upgrade proof belongs to the trusted hosted workflow.
Only `dispatch` writes to GitHub; the following `collect` is read-only:

```sh
bin/hive-release-candidate dispatch --sha "$candidate_sha" --json
bin/hive-release-candidate collect --request "$request_id" \
  --wait --timeout 7200 --json
```

The trusted `.github/workflows/release-candidate.yml` run requires no
model-provider credentials. It builds one manifest-bound gem, committed-source,
four-platform skill, and managed-web candidate before fan-out; runs the release
semantic E2E profile, packaging and managed-web checks, three native installs,
latest-stable upgrades on all supported platforms, the v0.4.1→v0.4.2→candidate
historical lane, baseline freshness/version checks, and exact protected
ordinary CI; then publishes digest-bound `trusted_remote` evidence and a
`hive-release-candidate` Check Run. Missing, duplicate, skipped, cancelled,
failed, stale, or substituted deterministic rows block QA. Authenticated
OpenClaw/Claude/Codex/Pi proof is advisory only and cannot replace a required
row. Each blocking cell rejects candidate-controlled harness drift against the
protected-main control checkout before execution. Linux historical lanes run
in digest-pinned, unprivileged, read-only containers with no network or
capabilities; macOS uses a deny-network sandbox. Both expose only read-only
trusted-control/cache roots and one writable run root.

Targeted retries preserve the original candidate bytes and predecessor rows:

```sh
bin/hive-release-candidate dispatch \
  --retry-workflow-run "$source_run_id" \
  --retry-attempt "$source_run_attempt" \
  --failed --json
```

Use exactly one of `--failed`, `--missing`, or repeated
`--gate "Required display name"`. The retry's evidence run/attempt is distinct
from the original candidate artifact producer run/attempt/name/ID/digest; both
identities are revalidated through chained retries.

A maintainer's separately authorized `vX.Y.Z` tag triggers
`.github/workflows/release.yml`. Its first `select-candidate` job:

1. Resolves the tag target and selects exactly one successful, digest-bound
   candidate Check for that SHA.
2. Revalidates the protected-main workflow/run/attempt, required jobs, ordinary
   CI, action lock, retry lineage, terminal evidence archive, and original
   candidate artifact.
3. Verifies the downloaded Actions archive digests, safely extracts them, and
   confirms the manifest, source/tag version, and latest-stable comparison.
4. Restages only the exact manifest-bound gem, skill, and managed-web bytes.
   The tag workflow has no gem/source/skill/web build and no fallback dispatch.

`install-gate` installs those selected gem bytes natively before
`release-finalize` creates and cosign-signs `SHA256SUMS`, publishes the exact
gem/skill/web bytes, dispatches Homebrew when configured, and announces on
Discord when configured. The existing AUR, multi-architecture Hivebox, and
post-release verification graph remains downstream.

Implementation status: no real hosted candidate workflow, native-platform
matrix, or historical package lane was run while adding this machinery. No
version choice, tag, publication, deployment, or release was authorized.

Both channel templates render through one helper (`packaging/render.rb`), so a
release's version/sha is substituted identically everywhere.

---

## Versioning policy

Hive follows [SemVer](https://semver.org) `MAJOR.MINOR.PATCH` and ships **frequent
micro-releases**, modeled on Claude Code's cadence (which patch-bumps multiple
times a day). The bias is to release small and often, not to batch changes into
big versions.

- **PATCH** (`0.1.3` → `0.1.4`) — the common case. Bug fixes, small changes, doc
  updates, packaging/CI tweaks. Cut one freely for nearly any merged change;
  don't agonize over whether a release is "worth it," and don't worry about
  churn (two patches minutes apart is fine). Gaps in the patch sequence are fine
  too — a tag that fails to publish is simply superseded by the next.
- **MINOR** (`0.1.x` → `0.2.0`) — a notable feature or a batch of them.
- **MAJOR** (`0.x` → `1.0.0`) — milestones / intentional breaking changes. Hive
  is pre-1.0; `1.0.0` is reserved for when the CLI/JSON contracts are declared
  stable.

**How to cut a release:** bump `VERSION` in `lib/hive.rb`, sync **both**
`Gemfile.lock` and `web/Gemfile.lock` (`hive-cli (X.Y.Z)` — Hive web
depends on the gem via `path: ".."` in a source checkout, so a stale web lock fails its frozen
`bundle install`), bump the `vX.Y.Z` installer-URL refs in `README.md` /
`install.md`, add a `## X.Y.Z` CHANGELOG section, and merge the release-prep PR.
Only a separate explicit release decision should create/push `vX.Y.Z` on the
full protected-main commit, after trusted pre-tag candidate evidence is
`qa_ready`. The tag selects and republishes those exact bytes; it does not
rebuild them. The owner bypasses the `v*` tag-protection ruleset.

**CHANGELOG style:** newest-first `## X.Y.Z` sections with user-facing `-`
bullets (prefix fixes with "Fixed"); no `[Unreleased]` accumulator and no dates
— the git tag carries the date. Use descriptive `###` category subheadings for
notable minor/major releases; keep routine patch releases terse. A release with
nothing user-facing gets a one-line "no user-facing changes" note.

### Workflow-creator public wording

The canonical skill may describe current-main behavior because its generated
projections and candidate artifacts are pinned to the same source commit. Do
not describe current-main workflow-creator commands as stable on hivecli.sh,
ClawHub, or release announcements until a separately authorized release
containing those commands is published. Stable-user wording should name the
containing release or tell users to run the supported `hive update` path after
that release exists.

The downstream wording handoff is tracked as `hive-site #23116`. It does not block this repository.
Implementation, tests, and release readiness proceed independently, and this
repository must not mutate or deploy hive-site as part of that coordination.

---

## One-time setup

Do these **once**, before relying on the automated channels. They are the
irreducibly-human steps (accounts, keys, secrets) that an agent cannot perform.

### 1. Tag-protection rule (do this first)

A `vX.Y.Z` tag now auto-publishes a cosign-signed artifact to **both**
Homebrew and AUR. Restrict who can push `v*` tags so a stray or hostile tag
cannot mint a release that propagates to users.

- GitHub → repo **Settings → Rules → Rulesets → New tag ruleset**.
- Target tags matching `v*`.
- Restrict creation/update to maintainers (bypass list = you).

> Signed git tags (`git tag --verify` against a maintainer key in the workflow)
> remain a separate, deferred hardening. Tag protection is the compensating
> control until then.

### 2. Optional live-agent diagnostics

Releases do not require provider keys or these environments. Maintainers who
want an additional authenticated native-agent diagnostic may create four
GitHub environments restricted to protected `main` workflow runs:

- `live-agent-skills-openclaw`: environment variable `HIVE_LIVE_MODEL` beginning
  with `openai/` or `openrouter/`, plus only the matching `OPENAI_API_KEY` or
  `OPENROUTER_API_KEY` secret.
- `live-agent-skills-claude`: `ANTHROPIC_API_KEY` and a Claude-compatible
  `HIVE_LIVE_MODEL`.
- `live-agent-skills-codex`: `CODEX_API_KEY` and a Codex-compatible
  `HIVE_LIVE_MODEL`.
- `live-agent-skills-pi`: `ANTHROPIC_API_KEY` and an Anthropic-compatible
  `HIVE_LIVE_MODEL`.

Use dedicated low-privilege test credentials and environment reviewers when
appropriate. The OpenClaw creator job derives the provider from the model
prefix and maps the selected secret into the runner's single generic credential
input; neither the opposite named secret nor the generic input reaches the
OpenClaw child. Provider credentials are exposed only to the authenticated
proof step, not checkout, npm, Bundler, artifact, or attestation steps. The
harness never copies host auth state, retains no model prose, scans every raw
process-output byte before redaction, strips selected/opposite/generic provider
credentials before every candidate invocation, and uses a Linux child-subreaper
in an independently live containment owner to terminate and reap process-group
escapes, `setsid` descendants, and double-forks even when the fault-injected
worker is stopped or killed. Parent/owner/worker IPC is length-bounded JSON
framing with strict typed keys and Base64 binary streams; malformed, truncated,
oversized, or trailing frames fail closed.

The creator proof installs exact OpenClaw `2026.7.1-beta.2` under Node
`22.23.1` with `npm ci` from the committed lockfile. The lock is a closed
306-package inventory: every non-root entry has an exact registry URL and
SHA-512 integrity, the OpenClaw entry matches the reviewed SRI, and install
scripts are disabled. Typed receipts bind each complete entry-bounded,
read-only installed tree, the executable and artifact, and the realpath,
digest, and version of every invoked interpreter. This covers OpenClaw's
imported dependency bytes and the candidate's outer launcher, RubyGems inner
launcher, and installed gem bytes. The runner revalidates those identities
immediately before and after relevant executions. OpenClaw is always invoked
as the receipt-bound Node interpreter realpath followed by the executable
realpath, including the pinned package's `#!/usr/bin/env node` launcher form.

The runner materializes the candidate skill archive with shared byte, entry,
directory, depth, and inode budgets, creates a disposable project, and exposes
a distinct digest-bound audit gateway through OpenClaw's native
`tools.exec.pathPrepend`. OpenClaw's exact runtime must resolve only
`apply_patch`, `edit`, `exec`, `read`, and `write`; filesystem and apply-patch
writes are workspace-only, while the exec approval file allows only the
gateway executable. A digest-bound committed driver parses configuration with
the public `openclaw/plugin-sdk/config-schema` export and constructs tools with
the public `openclaw/plugin-sdk/agent-harness` export. It executes native
inside-workspace read/write/edit/apply-patch controls, the allowed `hive
version` exec, and unchanged-sentinel denials for outside write/edit/apply-patch
plus absolute, redirected, and chained exec attempts. The receipt records the
pinned beta's outside-read skill-root caveat instead of claiming a global read
denial. A deterministic fake may drive CLI orchestration, but workflow
authoring still uses this exact native tool surface and explicitly records that
it did not exercise a model loop. The live creator prompt fixes the four
creation commands and requires removal of unused neutral-scaffold files before
validation, so a passing model run retains only the accepted descriptor plus
research and draft instructions. The inspector safe-loads that descriptor and
binds its exact normalized editorial semantics, including the intentional
absence of stage-level `agent` and `model` keys. The first task run therefore
inherits the disposable project's Claude configuration. A proof-owned,
credential-free Claude executable outside the workspace accepts only that
single research-stage argv and bounded prompt, writes a deterministic nonempty
`research.md` ending in one `<!-- COMPLETE -->`, and emits a one-shot receipt
binding its executable, prompt, argv, before/after artifact digests, task slug,
and invocation count. Attestation independently binds the descriptor,
fixture, and completed artifact; the fixture proves provider inheritance and
real stage orchestration without claiming a second remote model call.
Candidate command failures are retained as bounded structured receipts rather
than raw stderr. The gateway allows exactly nine semantic Hive
commands, holds one serialized audit
transaction through candidate completion, and runs from a committed six-file
runtime whose exact copied bytes plus immutable config are SHA-256-bound by the
small launcher and retained in evidence. Before admission checks or candidate
launch it appends and fsyncs an immutable `attempted` row; success, denial, or
failure appends a matching `terminal` row with the same deterministic attempt
ID. Any
malformed pair, pending attempt, or denied/failed terminal poisons the session
before another candidate launch. Success therefore means nine successful
pairs (18 rows), no extras or pending attempts, and attempt-bound result rows.
Those deterministic IDs detect corruption, truncation, and broken pairing;
they are not authenticity evidence against a coherent same-UID rewrite. The
separate result reader rejects links, malformed or extra rows, type drift,
wrong order, and mismatched attempt IDs under bounded reads. Before ordinal 7
can launch, ordinal 6 must have succeeded with `created=true`, and one
symlink-free, bounded task metadata record must bind its exact safe slug,
`editorial` workflow, and proof idempotency key.

The inspector derives `unauthorized_effects_observed` from independently
retained filesystem mutation receipts, effective policy decisions, and
prohibited-action controls over enumerated authorization surfaces. Raw socket
snapshots remain in process/effect evidence as `unattributed_agent_window` or
`unattributed_process_window`; destination identity and authorization are
unverified, so network is explicitly an observed-but-unadjudicated surface and
is not folded into that authorization verdict. The compatibility
`external_actions` field is the same scoped derived value and never claims
global effect absence. Missing observation fails closed. Before any artifact
download, extraction, lock/npm install, binary or
version check, receipt, or Bundler preflight, a packaging-owned workflow driver
creates the schema-v1 evidence file. Each ordinary preparation partition
updates that same redacted artifact, the proof runner inherits its preparation
receipts, an `always()` finalizer closes non-terminal evidence, and the smoke
test remains a thin adapter with no substitute Hive.

The optional workflow refuses a non-main dispatch, a workflow revision not
loaded from `refs/heads/main`, a
non-full SHA, a candidate not reachable from `origin/main`, or an unprotected
main branch.

### 3. Homebrew tap

The tap repo already exists and is seeded:
[`ivankuznetsov/homebrew-hive`](https://github.com/ivankuznetsov/homebrew-hive)
(`Formula/hive.rb` for v0.1.0 + `.github/workflows/update-formula.yml`, with
default workflow permissions set to write). Installs already work without any
secret.

To enable **auto-update on future releases**, create the dispatch token:

1. GitHub → **Settings → Developer settings → Fine-grained tokens → Generate**.
   - **Resource owner:** `ivankuznetsov`.
   - **Repository access:** *Only select repositories* → `homebrew-hive` **only**.
   - **Permissions:** Repository → **Contents: Read and write**. (GitHub's
     `repository_dispatch` API requires Contents write — it cannot be scoped
     narrower. The mitigation is the single-repo scope + a short expiry, not a
     lesser permission.)
   - **Expiration:** short (e.g. 90 days); renew on a calendar reminder.
2. Add it as a secret on the **hive** repo:

   ```sh
   gh secret set HOMEBREW_TAP_TOKEN -R ivankuznetsov/hive
   ```

If `HOMEBREW_TAP_TOKEN` is unset, the release still succeeds — the dispatch
step is skipped with an audit log line, and the tap simply stays at its last
version until you bump it manually or set the token.

### 4. AUR account, key, and first bootstrap

1. **Account:** ensure you have an account on <https://aur.archlinux.org>.
2. **SSH key (dedicated to releasing):**

   ```sh
   ssh-keygen -t ed25519 -C "hive-aur-release" -f ~/.ssh/hive_aur_ed25519
   ```

   Add the **public** key (`~/.ssh/hive_aur_ed25519.pub`) under AUR → *My
   Account → SSH Public Key*.
3. **Secret:** add the **private** key to the hive repo:

   ```sh
   gh secret set AUR_SSH_PRIVATE_KEY -R ivankuznetsov/hive < ~/.ssh/hive_aur_ed25519
   ```
4. **First bootstrap push (manual — claim the name and sanity-check on a real
   Arch box):**

   ```sh
   # On an Arch machine, with this hive checkout available:
   GIT_SSH_COMMAND='ssh -i ~/.ssh/hive_aur_ed25519' \
     git clone ssh://aur@aur.archlinux.org/hive-bin.git
   cd hive-bin

   # Render the PKGBUILD for the current release (use the verified gem sha
   # from that release's SHA256SUMS):
   ver=0.1.0
   sha=$(curl -fsSL "https://github.com/ivankuznetsov/hive/releases/download/v${ver}/SHA256SUMS" \
          | awk '/hive-cli-/ {print $1}')
   ruby /path/to/hive/packaging/render.rb \
     /path/to/hive/packaging/aur/PKGBUILD.template \
     "version=${ver}" "sha256_gem=${sha}" > PKGBUILD
   cp /path/to/hive/packaging/aur/hive.install .
   makepkg --printsrcinfo > .SRCINFO

   # Verify it actually builds and installs before publishing:
   makepkg -si

   git add PKGBUILD .SRCINFO hive.install
   git commit -m "hive-bin ${ver}"
   git push
   ```

   After this first push, `release.yml`'s `aur-publish` job maintains the
   package automatically on each tag.

---

## Cutting a release

1. Bump the version in `lib/hive.rb` (`VERSION = "X.Y.Z"`) and update
   `CHANGELOG.md`, both lockfiles, and pinned installer URLs.
2. Commit, open a PR, merge to `main`.
3. Record the full merged commit and confirm the release metadata matches it:

   ```sh
   candidate_sha="$(git rev-parse origin/main)"
   test "$(git rev-parse HEAD)" = "$candidate_sha"
   test "$(ruby -Ilib -e 'require "hive"; print Hive::VERSION')" = "X.Y.Z"
   ```

4. Inspect/materialize the reviewed inputs from the exact plan, then dispatch
   and collect the pre-tag proof:

   ```sh
   bin/hive-release-candidate plan --sha "$candidate_sha" --json
   dispatch_json="$(
     bin/hive-release-candidate dispatch --sha "$candidate_sha" --json
   )"
   request_id="$(printf '%s' "$dispatch_json" | jq -er .request_id)"
   collect_json="$(
     bin/hive-release-candidate collect --request "$request_id" \
       --wait --timeout 7200 --json
   )"
   test "$(printf '%s' "$collect_json" | jq -r .status)" = terminal
   test "$(printf '%s' "$collect_json" | jq -r .conclusion)" = success
   ```

   Confirm the exact-SHA `hive-release-candidate` Check is completed/success
   and its retained evidence says `trust_scope: trusted_remote`,
   `qa_status: qa_ready`, with no blockers. A failed or expired proof requires
   a new full run or a provenance-preserving targeted retry—not a tag-time
   fallback.
5. Review the proof. Only after the separate explicit release decision, tag
   that exact commit and push (this is the irreversible public trigger):

   ```sh
   test "$(git rev-parse HEAD)" = "$candidate_sha"
   git tag vX.Y.Z "$candidate_sha"
   git push origin vX.Y.Z
   ```
6. Watch the run: **select-candidate → install-gate → release-finalize →
   downstream channel/image verification**. Confirm:
   - `select-candidate` chose the exact candidate Check/evidence and original
     artifact producer for the tag target, verified both archive digests, and
     restaged the exact manifest-bound gem, skill, and web bytes without a
     build or fallback dispatch.
   - `install-gate` installed the selected gem on `macos-15` and native arm64
     Linux before `release-finalize`.
   - The GitHub Release has `hive-cli-X.Y.Z.gem`, the four-platform Hive skill
     archive, `hive-web-X.Y.Z.tar.gz`, and `SHA256SUMS{,.sig,.pem}`.
   - The tap committed `Formula/hive.rb` at `X.Y.Z` (if `HOMEBREW_TAP_TOKEN` is set).
   - `https://aur.archlinux.org/packages/hive-bin` shows `X.Y.Z` (if `AUR_SSH_PRIVATE_KEY` is set).
7. Smoke each channel:

   ```sh
   brew install ivankuznetsov/hive/hive && hive --version    # macOS / Linuxbrew
   yay -S hive-bin && hive --version                          # Arch (test aarch64 too)
   ```

   Then run `hive setup --json` in the isolated verification environment and
   require the same package-root dependency and service-state contract as a
   normal install. The default release URL is trusted only after cosign
   verification of `SHA256SUMS` against `.github/workflows/release.yml` at the
   exact expected `vX.Y.Z` tag, followed by exact archive-digest verification. A
   custom remote `HIVE_WEB_BUNDLE_URL` must be paired with the documented exact
   `HIVE_WEB_BUNDLE_SHA256`; never weaken that requirement to diagnose a mirror.

---

## Install verification

CI does **real installs** on native OS runners and containers. Four layers feed
the release and channel graph:

1. **Trusted pre-tag candidate** (`release-candidate.yml`) — builds candidate
   bytes once, then blocks on the semantic release profile, packaging/managed
   web, native Linux x86_64/arm64 and macOS arm64 installs, authenticated
   latest-stable upgrades, the historical v0.4.1→v0.4.2→candidate survivor,
   baseline freshness/version, and exact ordinary CI. It publishes immutable
   evidence and a digest-bound Check Run; it does not tag or publish.
2. **Exact-byte tag selection** (`select-candidate` in `release.yml`) —
   revalidates the trusted evidence and candidate artifact by server ID/digest,
   verifies the manifest/source/tag/latest-stable contracts, and restages only
   exact public bytes. It never rebuilds or dispatches a candidate.
3. **Pre-publication install gate** (`install-gate` in `release.yml`) —
   `gem install`s the selected gem on `macos-15` and
   `ubuntu-24.04-arm` before publishing. `release-finalize` needs it, so a gem
   that will not install never reaches Homebrew/AUR.
4. **Post-release verification** (`post-release-verify` in `release.yml`) — after
   publish, runs the **real** `brew install` / `yay -S hive-bin` / `install.sh`
   of the just-released version.
5. **Weekly canary** (`install-canary.yml`, Mondays 06:00 UTC + `workflow_dispatch`)
   — re-installs the latest release to catch dependency / base-image drift.

The Hivebox image gate is daemon-deep: `packaging/docker/smoke.sh` waits for
Rails `/health`, then requires daemon-backed `/health?deep=1` to stay healthy
across the supervisor's ten-second fast-failure window before checking the
claimable login and owner gate. It probes deep health again afterward. This
prevents a web-healthy image with a missing or crashlooping CLI/daemon bundle
from receiving public versioned or `latest` tags.

Both architectures are fail-closed before public tagging. The amd64 and native
arm64 jobs push untagged content by digest, run the smoke against those exact
digests, and expose the proven digests as job outputs. Only after both jobs
succeed does `hivebox-image` create the versioned and `latest` multi-arch
manifest from those two immutable inputs; it never rebuilds between smoke and
promotion.

Any failure opens or updates a single **`install-failure`** GitHub issue (one
aggregation job, so no duplicate spam) naming the run. To check a specific
version on demand:

```sh
gh workflow run install-verify.yml -f version=vX.Y.Z
```

The local end-to-end verifier prepends inert `systemctl`/`launchctl` stubs
inside its isolated prefix. Changing `HOME` confines unit files but does not
isolate the live per-user service manager; the stubs keep verification from
starting, stopping, enabling, disabling, or restarting the operator's actual
Hive services while preserving unit rendering and lifecycle assertions.

Scope note: aarch64 covers `install.sh` (`ubuntu-24.04-arm`) and macOS (arm64);
aarch64-AUR is deferred (the official `archlinux` image is x86_64-only — needs an
Arch-Linux-ARM image).

---

## Troubleshooting

- **Candidate package verification reports projection drift** → regenerate the checked-in
  projections from `skills/hive/`, inspect the diff, and rerun the focused
  agent-skill tests. Do not edit a generated projection directly.
- **`candidate_not_newer`** → the prepared `Hive::VERSION` must be newer than
  the reviewed `latest_stable` catalog row. Do not edit the baseline or choose
  a version merely to clear this blocker; use the separately reviewed
  release-prep change.
- **`select-candidate` cannot find trusted proof** → do not add a tag-time
  build or dispatch fallback. Verify the tag target SHA, candidate Check
  external ID/evidence digest, 30-day artifact retention, workflow/action lock,
  exact ordinary CI, and original artifact producer identity. Dispatch or
  target-retry the pre-tag workflow before the explicit tag decision.
- **`select-candidate` reports a version mismatch** → the tag,
  `Hive::VERSION`, candidate manifest/source archive, gem filename, and
  installed `hive --version` must all name the same version.
- **Optional live-agent job skipped** → its protected environment lacks the
  provider credential/model configuration. This is advisory and does not block
  deterministic candidate proof.
- **AUR job skipped** → `AUR_SSH_PRIVATE_KEY` is unset, or `release-finalize`
  failed before its `aur_gate` step. Set the secret / re-run the release.
- **Tap not updated** → `HOMEBREW_TAP_TOKEN` is unset or expired. Renew the PAT
  and re-set the secret; the tap stays at its last version meanwhile.
- **`cosign verify-blob` fails in `aur-publish`** → the released gem's signing
  identity didn't match the pinned release workflow and version tag. This is the supply-chain gate
  working; do **not** loosen the `--certificate-identity-regexp`. Investigate
  the release artifact.
- **`Host key verification failed` in `aur-publish`** → the AUR SSH first-contact
  trust path failed before key authorization. The job intentionally uses
  `StrictHostKeyChecking=accept-new` for CI TOFU: host identity checking stays
  enabled, the first key is recorded in `~/.ssh/known_hosts`, and later changes
  still fail closed. A missing or invalid `AUR_SSH_PRIVATE_KEY` fails later as
  `Permission denied (publickey)`.
- **Re-running a tag** → both publish paths are idempotent (a no-op when the
  channel is already at that version), so re-runs are safe.
- **`aarch64` AUR install fails** → a precompiled dependency gem may be missing
  for the resolved version, forcing a source compile. Until validated on
  `aarch64`, do not advertise the AUR channel as `aarch64`-ready.
