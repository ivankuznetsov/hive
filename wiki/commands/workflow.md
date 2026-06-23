---
title: hive workflow
type: command
source: lib/hive/cli.rb, lib/hive/commands/workflow.rb, templates/workflows/blank/
created: 2026-06-21
updated: 2026-06-23
tags: [command, workflow, authoring]
---

**TLDR**: `hive workflow new ID` scaffolds a minimal project-authored workflow descriptor at `<hive_state_path>/workflows/ID.yml` plus a placeholder instruction at `<hive_state_path>/workflows/ID/work.md`. The generated `inbox -> work -> done` descriptor validates immediately and is discoverable by `hive new PROJECT --workflow ID`, status, run, approve, and daemon-driven dispatch.

## Usage

```bash
hive workflow new my-flow
hive workflow new my-flow --json
```

For a fresh project that should default to the custom workflow immediately,
prefer `hive init --new-workflow my-flow [PROJECT_PATH]`; it performs init,
scaffolds the same descriptor/instruction files, and binds `default_workflow`
in one flow. Use `hive workflow new` when the project is already initialized
and you do not want to rebind the default.

The command is project-root local. It reads the current project's
`hive_state_path` from `.hive-state/config.yml` (default `.hive-state`) and
writes:

```text
<hive_state_path>/workflows/my-flow.yml
<hive_state_path>/workflows/my-flow/work.md
```

It refuses to overwrite an existing descriptor, instruction directory, or
instruction file. `ID` must match the descriptor safe-slug rule and cannot be a
built-in workflow id such as `coding` or `content`.

On success, the command validates the generated descriptor with
`Hive::Workflows::DescriptorParser`, resets the project workflow cache, commits
the workflow files on `hive/state`, and prints the next command:

```bash
hive new <project> --workflow my-flow "<your idea>"
```

With `--json`, success is an unversioned document containing `ok`, `id`,
`descriptor_path`, `instruction_path`, and `next`. Typed usage/config/git
errors emit an unversioned JSON error document with `ok: false`, `error_class`,
`exit_code`, and `message`.

## Generated Descriptor

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
  - name: done
    kind: terminal
    state_file: done.md
```

The placeholder `work.md` says:

```text
Edit this file to define what the `work` stage should do.
```

## Backlinks

- [[cli]]
- [[commands/init]]
- [[modules/workflows]]
- [[commands/new]]
