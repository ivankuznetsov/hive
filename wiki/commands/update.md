---
title: hive update
type: command
source: lib/hive/commands/update.rb, lib/hive/commands/migrate_all.rb, lib/hive/install_channel.rb, install.sh
created: 2026-05-21
updated: 2026-09-02
tags: [command, install, update, migration]
---

**TLDR**: `hive update --yes` delegates publication to the normal install
channel, then runs one confirmed irreversible fleet cutover through the
installed candidate. Hive never renames package-owned launchers.

## Usage

```bash
hive update [--dry-run] [--yes]
```

`--dry-run` prints the selected channel, updater command, irreversible
activation boundary, and post-update migration command without executing
either one. A mutating update refuses without `--yes`.

## Channel detection

`Hive::InstallChannel.detect` probes marker paths in priority order:

1. `${XDG_DATA_HOME:-~/.local/share}/hive/install-channel`.
2. `$HIVE_PREFIX/hive/install-channel` when `HIVE_PREFIX` is set.
3. macOS Homebrew marker paths under a valid Homebrew prefix.
4. `/usr/share/hive/install-channel` for system packages.

A missing marker means `dev`, the git-checkout fallback. Malformed markers fail closed with `Hive::ConfigError` instead of falling through to a lower-priority marker.

`install.sh --prefix=<dir>` normalizes `<dir>` to an absolute path before it writes both `install-channel` and `install-prefix` sidecars, so the bash-channel updater can re-use relative or `~/...` caller input from any later working directory without requiring `HIVE_PREFIX` to be exported again.

## Channel actions

| Channel | Action |
|---------|--------|
| `brew` | `brew upgrade ivankuznetsov/hive/hive` |
| `aur` | `yay -Syu hive-bin`, falling back to `paru` when `yay` is unavailable |
| `bash` | downloads `https://raw.githubusercontent.com/ivankuznetsov/hive/main/install.sh` to a temp file, then runs it, preserving the detected prefix when available |
| `dev` | prints `git pull && bundle install && hive migrate --all` guidance and exits 0 |

The bash channel deliberately downloads to a tempfile rather than piping remote script bytes into a shell. Helper preflight checks make missing `brew`, `curl`, `yay`, or `paru` errors actionable.
The installer binds cosign verification to the resolved release tag whether
that tag came from `HIVE_VERSION`/`--version` or the latest-release API; the
latest-version path therefore authenticates the same exact workflow identity
as an explicitly pinned install.

## Confirmed irreversible fleet cutover

The configured package updater publishes the candidate through its normal
channel. Hive does not copy, rename, or replace Homebrew, AUR, bash, or other
package-owned launcher entries. The update command then resolves the installed
candidate and runs `migrate --all --yes`; its own `--yes` confirmation is the
authority for that non-interactive cutover call.

The candidate's read-only activation gate runs before LLM-wiki reconciliation
or any other startup mutation. Until SQLite activation is complete, ordinary
entrypoints refuse and point to fleet cutover or `hive runtime status`. Only
the exact forward maintenance/diagnostic routes remain available.

The standalone `install.sh` path deliberately does not migrate runtime state or
start services. A genuinely fresh install finishes with `hive setup --yes`,
which performs explicit bootstrap before service installation. Existing
installations use `hive update --yes`. The immediately previous release already
invokes candidate `migrate --all` without `--yes`; the candidate therefore asks
for `yes` on a TTY and refuses non-TTY use with the exact
`hive migrate --all --yes` instruction.

`hive migrate --all` validates every registered project and global legacy
domain before activation. Missing projects require an explicit recorded
exclusion. One project failure, source mutation, live owner, unsupported
record, or parity/integrity failure leaves the installation unactivated; this
is not a sequence of independently committed project migrations.

If the channel updater fails, migration is not started. If the updated binary
cannot be resolved or fleet migration exits non-zero, `hive update` reports
that distinction and prints the exact `hive migrate --all --yes` or runtime
status/resume action. Before sealing, retry uses intact legacy input. After
sealing, the immutable source, candidate, and writer fences remain and
`hive runtime resume` converges only forward.

## Nudge command (shared with the update flow)

`Hive::Commands::Update.nudge_command(channel)` returns `hive update` for every
installed channel and `nil` for `dev` (a git clone has no single automatic
update action). The daemon-driven [[update-flow]] uses this string when it
records a per-version nudge. Keeping the user-facing command channel-neutral
ensures every guided update includes the confirmed fleet cutover; the update
command itself still selects brew, `yay`/`paru`, or the bash installer.

## Output and serialization

Update has no JSON mode or command schema. It prints the selected channel,
updater, cutover progress, and exact recovery action as human-readable text;
JSON serialization and a serialization fallback are not applicable.

## Tests

- `test/unit/commands/update_test.rb` covers channel selection, dry-run output,
  bash-prefix reuse, helper preflights, AUR fallback, update/migration ordering,
  package-launcher non-mutation, status output, and readable forward-recovery
  failures.
- `test/unit/commands/migrate_all_test.rb` covers the fleet-cutover delegation,
  TTY/non-TTY confirmation and exclusions.
- `test/integration/release_candidate_latest_stable_upgrade_test.rb` covers the
  immediately previous packaged release's real Update-to-candidate argv,
  candidate confirmation contract, activation, and retired-writer fences.
- `test/unit/install_channel_test.rb` covers marker reads/writes, XDG paths, Homebrew marker probing, prefix marker precedence, and fail-closed invalid markers.
- `test/unit/install_script_test.rb` proves direct installation leaves runtime
  bootstrap and service activation to the explicit `hive setup --yes` step.

## Backlinks

- [[cli]] · [[operating]] · [[modules/config]] · [[update-flow]]
