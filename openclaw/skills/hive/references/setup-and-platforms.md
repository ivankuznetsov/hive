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
curl -fsSL https://raw.githubusercontent.com/ivankuznetsov/hive/v0.6.8/install.sh \
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
# Interactive terminals preview exact managed writes and prompt for consent:
hive setup-agents
# JSON/non-TTY calls without --yes return a typed, empty refusal:
hive setup-agents --json
# Only after the user approves the managed Claude/Codex/Pi scope:
hive setup-agents --yes --json
# Only after the user approves core provisioning:
hive setup --no-init --yes --json
# If approval excludes persistent Hive web service changes:
hive setup --no-init --no-service --yes --json
```

`hive doctor` is read-only and inspects durable filesystem evidence without
launching Claude, Codex, Pi, or OpenClaw. An interactive `hive setup-agents`
previews exact managed writes before prompting. By design,
`hive setup-agents --json` without `--yes` does not inspect agent homes or
return a write plan: it returns a typed `consent_required` refusal with empty
targets and operations. An agent must explain the managed Claude/Codex/Pi
scope, obtain the user's approval, and only then run `--yes --json`. Foreign or
user-edited destinations are conflicts, not overwrite targets.

JSON or non-interactive setup without `--yes` returns a typed refusal before
diagnostics or native agent discovery. After approval,
`hive setup --no-init --yes --json` provisions the managed skills, web assets,
and daemon without enrolling the repository. On supported Linux/macOS, this
approved default setup is also a persistent service change: it installs,
enables, starts, and bounded-probes the loopback Hive web service. Include that
default web-service mutation in the consent explanation. If it is not approved,
use `--no-service`; setup may report an existing unit but must not install,
enable, start, stop, or disable it.

Keep service lifecycle separate from application readiness. The
`hive-setup.v1` response reports `service.service_manager_available`,
`service.service_installed`, `service.service_enabled`,
`service.service_running`, `service.ready`, `service.readiness`, and
`service.url`; do not collapse those fields into one "running" claim. For a
read-only follow-up, use `hive web status --json`. It samples the existing
service immediately without installing, enabling, starting, or restarting it;
bare `hive web` starts the blocking foreground server and is not a status
probe.

Prefer this native managed-service path for an ordinary Linux/macOS
workstation. Choose Hivebox when the user needs container isolation, multiple
local instances, containment for untrusted agents, or a reproducible
server/NAS deployment. On Windows, use WSL with systemd for the native path or
Hivebox through Docker Desktop; do not invent a separate Windows service
manager.

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
