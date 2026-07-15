---
title: hive workflow
type: command
source: lib/hive/cli.rb, lib/hive/commands/workflow.rb, lib/hive/honeycomb/, templates/workflows/
created: 2026-06-21
updated: 2026-07-15
tags: [command, workflow, authoring, honeycomb, packages]
---

**TLDR**: `hive workflow` retains project authoring through `new` and adds immutable public honeycomb management through `install`, `list`, `update`, and `remove`. Managed packages preserve their nested `<id>/workflow.yml` root, are validated against an exact manifest inventory before mutation, record immutable source/integrity/selector/security state in `.honeycomb.lock`, and change package files plus the lock in one scoped `hive/state` transaction.

## Usage

```bash
hive workflow new my-flow
hive workflow new my-flow --template writing
hive workflow new my-flow --json
hive workflow install honeycomb/release-notes[@1.2.0]
hive workflow list [--remote|--outdated]
hive workflow update release-notes[@SELECTOR]
hive workflow update --all
hive workflow remove release-notes
```

## Published honeycombs

V1 fixes the source to `github.com/ivankuznetsov/honeycomb`; there is no
alternate-registry or authentication surface. `honeycomb/<name>` resolves the
catalog's exact `latest` release. `@selector` accepts an exact SemVer, complete
recorded package digest, full fetched commit, or unambiguous catalog SHA prefix.
Resolution checks the selected object is a commit and that catalog release tags
peel to the recorded SHA.

The registry root's `catalog.yml` is versioned and maps workflow names to an
exact latest version plus release records (`version`, `tag`, full `sha`, package
`digest`). Explicit network operations fetch a bare cache below
`Hive::Paths.cache_home`; a new catalog replaces the cached snapshot only after
validation. The package verifier reads raw Git tree/blob objects and accepts
only normal file blobs under `workflows/<id>/`.

Every package contains `manifest.yml`, an inventoried `workflow.yml`, and any
owned instruction/assets. Normalized POSIX-relative paths, SHA-256 file hashes,
tree equality, canonical package digest, descriptor ID/shape, and instruction
containment/UTF-8 are checked before the project is mutated. Symlinks,
submodules, special modes, path escapes, undeclared files, and built-in IDs are
rejected.

### Install and approval

Install prints immutable source/version/SHA, the file inventory, derived
permission/tool/directory exposure, shell-capable status, extracted shell-like
instructions, high-risk categories, and collision state before confirmation.
`--force` authorizes replacement of a dirty managed install or an unmanaged
authored collision; it never substitutes for confirmation and cannot replace a
built-in workflow. Non-TTY mutation always prints/emits the preview and requires
`--yes`.

Managed files land below `<hive_state_path>/workflows/<id>/`; `manifest.yml` is
validation metadata and is not materialized. `.honeycomb.lock` records source,
name, selector intent, immutable SHA/version/tag/digest, complete hashes/modes,
and the derived security report.

### List, update, and remove

Plain `list` reads the lock, installed files, and at most an existing cached
catalog. It never invokes the registry transport; absent cache data renders
update availability as `unknown`/JSON `null`. `list --remote` refreshes and
renders the catalog. `list --outdated` refreshes and renders only eligible local
updates. Those modes are mutually exclusive.

Untargeted updates follow current catalog latest for installs originating from
latest/version selectors. SHA/digest-origin installs are pinned no-ops until an
explicit selector repins them. Equal SHAs succeed without a transaction.
Comparable downgrades require an explicit selector and approval. Changing
packages show semantic permission differences, a distinct escalation marker,
complete unified diffs for all changed text instructions, and concise
descriptor/asset summaries; descriptor-, asset-, or metadata-only changes still
advance the pin. `--all` verifies and previews every candidate before one
approval and transaction.

Remove reports ownership and lock integrity before approval. Dirty installs
require `--force`. A missing or malformed lock permits only forced cleanup of a
canonical managed root, and the command still exits non-zero with a partial
result because clean ownership could not be proven.

### Transaction and JSON contracts

Under the project commit lock, a durable same-filesystem journal backs up the
exact package roots/authored collisions and prior lock, swaps the verified
revision, stages only workflow-owned pathspecs, and creates one `hive/state`
commit. A failure restores the previous files/lock/index state; a later mutation
recovers an interrupted pre-commit journal before proceeding.

Package commands emit the strict v1 schemas
`hive-workflow-install`, `hive-workflow-list`, `hive-workflow-update`, and
`hive-workflow-remove`. Success and typed error envelopes include the same
preview that drives human approval.

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

With `--json`, success is a `hive-workflow-new` (schema_version 1) document
containing `ok`, `id`, `descriptor_path`, `instruction_path`, and `next`. Typed
usage/config/git errors emit a `hive-workflow-new` (schema_version 1) JSON error
document with `ok: false`, `error_class`, `exit_code`, and `message`.

A bare or unknown workflow subcommand is a USAGE error (exit 64). Human output
uses the command prefix and lists the closed `new, install, list, update,
remove` set. With
`--json`, those subcommand-shape errors carry a structured `expected` array
of those verbs; unknown subcommands also carry `value` with the rejected
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
- [[modules/honeycomb]]
- [[modules/workflows]]
- [[commands/new]]
