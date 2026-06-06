# Hive OpenClaw Skill

This directory contains the OpenClaw skill for driving the `hive` CLI from an
OpenClaw agent. The published ClawHub surface is intentionally one skill:

```bash
openclaw skills install hive-cli
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

## Setup Model

`openclaw skills install hive-cli` installs the OpenClaw skill folder. It does
not run arbitrary setup commands during the install itself. The `/hive` skill is
always visible, even before the Hive CLI is installed, and guides first use:

```text
/hive setup
```

That guided setup asks for confirmation, installs the Hive CLI through the
documented platform channel, verifies `hive`/`hv`, runs `hive daemon install`,
and optionally initializes the current project with non-interactive defaults.
The macOS Skills UI can also use the skill's Homebrew installer metadata to
install the `hive` binary.

## Local Install For Testing

From the Hive repository root:

```bash
openclaw skills install ./openclaw/skills/hive --as hive
```

Then run `/hive setup` from OpenClaw.

## Publish Checklist

Publish exactly the umbrella skill:

```bash
clawhub login
clawhub whoami

clawhub skill publish openclaw/skills/hive \
  --slug hive-cli \
  --name "Hive CLI" \
  --owner ivankuznetsov \
  --version 0.1.0 \
  --changelog "Initial Hive OpenClaw skill with guided setup"
```

Do not run `clawhub sync` for this repository, and do not publish folders such
as `openclaw/skills/plan` or slugs such as `hive-plan`. Those shortcut listings
are intentionally not part of the public surface.
