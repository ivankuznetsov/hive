# Releasing hive

Hive ships the `hive-cli` rubygem and managed `hive-web-X.Y.Z.tar.gz` bundle in
one signed GitHub Release. All three native install channels download the same
gem, and `hive setup` authenticates and installs the matching web bundle:

- **install.sh** — already works; auto-resolves the latest release.
- **Homebrew** — `brew install ivankuznetsov/hive/hive` via the
  [`ivankuznetsov/homebrew-hive`](https://github.com/ivankuznetsov/homebrew-hive) tap.
- **AUR** — `yay -S hive-bin` (or `paru -S hive-bin`).

A maintainer's explicit `vX.Y.Z` tag triggers `.github/workflows/release.yml`.
The workflow requires no model-provider credentials. On GitHub-hosted runners,
it proves the exact tag candidate as follows:

1. Builds `hive-web-X.Y.Z.tar.gz` once from the tracked `web/` tree and records
   its SHA-256 before the candidate or install gates run.
2. Builds one gem, source archive, and deterministic OpenClaw/Claude/Codex/Pi
   skill archive from the exact tag commit. The candidate verifier checks the
   manifest digests and compares every packaged projection byte-for-byte with
   the canonical skill source, then installs and invokes that exact gem.
3. Installs the proven gem against the exact web archive through
   consent-approved managed `hive setup --no-init --yes --json` under inert
   service-manager stubs. It never rebuilds the candidate after this gate.
4. Gem-installs the exact proven gem on macOS and native arm64 Linux.
5. Creates and cosign-signs `SHA256SUMS` for the proven gem, four-platform
   skill archive, and the already-proven web archive. `release-finalize`
   publishes those same web bytes; it never rebuilds them. The GitHub Release
   contains those assets and `SHA256SUMS{,.sig,.pem}`.
6. Dispatches a `hive-release` `repository_dispatch` to the Homebrew tap
   (gated on `HOMEBREW_TAP_TOKEN`).
7. Runs the `aur-publish` job (gated on `AUR_SSH_PRIVATE_KEY`): cosign-verifies
   the released gem, renders `PKGBUILD` from `packaging/aur/PKGBUILD.template`
   via `packaging/render.rb`, regenerates `.SRCINFO` with
   `makepkg --printsrcinfo`, and pushes a version bump to the AUR package.
8. Announces the release on Discord with the supported `hive update` command
   when `DISCORD_RELEASE_WEBHOOK` is configured. Announcement failures are
   non-fatal and do not block package publication.

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
full protected-main commit. The tag drives the exact offline candidate and
native install gates in `release.yml` (above). The owner bypasses the `v*`
tag-protection ruleset.

**CHANGELOG style:** newest-first `## X.Y.Z` sections with user-facing `-`
bullets (prefix fixes with "Fixed"); no `[Unreleased]` accumulator and no dates
— the git tag carries the date. Use descriptive `###` category subheadings for
notable minor/major releases; keep routine patch releases terse. A release with
nothing user-facing gets a one-line "no user-facing changes" note.

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

- `live-agent-skills-openclaw`: `OPENAI_API_KEY` and environment variable
  `HIVE_LIVE_MODEL` naming its OpenClaw model.
- `live-agent-skills-claude`: `ANTHROPIC_API_KEY` and a Claude-compatible
  `HIVE_LIVE_MODEL`.
- `live-agent-skills-codex`: `CODEX_API_KEY` and a Codex-compatible
  `HIVE_LIVE_MODEL`.
- `live-agent-skills-pi`: `ANTHROPIC_API_KEY` and an Anthropic-compatible
  `HIVE_LIVE_MODEL`.

Use dedicated low-privilege test credentials and environment reviewers when
appropriate. Provider credentials are exposed only to the authenticated proof
step, not checkout, npm, Bundler, artifact, or attestation steps. The harness
passes only the selected platform's credential into its disposable child
environment, never copies host auth state, retains no model prose, scans raw
process output before redaction, and removes the private home before success.

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

4. After the separate explicit release decision, tag that exact commit and
   push (this is the irreversible public trigger):

   ```sh
   test "$(git rev-parse HEAD)" = "$candidate_sha"
   git tag vX.Y.Z "$candidate_sha"
   git push origin vX.Y.Z
   ```
5. Watch the run: **web-bundle → candidate-gate → install-gate → release-finalize →
   aur-publish**. Confirm:
   - `web-bundle` built the managed archive once and exposed its exact digest.
   - `candidate-gate` built the tag exactly once, verified all four canonical
     skill projections and manifest digests offline, installed and invoked the
     exact gem, then exercised managed setup against the digest-pinned web
     candidate under the isolated service-manager harness.
   - The GitHub Release has `hive-cli-X.Y.Z.gem`, the four-platform Hive skill
     archive, `hive-web-X.Y.Z.tar.gz`, and `SHA256SUMS{,.sig,.pem}`.
   - The tap committed `Formula/hive.rb` at `X.Y.Z` (if `HOMEBREW_TAP_TOKEN` is set).
   - `https://aur.archlinux.org/packages/hive-bin` shows `X.Y.Z` (if `AUR_SSH_PRIVATE_KEY` is set).
6. Smoke each channel:

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

CI does **real installs** of every channel on its native OS (no macOS/Ubuntu
hardware needed — GitHub-hosted runners + containers). Three layers, all backed
by `packaging/verify-channel.sh` and the reusable `.github/workflows/install-verify.yml`:

1. **Exact-artifact candidate gate** (`candidate-gate` in `release.yml`) —
   checks out the exact tag, runs the offline canonical-skill contracts, builds
   one gem/source/four-platform skill candidate, verifies every manifest digest
   and projected file against canonical source, then installs and invokes the
   exact gem. `web-bundle` builds the tracked managed web archive once before
   this gate; the gate digest-checks it and runs the installed candidate through
   managed setup. No downstream job rebuilds the proven candidate.
2. **Pre-release install gate** (`install-gate` in `release.yml`) — `gem
   install`s the exact proven gem on `macos-15` + `ubuntu-24.04-arm` before
   publishing. `release-finalize` needs it, so a gem that will not install never
   reaches brew/AUR. Native runners only.
3. **Post-release verification** (`post-release-verify` in `release.yml`) — after
   publish, runs the **real** `brew install` / `yay -S hive-bin` / `install.sh`
   of the just-released version.
4. **Weekly canary** (`install-canary.yml`, Mondays 06:00 UTC + `workflow_dispatch`)
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

- **`candidate-gate` reports projection drift** → regenerate the checked-in
  projections from `skills/hive/`, inspect the diff, and rerun the focused
  agent-skill tests. Do not edit a generated projection directly.
- **`candidate-gate` reports a version mismatch** → the tag, `Hive::VERSION`,
  gem filename, and installed `hive --version` must all name the same version.
- **Optional live-agent job skipped** → its protected environment lacks the
  provider credential/model configuration. This does not block a release; use
  the offline candidate gate when no provider keys are available.
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
