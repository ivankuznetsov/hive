# Setup and platforms

## Verify the CLI

Resolve Hive without confusing it with Apache Hive:

```bash
if hive --version 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  hive_cmd=hive
elif hv --version 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  hive_cmd=hv
else
  hive_cmd=
fi
```

If neither command prints Hive CLI's bare semantic version, stop or offer an
installation. Explain the chosen channel and obtain confirmation before
changing user-global software. Preserve the package manager's normal review
and confirmation prompt:

```bash
brew tap ivankuznetsov/hive && brew install ivankuznetsov/hive/hive
yay -S --needed hive-bin
paru -S --needed hive-bin
```

For Arch, display the selected transaction and ask the user to run it in their
real terminal. Never add `--noconfirm` or execute the transaction through a
non-TTY agent tool call.

On supported Ubuntu or compatible glibc Linux, download the version-pinned
installer into an owner-private temporary directory after approval:

```bash
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
curl -fsSL https://raw.githubusercontent.com/ivankuznetsov/hive/v0.6.4/install.sh \
  -o "$tmpdir/hive-install.sh"
bash "$tmpdir/hive-install.sh"
```

The exact installer tag in a rendered skill comes from the running Hive package
version. Repeat strict `hive`/`hv` detection after installation and stop if it
does not resolve Hive CLI.

## Provision first, enroll separately

Use Hive’s setup lifecycle rather than copying files manually:

```bash
hive doctor --json
hive setup-agents --json
# Only after the user approves that exact plan:
hive setup-agents --yes --json
# Only after the user approves core provisioning:
hive setup --no-init --yes --json
```

`hive doctor` is read-only and inspects durable filesystem evidence without
launching Claude, Codex, Pi, or OpenClaw. `hive setup-agents --json` is the
machine-readable preview; its consent-required response and nonzero exit are
expected when changes are planned. Run `--yes --json` only after the user
approves the displayed scope. Foreign or user-edited destinations are
conflicts, not overwrite targets.

JSON or non-interactive setup without `--yes` returns a typed refusal before
diagnostics or native agent discovery. After approval,
`hive setup --no-init --yes --json` provisions the managed skills, web assets,
and daemon without enrolling the repository.

Initial project enrollment is a separate consent boundary. Explain that a
non-TTY `hive init` takes defaults that enable medium patrol, architecture
discovery, daemon dispatch, and the babysitter; those facilities consume
provider subscription capacity and can eventually open pull requests. After
the user reviews and approves enrollment, ask them to run `hive init .` in
their own real terminal so they can change those defaults. Do not run it
headlessly on their behalf or invent bypass flags.

OpenClaw installs the public ClawHub projection separately:

```bash
openclaw skills install @ivankuznetsov/hive-cli
```

`hive doctor` diagnoses OpenClaw when available but Hive setup does not take
over ClawHub ownership.

Never patch an installed Hive runtime or write service-manager overrides.
Diagnose with `hive doctor --json` and `hive daemon status --json`, then use
Hive-native setup or repair commands only after the user approves the specific
persistent change.

## Invocation conventions

- OpenClaw: `/hive`
- Claude: `/hive`
- Codex: `$hive`
- Pi: `/skill:hive`

Pass the remaining user request as arguments or intent to the skill. Do not turn free-form text into an unquoted shell command. Use each platform’s resolved skill inventory to confirm which Hive projection wins when multiple locations exist.
