# Setup and platforms

## Verify the CLI

Resolve Hive before operating:

```bash
command -v hive || command -v hv
hive --version
```

Reject an unrelated Apache Hive binary or output that is not Hive CLI’s bare semantic version. For a requested installation, explain the channel and obtain confirmation before changing user-global software:

```bash
brew install ivankuznetsov/hive/hive
yay -S --noconfirm --needed hive-bin
curl -fsSL https://raw.githubusercontent.com/ivankuznetsov/hive/v{{HIVE_VERSION}}/install.sh | bash
```

The exact installer tag in a rendered skill is derived from the running Hive package version.

## Initialize and inspect agent skills

Use Hive’s setup lifecycle rather than copying files manually:

```bash
hive setup --yes --json
hive init PATH --json
hive doctor --json
hive setup-agents --yes --json
```

`hive doctor` is read-only. Interactive `hive setup-agents` previews managed Claude, Codex, and Pi changes and requires consent before writing. JSON or non-interactive setup without `--yes` returns a typed refusal before diagnostics or native agent discovery; after the user approves the operation, rerun with `--yes`. Foreign or user-edited skill destinations are conflicts, not overwrite targets.

OpenClaw installs the public ClawHub projection separately:

```bash
openclaw skills install @ivankuznetsov/hive-cli
```

`hive doctor` diagnoses OpenClaw when available but Hive setup does not take
over ClawHub ownership.

## Invocation conventions

- OpenClaw: `/hive`
- Claude: `/hive`
- Codex: `$hive`
- Pi: `/skill:hive`

Pass the remaining user request as arguments or intent to the skill. Do not turn free-form text into an unquoted shell command. Use each platform’s resolved skill inventory to confirm which Hive projection wins when multiple locations exist.
