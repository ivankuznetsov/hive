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

`Hive::AgentSkills::CanonicalSkill` renders platform frontmatter, invocation, provenance, the current Hive installer version, and `.hive-skill.json`. Tests byte-compare every committed OpenClaw file with that renderer. Claude (`/hive`), Codex (`$hive`), and Pi (`/skill:hive`) receive the same canonical payload through Hive’s consent-safe agent-skill setup; OpenClaw invokes it as `/hive`.

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
user-global software. After approval it runs
`hive setup --no-init --yes --json` for local web and daemon provisioning;
initial project enrollment remains a separate `hive init .` run in the user's
real terminal so Hive can show its defaults and ask for confirmation. The
Homebrew installer metadata provides the macOS `hive` binary dependency.
OpenClaw installation remains ClawHub-owned:
`hive doctor` reads local config, workspace, and ClawHub provenance without
launching OpenClaw and points missing or stale installations to
`openclaw skills install/update @ivankuznetsov/hive-cli`;
`hive setup-agents` never writes OpenClaw state.

## Local projection test

From the Hive repository root:

```bash
openclaw skills install ./openclaw/skills/hive --as hive
```

Then invoke `/hive status`. The skill should use `hive status --operational --json` and `hive watch --json-lines`, never a shell polling loop.

## Authenticated release proof

The protected `.github/workflows/live-agent-skills.yml` workflow builds one
candidate gem and one four-platform skill archive from an exact commit, then
runs each native agent against its projection in a disposable home. OpenClaw
must discover `/hive` through its own JSON inventory and complete the same
bounded status/watch task as Claude, Codex, and Pi. Retained evidence contains
only structured event kinds, hashes, exact audited Hive argv, candidate
provenance, and cleanup/secret-scan results.

All four jobs and the attestation job must pass before the workflow can publish
the candidate-bound `live-agent-skills` check. A local skip proves only that
credentials were unavailable; it is not release evidence. See
`docs/RELEASING.md` for the exact-artifact gate.

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
