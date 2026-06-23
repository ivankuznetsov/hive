---
title: Hive::TaskResolver
type: module
source: lib/hive/task_resolver.rb
created: 2026-04-25
updated: 2026-06-23
tags: [module, resolver, slug, task-id]
---

**TLDR**: Resolve a CLI TARGET (folder path, bare slug, or numeric task id) to a `Hive::Task`. Shared between task-target commands so path validation, slug/id lookup, ambiguity, realpath, `--project`, and stage-filter rules live in one place.

## Public surface

```ruby
task = Hive::TaskResolver.new(target, project_filter: nil, stage_filter: nil).resolve
# Returns a Hive::Task or raises a typed Hive::Error subclass.
```

## Resolution rules

1. **Path-shaped TARGET** (contains `/` or starts with `~`/`.`): `File.expand_path` then `File.realpath`. The realpath flows into `Hive::Task.new`, whose `PATH_RE` validates that the result still looks like `<root>/.hive-state/stages/<N>-<name>/<slug>`. A slug-named symlink pointing outside the `.hive-state` hierarchy is therefore rejected at the PATH_RE check, not silently followed.
2. **Numeric id** (`/\A\d+\z/`): searched across registered projects by reading each candidate task's `meta.yml` via `Hive::TaskMeta.read(folder)[:id]`. `--project` and `stage_filter` narrow the scan the same way slug lookup does. A missing match raises `Hive::InvalidTaskPath` with `"no task folder for id <id>"`.
3. **Bare slug**: searched across registered projects (filtered by `--project` if given) for an unambiguous match. The search walks every stage directory under each project's `.hive-state/stages/`, or only `stage_filter` when one is provided.
4. **Ambiguity**:
   - **0 hits** → `Hive::InvalidTaskPath` (exit 64). Message includes the optional `--project <name>` hint when `--project` was set.
   - **1 hit** → realpath the resolved folder and return.
   - **>1 hits across projects** → `Hive::AmbiguousSlug` (exit 64) with structured `candidates: [{project, stage, folder}, …]` for the JSON error envelope. Caller passes `--project <name>` to disambiguate.
   - **>1 hits within one project** (slug exists in two stages) → also `Hive::AmbiguousSlug`, with a message naming the conflicting stages. Caller passes `--stage <stage>` on generic commands, `--from <stage>` on workflow verbs, or an absolute folder path.
   - **>1 numeric-id hits** → `Hive::AmbiguousSlug` with message `"task id <id> is duplicated (...); repair duplicate meta.yml ids"` and structured candidates. Duplicate ids should not happen through `Hive::TaskCounter`, so this is a repair signal for hand-edited or copied sidecars.

## `--project` validation

When the caller passes both an absolute folder path AND `--project NAME`, the path's project root must match the named project. Mismatch raises `Hive::InvalidTaskPath`. Without `--project`, no validation runs — the path is authoritative.

## Stage filter validation

`stage_filter:` accepts either full stage directories (`4-execute`) or short names (`execute`) through `Hive::Stages.resolve`. For bare slugs it narrows the search. For folder paths it validates that the exact path is already at the requested stage.

## Why a class, not a module function?

`@target`, `@project_filter`, and `@stage_filter` are referenced from helper methods. Wrapping them in an instance keeps the public surface a single `.resolve` call and avoids passing the same keywords through several helpers.

## Consumers

| File | Use |
|------|-----|
| `lib/hive/commands/run.rb` | Resolves slug, numeric id, or folder targets before dispatching stage runners. |
| `lib/hive/commands/stage_action.rb` | Resolves workflow-verb targets, using `--from` as stage filter when present. |
| `lib/hive/commands/drop.rb` | Resolves path-shaped and numeric-id targets before Drop snapshots active/archive stage dirs for deletion/refusal. |
| `lib/hive/commands/approve.rb` | Resolves approve targets; `--from` can disambiguate same-slug stages while preserving idempotency checks. |
| `lib/hive/commands/generate_name.rb` | Resolves task targets before display-name generation. |
| `lib/hive/commands/findings.rb` | Resolves findings targets, with optional `--stage`. |
| `lib/hive/commands/finding_toggle.rb` | Same pattern, used by both `accept-finding` and `reject-finding`. |

## Backlinks

- [[commands/approve]] · [[commands/generate-name]] · [[commands/findings]]
- [[modules/task]] — the `Hive::Task` value object the resolver returns
- [[modules/stages]] — the stage list the slug search walks
