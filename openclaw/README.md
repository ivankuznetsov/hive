# Hive OpenClaw Skill

Hive publishes one OpenClaw skill:

```bash
openclaw skills install @ivankuznetsov/hive-cli
```

The ClawHub slug is `hive-cli`; the installed invocation is `/hive` because the rendered skill name is `hive`. Do not publish one listing per Hive subcommand.

## Canonical source

Do not hand-edit `openclaw/skills/hive/`. It is the committed OpenClaw projection of:

```text
skills/hive/SKILL.md
skills/hive/skill.json
skills/hive/references/*.md
```

`Hive::AgentSkills::CanonicalSkill` renders platform frontmatter, invocation, provenance, the current Hive installer version, and `.hive-skill.json`. Tests byte-compare every committed OpenClaw file with that renderer. Claude, Codex, and Pi receive the same canonical payload through Hive’s consent-safe agent-skill setup.

The public listing remains <https://clawhub.ai/ivankuznetsov/skills/hive-cli>.

## First use

ClawHub installation does not run arbitrary setup commands. The OpenClaw
projection remains visible before the Hive CLI is installed and routes setup
through the progressive setup reference:

```text
/hive setup
/hive status
/hive watch <project>:<slug>
```

Guided setup explains the selected platform channel and asks before changing
user-global software. It runs `hive setup --no-init --json` for local web and
daemon provisioning; initial project enrollment remains a separate
`hive init .` run in the user's real terminal so Hive can show its defaults and
ask for confirmation. The Homebrew installer metadata provides the macOS
`hive` binary dependency. OpenClaw installation remains ClawHub-owned;
`hive setup-agents` diagnoses but never overwrites it.

## Local projection test

From the Hive repository root:

```bash
openclaw skills install ./openclaw/skills/hive --as hive
```

Then invoke `/hive status`. The skill should use `hive status --operational --json` and `hive watch --json-lines`, never a shell polling loop.

## Publish checklist

Publishing is a release action. Do not run these commands without a separate explicit release request and version direction.

Read the authoritative skill version instead of copying a literal into documentation:

```bash
skill_version="$(ruby -rjson -e 'print JSON.parse(File.read("skills/hive/skill.json")).fetch("version")')"
skill_dir="$(pwd)/openclaw/skills/hive"

clawhub login
clawhub whoami
clawhub skill publish "$skill_dir" \
  --slug hive-cli \
  --name "Hive CLI" \
  --owner ivankuznetsov \
  --version "$skill_version" \
  --dry-run \
  --json
```

The absolute path avoids ClawHub resolving the source under another configured
skills directory. Inspect the dry-run payload before a separately authorized
release reruns the command without `--dry-run`.

ClawHub publication is staged. A publish can reserve the immutable version
before that version is inspectable. Do not republish, delete, or increment the
version while checks are pending. Poll the exact version with a bounded wait:

```bash
clawhub inspect @ivankuznetsov/hive-cli \
  --version "$skill_version" \
  --files \
  --json
```

Declare the skill live only after the exact version is inspectable and a clean
temporary install matches the reviewed source:

```bash
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
clawhub --workdir "$tmpdir" --dir skills install \
  @ivankuznetsov/hive-cli \
  --version "$skill_version"
cmp openclaw/skills/hive/SKILL.md \
  "$tmpdir/skills/@ivankuznetsov/hive-cli/SKILL.md"
```

Keep host mutations reviewable: do not suppress package-manager confirmation,
patch installed Hive files, or write service-manager overrides from the public
skill. Publish exactly `openclaw/skills/hive`. Do not run `clawhub sync`, do not
publish folders such as `openclaw/skills/plan`, and do not create slugs such as
`hive-plan`.
