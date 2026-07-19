---
title: hive workflow
type: command
source: lib/hive/cli.rb, lib/hive/commands/workflow.rb, templates/workflows/
created: 2026-06-21
updated: 2026-07-19
tags: [command, workflow, authoring, honeycomb, registry]
---

**TLDR**: `hive workflow` manages two ownership domains: `new` scaffolds trusted project-authored descriptors, while `install`, `list`, `update`, and `remove` manage immutable reviewed Honeycomb generations; `publish` validates an authored descriptor and opens a registry PR whose status is only `pending_review`.

## Usage

```bash
hive workflow new my-flow
hive workflow new my-flow --template writing
hive workflow new my-flow --json
hive workflow install honeycomb/repo-brief --yes
hive workflow install honeycomb/repo-brief --yes --allow-escalation \
  --mapping stages.research=codex,model=gpt-5.6-sol,effort=high \
  --input-binding GSC_TOKEN=PRODUCTION_GSC_TOKEN
hive workflow install honeycomb/repo-brief --dry-run --json
hive workflow list --json
hive workflow update repo-brief --dry-run --json
hive workflow update repo-brief --yes --allow-escalation
hive workflow remove repo-brief --yes
hive workflow remove repo-brief --dry-run --json
hive workflow publish my-flow --version 1.0.0
```

## Honeycomb Lifecycle

The official-source grammar is closed: `honeycomb/NAME`, a catalog semantic
version, or its catalog-listed full upstream source SHA. Mutable refs,
abbreviated/unlisted commits, arbitrary namespaces, and arbitrary repositories
fail resolution. Bare discovery/latest considers only listed/discoverable
entries; exact soft-hidden and yanked versions remain resolvable, while revoked
versions fail closed with advisory IDs. Install materializes the immutable
package directory from the pinned catalog commit itself and validates canonical
`manifest.yml`, `release_sha256`, complete payload inventory/hashes, catalog
binding, static diagnostics, and every descriptor-selected runner before
mutation. The review head is audit identity and `source_sha` is upstream
provenance, not install-tree Git identity.

Managed storage is
`workflows/NAME/versions/CATALOG_COMMIT/` plus
`workflows/NAME/configurations/CONFIGURATION_DIGEST.json` plus
`workflows/NAME/honeycomb.lock.json`. Install enumerates each active stage,
reviewer, and reviser, shows one complete suggested mapping summary, and lets an
interactive operator accept the defaults or edit each slot. New tasks copy the
catalog commit, release digest, and configuration digest into `meta.yml`;
update/remove retain every identity referenced by an in-flight task. When the
selected pointer is a legacy schema-v1 lock, Hive derives its compatibility
configuration from the project's effective agent profiles and durably stores
the snapshot before writing task metadata, so a later schema-v2 update cannot
strand the task's configuration pin.

Package descriptors cannot select agent/model/effort; immutable installation
configuration overlays those choices in memory. Planning/development defaults
follow the project's init choices and reviewer roles cycle configured review
agents. Updates preserve only slots whose stable ID, role, and
`mapping_contract` match. Profile drift or contract changes require explicit
remapping. A non-null model or effort pin is accepted only when the selected
profile can translate it into native launch arguments; unsupported suggested
defaults remain unset, while an explicit unsupported pin fails before managed
state is mutated. JSON schema v2 discloses the mapping, configuration digest,
actor policy fingerprints, and optional-input availability without values.
Human previews likewise name each optional input, its authorized stable slots,
and its environment-variable binding while replacing every available value
with `[redacted]`. A compatible binding from the installed configuration wins
over a new same-name environment suggestion during update; an explicit
`--input-binding` wins over both. Rebinding is disclosed as a configuration
change before ordinary update consent, while an authorization-scope gain is an
actor-policy change and therefore uses the separate escalation consent.
Re-running install or update against the selected catalog commit resolves these
options against the selected snapshot: it is a no-op only when the resulting
configuration digest also matches. Otherwise Hive admits and activates a new
immutable configuration snapshot against the same generation using the full
source, manifest, and configuration baseline as its concurrency check.

The catalog permission union remains coarse disclosure. Runtime admission and
spawn use exact actor permissions. Unbounded installs require both ordinary
consent and `--allow-escalation`; this includes explicit `yolo`, scoped shell,
and unqualified scoped file-write actors. Registry manifests must conservatively
disclose those actors as high risk with the corresponding wildcard capability
surface. Actor-level policy redistribution also escalates when the package
union is unchanged. `--input-binding NAME=ENV_NAME`
stores only an environment reference, and absent optional inputs do not block
prompt-only execution. `publish` remains a legacy submission producer.

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
JSON schema v2 adds the selected configuration digest, its stable-slot
agent/model/effort mappings and fingerprints, and each declared optional
input's authorized slots, environment-variable binding, and availability.
Environment values are never emitted. Task-retained rows expose their pinned
configuration digest when present but omit active mapping/input details;
built-in and authored rows keep their generation-free shape. Its offline
visibility is `unknown_offline`. Publish copies only referenced instructions,
README, and `honeycomb.yml`, generates the legacy canonical manifest, runs
preflight before GitHub calls, and uses a deterministic fork branch/body file.
A returned PR remains `pending_review` and `listed: false`.

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
