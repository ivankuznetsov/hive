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
curl -fsSL https://raw.githubusercontent.com/ivankuznetsov/hive/v0.6.4/install.sh | bash
```

The exact installer tag in a rendered skill is derived from the running Hive package version.

## Initialize and inspect agent skills

Use Hive’s setup lifecycle rather than copying files manually:

```bash
hive setup --json
hive init PATH --json
hive doctor --json
hive setup-agents --json
```

`hive doctor` is read-only. `hive setup-agents` previews managed Claude, Codex, and Pi changes and requires consent before writing. In JSON or non-interactive mode, pass `--yes` only after the user approved the preview. Foreign or user-edited skill destinations are conflicts, not overwrite targets.

OpenClaw installs the public ClawHub projection separately:

```bash
openclaw skills install hive-cli
```

Hive setup diagnoses OpenClaw when available but does not take over ClawHub ownership.

## Invocation conventions

- OpenClaw: `/hive`
- Claude: `/hive`
- Codex: `/hive` or explicit `$hive` where the client uses skill mentions
- Pi: `/skill:hive`

Pass the remaining user request as arguments or intent to the skill. Do not turn free-form text into an unquoted shell command. Use each platform’s resolved skill inventory to confirm which Hive projection wins when multiple locations exist.
