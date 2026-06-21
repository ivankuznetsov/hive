# Project Workflows

Hive ships with built-in `coding` and `content` workflows. A project can also
define owner-authored workflows under its Hive state tree:

```
.hive-state/workflows/<id>.yml
.hive-state/workflows/<id>/<stage>.md
```

`hive init` still chooses the project default workflow, and `hive new
PROJECT --workflow <id> "..."` pins a single task to a workflow. Project
workflow descriptors are discovered at runtime by `hive new`, `hive init`,
`hive status`, `hive run`, `hive approve`, and the daemon path that uses those
commands.

## Create A Blank Workflow

```bash
hive workflow new my-flow
```

This writes a minimal `inbox -> work -> done` workflow:

```
.hive-state/workflows/my-flow.yml
.hive-state/workflows/my-flow/work.md
```

The generated descriptor is valid immediately, and the placeholder
`work.md` is the prompt for the `work` stage. Edit that file to define what the
agent should do.

Then create a task with:

```bash
hive new <project> --workflow my-flow "<your idea>"
```

## Descriptor Schema

```yaml
id: my-flow
stages:
  - name: inbox
    kind: terminal
    state_file: idea.md
  - name: work
    kind: agent
    state_file: work.md
    instruction: ./my-flow/work.md
    permissions: read-only
  - name: done
    kind: terminal
    state_file: done.md
```

Rules:

- `id` must match the filename stem and `/\A[a-z0-9][a-z0-9-]*\z/`.
- `kind: terminal` creates an inert stage; it does not spawn an agent.
- `kind: agent` spawns the generic stage runner.
- `kind: council` is reserved and currently rejected.
- Every agent stage must declare exactly one of `skill:` or `instruction:`.
- `skill:`, `instruction:`, and `permissions:` are only valid on `kind: agent`
  stages; declaring any of them on a `kind: terminal` stage is rejected at load
  (they are no-ops there).
- `instruction:` is resolved relative to the descriptor file and must point to a readable file (any extension; `.md` is conventional but not required).
- `permissions:` is optional and uses the same syntax as [permissions.md](permissions.md).
- The last stage must be `kind: terminal`. A task at the final stage cannot
  advance, so a non-terminal last stage would be undroppable.

Stage indexes and stage directories are derived from array order. The example
above produces `1-inbox`, `2-work`, and `3-done`. The first stage has no
incoming advance verb; later stages default their incoming advance verb to the
stage name.

## Trust Boundary

Project workflow descriptors are trusted project-owner configuration. An
`instruction:` file is injected into the agent prompt as the stage instruction,
not treated as untrusted task data. Permission scopes are tool-level controls,
not an OS sandbox; run Hive in a sandboxed user/container when isolation from a
descriptor author matters.
