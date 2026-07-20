# Hive OpenClaw Skill

This directory contains the OpenClaw skill for driving the `hive` CLI from an
OpenClaw agent. The published ClawHub surface is intentionally one skill:

```bash
openclaw skills install @ivankuznetsov/hive-cli
```

That listing installs a skill whose frontmatter name is `hive`, so users invoke
it in OpenClaw as:

```text
/hive setup
/hive status --json
/hive new . "build this feature"
/hive plan <task-slug>
/hive develop <task-slug>
/hive review <task-slug>
```

Do not publish one ClawHub listing per Hive command. Subcommands and options
belong after `/hive ...`.

## Shape

OpenClaw skills are directories containing a `SKILL.md` file with YAML
frontmatter and markdown instructions:

- Creating skills: <https://docs.openclaw.ai/tools/creating-skills>
- Installing skills: <https://docs.openclaw.ai/tools/skills>
- Publishing skills: <https://github.com/openclaw/clawhub/blob/main/docs/quickstart.md>

Hive ships one source skill folder:

```text
openclaw/skills/hive/SKILL.md
```

The ClawHub slug is `hive-cli` because the public `hive` slug is already owned
by another publisher. The installed slash command is still `/hive` because
OpenClaw reads `name: hive` from `SKILL.md`.

Public listing: <https://clawhub.ai/ivankuznetsov/skills/hive-cli>.

## Setup Model

`openclaw skills install @ivankuznetsov/hive-cli` installs the OpenClaw skill
folder. It does
not run arbitrary setup commands during the install itself. The `/hive` skill is
always visible, even before the Hive CLI is installed, and guides first use:

```text
/hive setup
```

That guided setup asks for confirmation, installs the Hive CLI through the
documented platform channel, verifies `hive`/`hv`, and runs
`hive setup --no-init --json` for local web/daemon provisioning without project
enrollment. On supported Linux/macOS the response reports the loopback URL and
distinct installed, enabled, running, and ready state for the default managed
Hive web service, along with daemon setup. Enrollment is a separate
`hive init .` run in the user's terminal, where patrol, architecture discovery,
daemon, and babysitter defaults are shown before confirmation. The skill also
covers machine-readable preview/approval flows for managed agent provisioning
and reviewed Honeycomb workflows, ordinary and architecture patrol limits,
digest/bench commands, status monitoring, and guarded recovery.
The macOS Skills UI can also use the skill's Homebrew installer metadata to
install the `hive` binary.

Use `/hive web status --json` for read-only web state. Bare `/hive web` is the
explicit blocking foreground path, not a status probe. The skill must never
create LAN/public binding or Tailscale exposure; it only reports a non-loopback
origin that an operator explicitly configured through Hive's existing gates.

Choose Hivebox when the user needs container isolation, multiple local
instances, containment for untrusted agents, or reproducible server/NAS
deployment. Windows can use WSL with systemd for native Hive web or Hivebox
through Docker Desktop; do not invent a separate Windows service manager.

## Local Install For Testing

From the Hive repository root:

```bash
openclaw skills install ./openclaw/skills/hive --as hive
```

Then run `/hive setup` from OpenClaw.

## Publish Checklist

Publish exactly the umbrella skill. Preview the resolved payload first:

```bash
clawhub login
clawhub whoami

skill_dir="$(pwd)/openclaw/skills/hive"
clawhub skill publish "$skill_dir" \
  --slug hive-cli \
  --name "Hive CLI" \
  --owner ivankuznetsov \
  --version 0.1.3 \
  --changelog "Refresh for Hive 0.6.4, add current workflow and patrol guidance, and require reviewable consent for host changes" \
  --dry-run \
  --json
```

ClawHub v0.23 resolves relative publish paths under its configured skills
directory, so the checklist uses an absolute path from the repository root.
If the preview contains one file from `openclaw/skills/hive/` and the intended
metadata, repeat the command without `--dry-run`. After publication, inspect
`@ivankuznetsov/hive-cli` and its security audit. A `Review` audit is not a
malware verdict, but every finding should be resolved or explicitly explained.

ClawHub publication is staged. The publish response can reserve the immutable
version before pre-publication checks make it visible, so `inspect` may briefly
report `Version not found` and unversioned installs may still resolve the prior
release. Do not republish, delete, or increment around that pending state. Poll
the exact version with a bounded wait:

```bash
clawhub inspect @ivankuznetsov/hive-cli \
  --version 0.1.3 \
  --files \
  --json
```

Declare the release live only after the exact version is inspectable and a clean
temporary install matches the reviewed source:

```bash
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
clawhub --workdir "$tmpdir" --dir skills install \
  @ivankuznetsov/hive-cli \
  --version 0.1.3
cmp openclaw/skills/hive/SKILL.md \
  "$tmpdir/skills/@ivankuznetsov/hive-cli/SKILL.md"
```

Keep host mutations reviewable: do not suppress package-manager confirmation,
patch installed Hive files, or write service-manager overrides from the public
skill. Prefer Hive's diagnose/preview/consent commands.

Do not run `clawhub sync` for this repository, and do not publish folders such
as `openclaw/skills/plan` or slugs such as `hive-plan`. Those shortcut listings
are intentionally not part of the public surface.
