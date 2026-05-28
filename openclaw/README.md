# Hive OpenClaw Skills

This directory contains OpenClaw-ready skills for driving the `hive` CLI from
an OpenClaw agent. Each skill is a folder with a `SKILL.md` file and optional
metadata, matching OpenClaw's documented skill format:

- Skills are directories containing `SKILL.md` with YAML frontmatter and
  markdown instructions:
  <https://docs.openclaw.ai/tools/creating-skills>
- ClawHub installs one skill slug into a workspace with
  `openclaw skills install <skill-slug>`:
  <https://docs.openclaw.ai/tools/skills>
- ClawHub publishes one skill folder with
  `clawhub skill publish ./my-skill --slug my-skill --version 1.0.0`:
  <https://github.com/openclaw/clawhub/blob/main/docs/quickstart.md>

## Recommendation

Hive's OpenClaw surface is a set of prompt-shaped slash commands that shell out
to the existing `hive` binary. That fits OpenClaw Skills better than an
OpenClaw Plugin:

| Path | Install command | Fit |
|---|---|---|
| ClawHub skills | `openclaw skills install hive` plus optional shortcuts | Best fit: text instructions that call `hive`, no Node runtime |
| OpenClaw plugin | `openclaw plugins install clawhub:<package>` | Too much machinery for this surface; plugins are for TypeScript runtime code, tools, providers, channels, and hooks |
| Direct Git/local skill | `openclaw skills install git:ivankuznetsov/hive@<ref>` or `openclaw skills install ./openclaw/skills/hive --as hive` | Useful for testing, but no marketplace discoverability or ClawHub update tracking |

OpenClaw's documented grouping support is a filesystem organization feature
(`skills/<group>/<skill>/SKILL.md`), not a single marketplace slug that installs
many slash commands. The bundle therefore ships an umbrella `/hive` skill for a
one-command entry point, plus optional shortcut skills such as `/plan`, `/work`,
and `/ce-review` for frequent workflows.

## Prerequisite

Install the Hive CLI first. The skills deliberately do not install Ruby, git,
GitHub CLI, agent CLIs, or Hive itself.

```bash
hive --version
```

If `hive` is missing, install it from the main project README and retry.

## Local Install For Testing

From the Hive repository root:

```bash
openclaw skills install ./openclaw/skills/hive --as hive
openclaw skills install ./openclaw/skills/plan --as plan
openclaw skills install ./openclaw/skills/work --as work
openclaw skills install ./openclaw/skills/ce-review --as ce-review
```

To install every checked-in shortcut from a local checkout:

```bash
for skill in openclaw/skills/*; do
  openclaw skills install "$skill" --as "$(basename "$skill")"
done
```

## Planned ClawHub Slugs

The intended published slugs are:

| ClawHub slug | Slash command | Hive command |
|---|---|---|
| `hive` | `/hive` | Any `hive ...` command |
| `hive-new` | `/new` | `hive new` |
| `hive-brainstorm` | `/brainstorm` | `hive brainstorm` |
| `hive-plan` | `/plan` | `hive plan` |
| `hive-work` | `/work` | `hive develop` |
| `hive-open-pr` | `/open-pr` | `hive open-pr` |
| `hive-ce-review` | `/ce-review` | `hive review` |
| `hive-artifacts` | `/artifacts` | `hive artifacts` |
| `hive-finalize` | `/finalize` | `hive finalize` |
| `hive-archive` | `/archive` | `hive archive` |
| `hive-status` | `/hive-status` | `hive status` |
| `hive-findings` | `/findings` | `hive findings` |
| `hive-accept-finding` | `/accept-finding` | `hive accept-finding` |
| `hive-reject-finding` | `/reject-finding` | `hive reject-finding` |
| `hive-approve` | `/approve` | `hive approve` |
| `hive-run` | `/run` | `hive run` |
| `hive-markers` | `/markers` | `hive markers` |
| `hive-rebase-status` | `/rebase-status` | `hive rebase-status` |
| `hive-doctor` | `/doctor` | `hive doctor` |
| `hive-daemon` | `/daemon` | `hive daemon` |
| `hive-bot` | `/bot` | `hive bot` |
| `hive-init` | `/init` | `hive init` |

`/hive-status` is prefixed because OpenClaw already has a built-in `/status`
command. Destructive or rarely used admin commands such as `hive drop`,
`hive uninstall`, `hive update`, `hive forget`, `hive prune`, `hive migrate`,
and `hive metrics` remain available through `/hive ...`, where the agent sees
the complete command before execution.

## Publish Checklist

Dry-run every skill before publishing:

```bash
for skill in openclaw/skills/*; do
  name="$(basename "$skill")"
  slug="hive-$name"
  test "$name" = "hive" && slug="hive"

  clawhub skill publish "$skill" \
    --slug "$slug" \
    --version 0.1.0 \
    --changelog "Initial Hive OpenClaw skill bundle" \
    --dry-run
done
```

Actual publish is intentionally manual and requires maintainer confirmation:

```bash
clawhub login
clawhub whoami
# Re-run the loop above without --dry-run after confirming the namespace.
```
