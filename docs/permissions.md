# Permission Scopes

Hive can opt a stage into a Claude tool scope with `permissions:`. The default is
`yolo`, so existing projects keep the same behavior until a project or stage
declares a narrower preset.

## Caveat

Permission scoping is tool/MCP-level, enforced by the agent's allowed tool set.
It is not an OS sandbox. The agent runs as the same OS user; `read-only` limits
accidental over-reach, but it does not contain a determined or mis-prompted
agent. For real isolation, run hive under a sandboxed user or container, such as
hivebox.

## Presets

| Preset | Effect |
|---|---|
| `yolo` | Current default. Claude receives bypass permissions and no tool allowlist or denylist from Hive. |
| `read-only` | Allows only `Read`, `LS`, `Grep`, and `Glob`. Explicitly denies `Write`, `Edit`, `MultiEdit`, `NotebookEdit`, and `Bash`. It does not include network tools or MCP tools. |
| `scoped` | Custom scope. You provide `tools:` and optionally `dirs:`, or use `bash:` as sugar on the read-only base set. |

Non-yolo presets are supported for the Claude runner only. If a stage using
Codex or Pi declares `read-only` or `scoped`, Hive fails closed with a config
error instead of silently degrading.

## YAML Forms

Use a scalar preset when the preset needs no options:

```yaml
permissions: read-only
```

Use a map when the preset takes options:

```yaml
permissions:
  preset: scoped
  tools: [Read, Write, Edit]
  dirs:
    - ./drafts
    - /tmp/shared-fixtures
```

A top-level `permissions:` value is the project default:

```yaml
permissions: read-only
```

Every stage block can replace that default completely:

```yaml
permissions: read-only

plan:
  agent: claude
  permissions: yolo

execute:
  agent: claude
  permissions:
    preset: scoped
    tools: [Read, Write, Edit]
    dirs: [./drafts]
```

The stage value is a full replacement, not a field merge. In the example above,
`execute.permissions.tools` does not inherit anything from the project default.

Review substages use their dotted stage names in config:

```yaml
review:
  ci:
    agent: claude
    permissions: read-only
  reviewers:
    - name: claude-ce-code-review
      kind: agent
      agent: claude
      permissions: read-only
```

## Scoped Options

`tools:` is authoritative. Hive passes exactly those tools as Claude's
`--allowedTools` value.

`dirs:` extends the task folder add-dir list. Relative paths are resolved from
the task folder; absolute paths are honored as written. Hive always keeps the
task folder and appends these extra directories.

`bash:` is shorthand on the read-only base set:

```yaml
permissions:
  preset: scoped
  bash: true
```

`bash: true` allows `Read`, `LS`, `Grep`, `Glob`, and `Bash`. `bash: false`
keeps the read-only base set. Do not combine `bash:` with `tools:`; express Bash
directly in `tools:` when you provide a custom list.

## Validation

Hive validates permission specs at config load and spawn time. Unknown presets,
unknown keys, malformed maps, and `bash:` plus `tools:` are hard errors.
Runner-support errors are checked when a stage resolves its agent profile, so a
non-yolo scope on Codex or Pi fails before the agent is spawned.
