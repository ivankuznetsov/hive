# Permission Scopes

Hive can opt a stage into a Claude tool scope with `permissions:`. The default is
`yolo`, so existing projects keep the same behavior until a project or stage
declares a narrower preset.

## Scope

`permissions:` applies to workflow **stage spawns** (`plan`, `execute`, etc.) and
to **review reviewers**. It is a stage-level control, not a global permission
floor. The top-level (project) `permissions:` value is the default *for stages
and reviewers* — it is not a floor that every agent in the system must obey.

A `permissions:` key placed on a non-stage config block — `daemon`, `rebase`,
`babysitter`, `digest`, `web`, `patrol`, `bot`, `update`, and similar internal
blocks — is **not** a per-stage scope. It shape-validates at load but is never
resolved at runtime, so it does **not** gate those internal agents. The rebase
conflict-resolver and the babysitter PR/CI fixer stay write-capable by design
(they must edit files and push), and no `permissions:` key changes that. To scope
an agent, declare `permissions:` on a pipeline stage or a review reviewer.

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

Project workflow descriptors can also put `permissions:` directly on an agent
stage in `.hive-state/workflows/<id>.yml`. That descriptor value is validated
with the same rules and overrides the config-keyed stage lookup for that
descriptor stage.

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

`tools:` is authoritative. Hive passes those tools as Claude's
`--allowedTools` value, deduplicated. Entries are validated at config load:
a blank, comma-bearing, whitespace-bearing, or null-byte entry is rejected
with an error (not silently dropped), so each entry must be a single tool
name. Hive also
emits a `--disallowedTools` deny list —
the `read-only` mutating/shell set (`Write`, `Edit`, `MultiEdit`,
`NotebookEdit`, `Bash`) minus whatever you granted — so a tool you grant
is never also denied. (Claude's deny rules win over allow rules, so an
overlap would silently revoke the grant.)

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
Runner-support errors are checked inside `PermissionScope.resolve` (when a stage
resolves its permission scope), so a non-yolo scope on Codex or Pi fails before
the agent is spawned.
