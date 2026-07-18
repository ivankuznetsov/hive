---
title: hive workflow
type: command
source: lib/hive/cli.rb, lib/hive/commands/workflow.rb, templates/workflows/
created: 2026-06-21
updated: 2026-07-18
tags: [command, workflow, authoring, honeycomb, registry]
---

**TLDR**: `hive workflow` manages two ownership domains: `new` scaffolds trusted project-authored descriptors, while `install`, `list`, `update`, and `remove` manage immutable reviewed Honeycomb generations; `publish` validates an authored descriptor and opens a registry PR whose status is only `pending_review`.

## Usage

```bash
hive workflow new my-flow
hive workflow new my-flow --template writing
hive workflow new my-flow --json
hive workflow install honeycomb/repo-brief --yes
hive workflow install honeycomb/repo-brief --dry-run --json
hive workflow list --json
hive workflow update repo-brief --dry-run --json
hive workflow update repo-brief --yes --allow-escalation
hive workflow remove repo-brief --yes
hive workflow remove repo-brief --dry-run --json
hive workflow publish my-flow --version 1.0.0
```

## Honeycomb Lifecycle

The official-source grammar is closed: `honeycomb/NAME`, a listed semantic
version, or its listed full source SHA. Mutable refs, abbreviated/unlisted
commits, arbitrary namespaces, and arbitrary repositories fail resolution.
Install validates the pinned catalog and source ancestry, canonical manifest,
complete payload inventory, static diagnostics, and every descriptor-selected
runner before it places and atomically selects a generation.

Managed storage is
`workflows/NAME/versions/SOURCE_SHA/` plus
`workflows/NAME/honeycomb.lock.json`. New tasks copy the selected source commit
and manifest digest into `meta.yml`; update/remove retain any referenced
generation. Loader fingerprints include managed locks and selected generations,
while a pinned task loads its exact descriptor directly from the managed store.

Consent is deliberately non-composable. JSON and non-TTY install/remove/update
require `--yes` for mutation. `--dry-run --json` on all three commands returns
the exact permission, diff, or retained/deletable-generation consequences
without requiring consent and without changing project state. An update that adds tools/directories/commands/domains,
credentials, dependencies, removes deny rules, or changes an incomparable
dependency additionally requires `--allow-escalation`. Dry-run validates and
reports content, dependency, security, and file categories without a project
write. Interactive refusal is a successful `cancelled` no-op; missing
non-interactive consent is `consent_required`/USAGE.

`list` emits orthogonal `origin`, `selection`, `integrity`, and
`catalog_visibility` fields, including tampered/malformed and retained entries.
Its offline visibility is `unknown_offline`. Publish copies only referenced
instructions, README, and `honeycomb.yml`, generates the canonical manifest,
runs preflight before GitHub calls, and uses a deterministic fork branch/body
file. A returned PR remains `pending_review` and `listed: false`.

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
<hive_state_path>/workflows/my-flow/README.md
<hive_state_path>/workflows/my-flow/honeycomb.yml
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

With `--json`, success is a `hive-workflow-new` (schema_version 1) document
containing `ok`, `id`, `descriptor_path`, `instruction_path`, and `next`. Typed
usage/config/git errors emit a `hive-workflow-new` (schema_version 1) JSON error
document with `ok: false`, `error_class`, `exit_code`, and `message`.

A bare or unknown workflow subcommand is a USAGE error (exit 64). Human output
lists the closed `new, install, list, update, remove, publish` verb set. With
`--json`, those subcommand-shape errors carry a structured `expected` array
such as `["new", "install", "list", "update", "remove", "publish"]`;
unknown subcommands also carry `value` with the rejected
token.

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
    permissions: read-only
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
- `architecture` — `inbox -> draft -> review(council) -> architecture`.

Every scaffold also renders `README.md` and `honeycomb.yml` with explicit
publish placeholders. Those assets do not alter local execution and the
existing `hive-workflow-new` JSON response remains unchanged.

A multi-stage template prints `edit: <id>/ (N stage instructions to fill in)`
pointing at the directory of instructions to define (the single-stage blank
still names its one `work.md`). An unknown `--template` is a USAGE error
listing the available names; with `--json` they ride the `expected` array.

## Backlinks

- [[cli]]
- [[commands/init]]
- [[modules/workflows]]
- [[commands/new]]
