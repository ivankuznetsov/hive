---
title: hive workflow
type: command
source: lib/hive/cli.rb, lib/hive/commands/workflow.rb, templates/workflows/
created: 2026-06-21
updated: 2026-07-13
tags: [command, workflow, authoring, honeycomb, publishing]
---

**TLDR**: `hive workflow new ID` scaffolds a project-authored descriptor. `hive workflow publish ID` validates one explicit descriptor, builds and locally preflights a deterministic `workflows/ID/` honeycomb, then opens a PR against the configured registry; `--dry-run` performs the same local work with no remote side effects.

## Usage

```bash
hive workflow new my-flow
hive workflow new my-flow --template writing
hive workflow new my-flow --json
hive workflow publish my-flow --dry-run
hive workflow publish my-flow --version 1.1.0 --json
```

For a fresh project that should default to the custom workflow immediately,
prefer `hive init --new-workflow my-flow [PROJECT_PATH]`; it performs init,
scaffolds the same descriptor/instruction files, and binds `default_workflow`
in one flow. Use `hive workflow new` when the project is already initialized
and you do not want to rebind the default.

The public user guide for this surface is
`https://hivecli.sh/docs/custom-workflows/`.

The command is project-root local. It reads the current project's
`hive_state_path` from `.hive-state/config.yml` (default `.hive-state`) and
writes:

```text
<hive_state_path>/workflows/my-flow.yml
<hive_state_path>/workflows/my-flow/work.md
```

It refuses to overwrite an existing descriptor, instruction directory, or
instruction file. `ID` must match the descriptor safe-slug rule and cannot be a
built-in workflow id such as `coding`, `content`, or `bench`.

On success, the command validates the generated descriptor with
`Hive::Workflows::DescriptorParser`, resets the project workflow cache, commits
the workflow files on `hive/state`, and prints the next command:

```bash
hive new <project> --workflow my-flow "<your idea>"
```

With `--json`, new-workflow success is a `hive-workflow-new` (schema_version 1) document
containing `ok`, `id`, `descriptor_path`, `instruction_path`, and `next`. Typed
usage/config/git errors emit a `hive-workflow-new` (schema_version 1) JSON error
document with `ok: false`, `error_class`, `exit_code`, and `message`.

A bare or unknown workflow subcommand is a USAGE error (exit 64). Human output
lists both valid router verbs (`new, publish`). With
`--json`, those subcommand-shape errors carry a structured `expected` array
such as `["new", "publish"]`; unknown subcommands also carry `value` with the rejected
token.

## Publishing

Publication requires descriptor metadata `version`, `author`, `description`,
and `minimum_hive_version`; `readme` and `assets` are optional explicit files.
All local files must resolve as regular files beneath
`<hive_state_path>/workflows/<id>/`. The package contains rewritten
`workflow.yml`, copied/generated `README.md`, rebased instructions/assets, and a
deterministic `manifest.yml` with SHA-256 file rows and aggregate digest.

Local preflight checks Hive compatibility, every named skill through its
effective agent profile, versioned secret rules, and versioned high-risk deny
rules. Secret findings always block without match text. Deny findings block
unless every owning context declares scoped Bash plus `shell_justification`;
accepted cases appear as `review_required`.

The target defaults to `ivankuznetsov/honeycomb` and is overridden with
`honeycomb.repository`. Hive caches a verified upstream checkout under
`Hive::Paths.cache_home`, pushes directly for `WRITE`/`MAINTAIN`/`ADMIN`, and
otherwise creates or reuses the authenticated user's fork. Submit branch
collisions fail closed; no force push exists. Success stops after PR creation.

`--dry-run` returns before authentication/cache/git/fork/push/PR work. JSON is
the registered `hive-workflow-publish.v1` contract; dry-run leaves submission
mode, branch, and PR URL null.

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

## Templates

`new` scaffolds the blank `inbox -> work -> done` stub by default. Pass
`--template NAME` to seed from a curated sample workflow instead: the
descriptor is rewritten to your `ID` and the sample's stage instructions are
copied verbatim — real content, not a placeholder — into `<id>/`. Available
templates are the directories under `templates/workflows/` that carry a
`descriptor.yml.erb`:

- `blank` (default) — `inbox -> work -> done`, one placeholder instruction.
- `writing` — `inbox -> research -> draft -> edit -> done`.
- `research` — `inbox -> gather -> synthesize -> report -> done`.

A multi-stage template prints `edit: <id>/ (N stage instructions to fill in)`
pointing at the directory of instructions to define (the single-stage blank
still names its one `work.md`). An unknown `--template` is a USAGE error
listing the available names; with `--json` they ride the `expected` array.

## Backlinks

- [[cli]]
- [[commands/init]]
- [[modules/workflows]]
- [[commands/new]]
