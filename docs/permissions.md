# Permission Scopes

Hive can opt a stage into an enforceable agent scope with `permissions:`. The
default is `yolo`, so existing projects keep the same behavior until a project
or stage declares a narrower preset. Claude and OpenCode implement the safe
presets through different native mechanisms; unsupported profiles fail closed.

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

Permission scoping is application-level enforcement. Claude uses its native
tool rules; OpenCode receives an invocation-owned deny-first permission
configuration plus private config/data/cache/state homes. Neither is an OS
sandbox. The agent runs as the same OS user; `read-only` limits accidental
over-reach, but it does not contain a determined or compromised runtime. For
real isolation, run Hive under a sandboxed user or choose the [Hivebox
container distribution](../packaging/docker/README.md).

## Managed Honeycomb Policy

Reviewed Honeycomb packages use a separate managed-runtime contract rather than
inheriting the owner-authored stage default above. Hive validates each exact
actor scope during install or update and again immediately before spawn; a
profile that cannot enforce the declared bound fails closed. Preview and status
show permission/input metadata and secret-binding availability, never secret
values. These tool controls are still not an OS sandbox, so use Hivebox or
another container boundary when inherited settings, plugins, MCP servers, or
the shared OS user must also be isolated.

The authoritative package-policy specification—including disclosure versus
runtime enforcement, high-risk consent classification, provider admission, and
publication projection—lives in the managed wiki's
[`Hive::WorkflowPackage` module page](../wiki/modules/workflow_package.md).

## Presets

| Preset | Effect |
|---|---|
| `yolo` | Current default. Claude receives bypass permissions and no tool allowlist or denylist from Hive. OpenCode rejects this implicit policy. |
| `read-only` | Allows read/list/search operations and explicitly denies edits, shell, unsafe tools, network tools, and external writes. |
| `scoped` | Custom non-interactive scope. You provide `tools:` and optionally `dirs:`, or use `bash:` as Claude-only sugar on the read-only base set. Requests unmatched by any generated rule are denied. |

Non-yolo presets are supported for Claude and OpenCode. If a stage using Codex,
Pi, or Grok declares `read-only` or `scoped`, Hive fails closed with a config
error instead of silently degrading. OpenCode never receives an auto-approve
or bypass flag without a deny-first generated policy.

## OpenCode Enforcement

An OpenCode stage must select `read-only` or `scoped`; the project-default
`yolo` value is rejected before preparation. Hive resolves the real working
directory and every declared extra root, rejects unsafe symlinks/ownership,
and writes OpenCode's stable `permission` grammar into a private per-invocation
config. Last-match rules deny by default.

`read-only` permits bounded read/list/glob/grep/LSP operations and the selected
native skill, then denies edits, Bash, task delegation, web tools, questions,
and undeclared external directories. `scoped` becomes `workspace-write` when
the tool declaration includes Write/Edit authority. It permits edits only in
the working/declaration-derived write roots, keeps read-only extra roots
non-writable, and still denies unrestricted Bash and web tools. A scoped policy
that asks for Bash is rejected; Hive does not claim filesystem confinement
while leaving a general shell open.

The selected source config and credentials remain caller-owned and read-only.
Hive redirects OpenCode config, data, cache, and state into owner-private paths,
forwards only named credential variables (or an explicitly selected staged auth
file), disables ambient project/default discovery and remote model refresh,
and removes only those invocation-owned paths from the process owner's
`ensure`. Cleanup is idempotent. See the [OpenCode opt-in
example](getting-started.md#optional-opencode-profile).

## YAML Forms

Use a scalar preset when the preset needs no options:

```yaml
permissions: read-only
```

Use a map when the preset takes options:

```yaml
permissions:
  preset: scoped
  tools:
    - Read
    - Edit(./work.md)
    - Edit(../../../../docs/**)
  dirs:
    - ../../../..
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
  agent: opencode
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

`tools:` is authoritative. For Claude, Hive passes those rules as the
deduplicated `--allowedTools` value. A rule is either a bare tool name or a
single non-empty specifier, such as `Read(../../../../src/**)` or
`Edit(../../../../docs/**)`. Entries are validated at config load: a blank,
comma-bearing, whitespace-bearing, null-byte, or malformed rule is rejected
with an error (not silently dropped).

`Read(path)` and `Edit(path)` are portable, task-relative file rules. At spawn
time Hive resolves their paths and emits Claude's absolute `//...` form.
`Edit(path)` covers both built-in edits and new-file writes; use it instead of
`Write(path)`, `MultiEdit(path)`, or `NotebookEdit(path)`, which Hive rejects
because Claude does not enforce those rules as path matchers. Likewise, use
`Read(path)` instead of path-qualified `LS`, `Grep`, or `Glob`. Bare tool names
remain valid when unbounded access to that exact tool is intended.

Claude scoped stages use `dontAsk` mode: a matching rule runs and an
unmatched request is denied rather than prompting a headless process. Claude
merges Hive's CLI rules with permission rules from loaded managed, user,
project, and local settings. A broader allow there (for example bare `Write`)
can widen the effective session beyond the descriptor's requested scope. Treat
those setting sources as trusted operator policy; use an isolated Claude
configuration plus an OS sandbox when the descriptor must be a hard security
ceiling.

For Claude, Hive also emits a `--disallowedTools` deny list — the `read-only`
mutating/shell set (`Write`, `Edit`, `MultiEdit`, `NotebookEdit`, `Bash`) minus
whatever you granted — so a tool you grant is never also denied. A
path-qualified `Edit` rule covers every built-in file-edit tool, so Hive removes
all four file-edit denies for that rule. Claude's deny rules win over allow
rules, so retaining any of them could silently revoke the qualified grant.

`dirs:` extends the task folder directory list. Relative paths are resolved from
the task folder; absolute paths are honored as written. Hive always keeps the
task folder and appends these extra directories. Claude renders them as
`--add-dir`; OpenCode compiles them into its external-directory and edit rules.
A path rule does not itself make an external directory accessible, so declare
the matching `dirs:` entry as well.

For a standard workflow task at
`<project>/.hive-state/stages/<stage>/<slug>`, `../../../..` is the project
root. For example, bare `Read` plus `dirs: [../../../..]` grants project read,
while `Edit(../../../../docs/**)` grants writes under project `docs/**` only.

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
unknown keys, malformed maps/rules, unresolvable file-rule paths,
unsupported file-tool path rules, and `bash:` plus `tools:` are hard errors.
Runner-support errors are checked inside `PermissionScope.resolve` (when a
stage resolves its permission scope), so a non-yolo scope on Codex, Pi, or Grok
fails before the agent is spawned. OpenCode additionally validates its
deny-first policy, resolved roots, selected config/auth source, and installed
CLI capability before its model process is spawned.
