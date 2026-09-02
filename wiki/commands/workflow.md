---
title: hive workflow
type: command
source: lib/hive/cli.rb, lib/hive/commands/workflow.rb, templates/workflows/
created: 2026-06-21
updated: 2026-09-02
tags: [command, workflow, authoring, validation, human-stage, honeycomb, registry, archive, retention]
---

**TLDR**: `hive workflow` manages two ownership domains: `new` scaffolds trusted project-authored descriptors, while `install`, `list`, `update`, and `remove` manage immutable reviewed Honeycomb generations. `publish` locally builds and validates immutable Honeycomb v1 package bytes, binds a confirmed release digest to one recoverable non-draft review PR, and reconciles its PR/catalogue lifecycle without adding a public status command.

## Usage

```bash
hive workflow new my-flow
hive workflow new my-flow --template research
hive workflow new my-flow --json
hive workflow validate my-flow --json
hive workflow commit my-flow
hive workflow install honeycomb/repo-brief
hive workflow install honeycomb/repo-brief \
  --mapping stages.research=codex,model=gpt-5.6-sol,effort=high \
  --input-binding GSC_TOKEN=PRODUCTION_GSC_TOKEN
hive workflow install honeycomb/repo-brief --dry-run --json
hive workflow list --json
hive workflow update repo-brief --dry-run --json
hive workflow update repo-brief --yes --allow-escalation
hive workflow remove repo-brief --yes
hive workflow remove repo-brief --dry-run --json
hive workflow publish my-flow --version 1.0.0 --dry-run --json
hive workflow publish my-flow --version 1.0.0 \
  --expected-release-digest <confirmed-release-digest> --json
```

## Honeycomb Lifecycle

`install`, `list`, `update`, and `remove` are the 0.x command-compatible
projection of Hive's managed-module lifecycle. [[modules/workflow_package]] is
the authoritative source for package trust, immutable storage, configuration
resolution, task provenance, disclosure versus exact runtime enforcement, and
publication recovery. This command page owns only the operator-visible CLI
contract.

The accepted source forms are `honeycomb/NAME`, a catalog semantic version, or
a catalog-listed full upstream source SHA. Mutable refs, abbreviated or
unlisted commits, arbitrary namespaces, and arbitrary repositories fail
resolution. Exact soft-hidden or yanked versions remain addressable; revoked
versions fail closed with their advisory IDs.

`install` and `update` accept repeatable
`--mapping SLOT=AGENT[,model=MODEL][,effort=EFFORT]` and
`--input-binding NAME=ENV_NAME` flags. Human preview names every executable
slot and optional input, reports absent model/effort pins as `unpinned`, and
redacts all environment values. `--dry-run --json` validates and reports the
candidate, mapping/input changes, permission diff, retained-task migrations,
and deletable generations without writing project state.

Install and update immediately migrate retained tasks to the selected
generation by stable semantic stage name, atomically with pointer activation.
A removed occupied stage or live task lock leaves the previous selection
executable; `remove` refuses while retained tasks still name the workflow.
Stale nonterminal dispatch requests are removed, and identity fencing rejects
deliveries that raced the cutover.

Install verifies the immutable reviewed package, discloses its network,
filesystem, secret, and actor-mapping access, and proceeds without `--yes` or
`--allow-escalation`. `--dry-run --json` remains an optional no-write preview,
not a prerequisite. Update and remove retain their `--yes` boundary; an update
that grows permissions separately requires `--allow-escalation`. Interactive
refusal for those verbs is a successful `cancelled` no-op, while missing
non-interactive consent remains a USAGE error with
`error_kind: consent_required`.

`list --json` reports orthogonal `origin`, `selection`, `integrity`, and
`catalog_visibility` fields. Managed rows add the selected configuration
digest, stable-slot mapping identities and fingerprints, and optional-input
bindings/availability without values. Diagnostic retained rows expose pinned
configuration identity without presenting it as the active selection; runtime
does not dispatch them until `hive migrate` converges the task. Offline catalog
visibility is `unknown_offline`.

Activation or migration commit failures roll back the selected pointer and
retained-task filesystem changes. Once the commit succeeds, later cleanup or
cache refresh failures become `warnings`, which Hive Web renders after redirect.
A changed concurrent selection is a retryable `ConcurrentRunError`, while an
exact selected generation and configuration returns `already_installed`.

## Publish command

`publish ID --version VERSION` requires the CLI id to match the authored
descriptor and `VERSION` to be strict SemVer. Adjacent `honeycomb.yml` supplies
the author, license, minimum Hive version, immutable source identity, and closed
asset list; `README.md` must replace every required section placeholder.
`x-hive` authoring metadata may declare tools, prompt assets, and optional
inputs for stable actor slots.

`--dry-run --json` builds and validates the complete local package and returns
`state: validated`, the package/release digests, and
`freshness: not_checked` without Git, GitHub, receipt, or catalog effects. A
real submission must pass the confirmed full digest with
`--expected-release-digest`; a different digest for the same registry/name/version
is an immutable conflict.

Schema v2 reports `pending_review`, `merged_pending_listing`, `listed`, or
`closed_unmerged`, independently of `freshness: current|cached`. Publication
ends at registry review: this command never merges, approves, closes,
force-pushes, deletes remote state, or edits the catalog. The immutable builder,
receipt, PR-identity, checkout-custody, and retry reconciliation rules are owned
by [[modules/workflow_package]].

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

Pre-dispatch argv-shape failures select the requested subcommand's schema:
`hive-workflow-install.v1`, `hive-workflow-list.v1`,
`hive-workflow-remove.v1`, `hive-workflow-update.v1`,
`hive-workflow-publish.v1`, or `hive-workflow-validate.v1` (with
`valid: false` and the rejected `id`), defaulting to
`hive-workflow-new.v1`. All use `error_kind: "usage"`. Pre-dispatch failures
of `hive decide` use `hive-decide.v1` with
`error_kind: "invalid_task_path"`.

## Generated Descriptor

```yaml
id: my-flow
archive_visibility_retention_days: 3
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

Every generated descriptor declares
`archive_visibility_retention_days: 3`. Authors may replace `3` with another
positive integer (full 24-hour periods) or exact lowercase `never`. Omitted
legacy fields also resolve to `3`; explicit `null` and every other form are
rejected. The setting changes ordinary visibility only and never removes a
task from the dedicated archive.

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
- `research` — `inbox -> gather -> synthesize -> report -> done`.

The former `architecture` and `writing` samples are now full reviewed
Honeycomb packages. Passing either retired name returns its exact
`hive workflow install honeycomb/<name>` command instead of scaffolding a
reduced owner-authored copy.

Every scaffold also renders `README.md` and `honeycomb.yml` with explicit
publish placeholders. Those assets do not alter local execution and the
existing `hive-workflow-new` JSON response remains unchanged.

A multi-stage template prints `edit: <id>/ (N stage instructions to fill in)`
pointing at the directory of instructions to define (the single-stage blank
still names its one `work.md`). An unknown `--template` is a USAGE error
listing the available names; with `--json` they ride the `expected` array.

## Read-only validation and human outcomes

`hive workflow validate ID --json` resolves authored descriptors, built-ins,
and the currently selected managed generation through direct read-only
lookups. It does not acquire the managed mutation lock, reconcile a selected
pointer, or replay/clear a transaction journal. It validates descriptor YAML,
referenced instructions, stage inputs/state files, automatic edges, and
descriptor-declared human outcomes without creating a task or writing project
or Hive state. The `hive-workflow-validate.v1` result reports the descriptor
origin/path, ordered stages, instruction paths, automatic edges, human
outcomes, and `valid`. Invalid input uses the same command-specific envelope
with diagnostics, including malformed `--json` invocations.

Project-authored descriptors may declare a durable `kind: human` stage:

```yaml
- name: approval
  kind: human
  state_file: approval.md
  input: draft.md
  outcomes:
    approve:
      complete: true
      artifact: draft.md
    reject:
      to: draft
```

Every outcome has exactly one action: `complete: true` with a required
non-empty artifact basename, or `to: STAGE`. Human stages reject
agent/model/permissions/instruction/runner settings and are never dispatched
by the daemon. Apply a decision with
`hive decide TASK OUTCOME --from STAGE --decision-id DECISION_ID [--note TEXT] [--json]`.
The waiting `hive run --json` response supplies that visit-specific ID. The
expected stage and decision identity make matching retries no-ops and reject
stale or conflicting decisions. Matching concurrent retries are rechecked
under the decision lock and return one apply plus idempotent no-ops. Completing
outcomes accept only a no-follow regular file inside the task folder. A
self-targeting outcome records the decision, leaves the task in place, and
mints a fresh waiting identity instead of reporting a false move. Human state
files are also read no-follow with inode verification. A completing outcome
writes its decision record and `completed_at` from one clock, classifies as
archived, and participates in the descriptor's archive visibility retention;
commit failure or interruption rolls both files back.

Create-only natural-language requests are handled by the canonical `/hive`
skill's `hive-workflow-creator` route. It gates on the installed version,
inventories IDs, scaffolds only through this command (or the minimal init path),
edits only returned new paths, validates here, commits the populated descriptor
and instruction directory with `hive workflow commit ID`, reports all defaults, and creates no
task unless the original request explicitly asks for one. The populated-graph
commit is required because `workflow new` commits only the initial scaffold.
Both `workflow validate` and minimal-init preview bypass startup scheduler
reconciliation, preserving their strict no-write contract. Scaffold collision
checks treat dangling descriptor or instruction symlinks as occupied paths.
Creation claims the instruction directory and descriptor with exclusive
filesystem operations; rollback removes only paths claimed by that invocation,
so a concurrent or raced scaffold is never overwritten or deleted.
If a scaffold commit fails after staging, Hive resets those exact index
pathspecs under the commit lock before removing the generated files.

## Backlinks

- [[cli]]
- [[commands/init]]
- [[modules/workflows]]
- [[modules/workflow_package]]
- [[commands/new]]
