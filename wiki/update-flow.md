---
title: Update flow (daemon-driven version check + nudge)
type: feature
source: lib/hive/update_check.rb, lib/hive/update_check/state.rb, lib/hive/daemon/dispatcher.rb, lib/hive/bot/supervisor.rb, lib/hive/tui/bubble_model.rb
created: 2026-05-27
updated: 2026-11-02
tags: [architecture, daemon, bot, tui, update, decision]
---

**TLDR**: The daemon checks for releases and publishes an update nudge; it does
not install unattended. When an operator runs `hive update`, however, the
channel update and current-runtime validation are visibly reported. See [[commands/update]] and [[commands/migrate]].

## Pieces

- **`Hive::UpdateCheck.latest`** — probes `https://api.github.com/repos/ivankuznetsov/hive/releases/latest`, parses `tag_name`, compares to `Hive::VERSION`. Returns a `Result(current, latest, behind)` or `nil` on **any** failure (offline, rate-limit, malformed JSON, unparseable version). Never raises — the daemon calls it on a tick and must not crash.
- **`Hive::UpdateCheck::State`** — JSON state under `Paths.state_home/update_check.json`. Holds `last_check_at` (throttle), `last_notified_version` (de-dupe), and the active `nudge` payload (`latest`/`channel`/`command`). Atomic write, fail-closed load (corrupt JSON degrades to empty). A transient read error (EIO etc.) is *not* corruption: the last-known in-memory state is kept and writes are suspended (`:update_check_state_read_error`) until the next successful load, so a read-modify-write can never persist reset state over an intact file. **Shared across processes**: the daemon writes `nudge` + `last_check_at`; the bot writes `last_notified_version`; the TUI reads `nudge`. Every operation re-reads the file first so one process can't clobber another's keys with a stale in-memory copy.
- **Dispatcher integration** (`maybe_check_for_update`) — runs at the top of each `tick`, throttled by `state.due?`. Branches on `InstallChannel.detect`: `dev` → clear nudge + skip; brew/aur/bash → set the nudge with `Update.nudge_command(channel)` and log `:update_available`. Resilient: wrapped so an error logs `:update_check_error` and never breaks the tick. Runs only when an `update_state` is injected (the daemon does; unit tests stay inert/offline).
- **TUI footer** (`bubble_model.rb`) — reads `state.nudge` on a 10s TTL cache and prepends `update <ver>: <command>` to the hint line (prepended so truncation trims the hint, not the notice).
- **Bot push** (`supervisor.rb` `push_update_nudge`, called from `status_loop`) — reads `state.nudge`; if `should_notify?(latest)`, sends to the `chat_id_allowlist` and records notified **only after a delivery succeeds** (all-failed pushes retry next tick). Once per version.

## Config

`update.check` (default `true`) gates the whole probe. `update.auto` (default `true`) is reserved for the deferred bash auto-update — currently read but not yet consulted. Loaded via `Config.load_global_update`, validated as booleans.

## Channels

- **install.sh (bash)** — the daemon nudges `hive update`; that command re-runs the installer and then validates current runtime storage. Unattended daemon installation remains deferred to U7.
- **brew** — the daemon nudges `hive update`; the command runs brew followed by runtime validation.
- **aur** — the daemon nudges `hive update`; the command picks `yay` or `paru` at runtime and then runs runtime validation.
- **dev** — git clone; skipped entirely.

## Deferred (U7)

Bash auto-update from the daemon: drain in-flight work, run `hive update`, and
re-exec into the new version (idle = active-agent snapshot empty AND
`controller.in_flight_count == 0`). The foreground updater now waits for its
installer and validation subprocesses, but unattended daemon ownership and
restart proof still need a live systemd-user spike. Non-daemon users are also
not nudged in this scope.

## Backlinks

- [[state-model]] · [[modules/config]] · [[commands/update]] · [[architecture]] · [[decisions]]

## Known gaps

### Hive-site companion publication evidence

#### Source S25, lines 612–617: Current release gap

- The separately maintained `hive-site` source must mirror the native-first
  setup, foreground, opt-out, Windows/WSL, alias, and package contracts before
  website publication. This repository intentionally has no build-time import
  from that site, so its companion PR and rendered Jekyll/Pagefind verification
  remain external delivery evidence rather than Hive-source evidence.

### `hv` unsafe fallback-path removal is unit-pinned but not live-smoked.

#### Source S28, lines 796–796: Open questions about the codebase

19. **`hv` unsafe fallback-path removal is unit-pinned but not live-smoked.** Commit `00a8bca5` removed `/usr/bin/hive` and `/opt/hive/bin/hive` from `bin/hv`'s implicit candidate list so the fallback launcher does not accidentally exec Apache Hive from common system locations; `test/unit/hv_test.rb` covers the removed path strings and the `HIVE_BIN_OVERRIDE` custom-path escape hatch. This refresh did not find an in-tree artifact showing a live host with Apache Hive at one of those paths and the installed `hv` wrapper returning the new exit-127/custom-override behavior.

### v0.3.0 release prep is source-synced but not artifact-verified in-tree.

#### Source S28, lines 797–797: Open questions about the codebase

20. **v0.3.0 release prep is source-synced but not artifact-verified in-tree.** Commit `64b11b41` sets `Hive::VERSION` and `Gemfile.lock`'s path gem to `0.3.0`, adds the `CHANGELOG.md` release section for hivebox alpha, session-limit healing, dispatch-request/drop schema v2, golden-path E2E, and Windows installer harness coverage, and points README/install Linux installer snippets at `v0.3.0`. The committed `Gemfile.lock` diff changes only the local `hive-cli` path-gem version; no third-party dependency constraints or resolved versions changed. Commit `aa160a2c` hardens the pinned v0.1.0 install-smoke verifier's `jq` provisioning path, and PR #474's post-push GitHub Actions run `27500473396` passed `verify-release.sh (end-to-end behavior)` at that head. This refresh still did not find an in-tree artifact showing `packaging/verify-release.sh --version=v0.3.0`, channel verification against a published GitHub Release, Homebrew tap update, AUR package, or a published `ghcr.io/ivankuznetsov/hivebox:0.3.0` image after the tag exists.

### Release install follow-ups

#### Source S30, lines 928–940: Release install follow-ups

Latest refresh (2026-07-22): the source version and installer references are
prepared as v0.6.9. This release-prep branch does not itself prove a public tag,
signed assets, Homebrew/AUR updates, or ClawHub publication. The release boundary uses trusted pre-tag
candidate evidence plus exact-byte tag selection and does not require provider
credentials. The live post-release dogfood evidence
tracked below remains intentionally open until a separately authorized release
is published and installed.
Hivebox images are no longer built or published (ADR-055).
Dependency lock uncertainty is unchanged: the root bundle has
`concurrent-ruby` 1.3.7 and Brakeman 8.0.5, while `web/Gemfile.lock` resolves
`concurrent-ruby` 1.3.6 and Brakeman 8.0.4; release preparation synchronizes only the local
`hive-cli` path-gem version in that independently resolved web bundle.

### Release tag creation is protected, while signed git-tag verification remains deferred.

#### Source S30, lines 941–941: Release install follow-ups

1. **Release tag creation is protected, while signed git-tag verification remains deferred.** Homebrew and AUR publishing are implemented and public install docs route macOS users to the tap and Arch users to `yay -S hive-bin` (see ADR-032 in [[decisions]], `docs/RELEASING.md`, `README.md`, and `install.md`). The live repository has an active `v*` tag ruleset restricting creation, update, deletion, and non-fast-forward changes to the configured repository-role bypass. Release automation still publishes the commit selected by an authorized tag without independently verifying a maintainer cryptographic git-tag signature.

### macOS x86_64 install.sh support remains unsupported.

#### Source S30, lines 942–942: Release install follow-ups

2. **macOS x86_64 install.sh support remains unsupported.** Current `install.sh` still accepts only `darwin-arm64` on macOS and glibc Linux `x86_64`/`aarch64`; a future follow-up can add best-effort Rosetta behavior once the release smoke matrix covers it.

### Homebrew release-dispatch credential (0.7.3)

#### Source S80, lines 1750–1753: 0.7.3 distribution follow-up

- The Homebrew release-dispatch credential returned HTTP 401 during 0.7.3.
  A maintainer dispatch published the exact verified formula; the automation
  credential still needs renewal.

### Resolved

#### Hivebox HTTPS-origin push path is source/integration-pinned but not live-Docker-smoked.

##### Source S28, lines 850–850: Open questions about the codebase

37. ~~**Hivebox HTTPS-origin push path is source/integration-pinned but not live-Docker-smoked.**~~ — closed 2026-10-15. The Hivebox Docker distribution and its image credential helper were removed (ADR-055), so there is no Dockerized path left to smoke; origin normalization stays Rails-integration-pinned for native Hive web. Original record: Commit `8be458bd` added origin normalization, now owned by the Rails `Repository` model, plus a Rails integration regression proving an existing `git@github.com:` origin is rewritten to `https://github.com/...`, and a Dockerfile system credential helper for `https://github.com` via `gh auth git-credential`. This refresh did not find an in-tree artifact showing the full Dockerized path after a real Agents-page `gh` login: register/clone a repo whose `gh` config prefers SSH, open a Hive PR, and observe `5-open-pr` push succeeding over the rewritten https origin.

#### Hivebox golden-path install is workflow/diagnostics-pinned but not fully hosted/live-provider-smoked.

##### Source S28, lines 855–856: Open questions about the codebase

42. ~~**Hivebox golden-path install is workflow/diagnostics-pinned but not fully hosted/live-provider-smoked.**~~ — closed 2026-10-15. The Hivebox Docker distribution, its `hivecli.sh/box` installers, and the image release jobs were removed (ADR-055); published images stay in GHCR without updates, so no further install proof is owed. Original record: commit `54fd3455` moved the arm64 image smoke to native `ubuntu-24.04-arm` Docker and recorded a green run against `ghcr.io/ivankuznetsov/hivebox:0.3.1`; public endpoint, Windows Docker Desktop, and live-provider box runs were never evidenced in-tree.
