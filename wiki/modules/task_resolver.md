---
title: Hive::TaskResolver
type: module
source: lib/hive/task_resolver.rb
created: 2026-04-25
updated: 2026-04-25
tags: [module, resolver, slug]
---

**TLDR**: Resolve a CLI TARGET (folder path or bare slug) to a `Hive::Task`. Shared between every agent-callable command (`approve`, `findings`, `accept-finding`, `reject-finding`) so the slug-lookup, ambiguity, realpath, and `--project` mismatch rules live in one place.

## Public surface

```ruby
task = Hive::TaskResolver.new(target, project_filter: nil).resolve
# Returns a Hive::Task or raises a typed Hive::Error subclass.
```

## Resolution rules

1. **Path-shaped TARGET** (contains `/` or starts with `~`/`.`): `File.expand_path` then `File.realpath`. The realpath flows into `Hive::Task.new`, whose `PATH_RE` validates that the result still looks like `<root>/.hive-state/stages/<N>-<name>/<slug>`. A slug-named symlink pointing outside the `.hive-state` hierarchy is therefore rejected at the PATH_RE check, not silently followed.
2. **Bare slug**: searched across registered projects (filtered by `--project` if given) for an unambiguous match. The search walks every stage directory under each project's `.hive-state/stages/`.
3. **Ambiguity**:
   - **0 hits** → `Hive::InvalidTaskPath` (exit 64). Message includes the optional `--project <name>` hint when `--project` was set.
   - **1 hit** → realpath the resolved folder and return.
   - **>1 hits across projects** → `Hive::AmbiguousSlug` (exit 64) with structured `candidates: [{project, stage, folder}, …]` for the JSON error envelope. Caller passes `--project <name>` to disambiguate.
   - **>1 hits within one project** (slug exists in two stages) → also `Hive::AmbiguousSlug`, with a message naming the conflicting stages. Caller passes an absolute folder path; `--to` selects the destination, not the source, so it cannot disambiguate this case.

## `--project` validation

When the caller passes both an absolute folder path AND `--project NAME`, the path's project root must match the named project. Mismatch raises `Hive::InvalidTaskPath`. Without `--project`, no validation runs — the path is authoritative.

## Why a class, not a module function?

`@target` and `@project_filter` are referenced from every helper method. Wrapping them in an instance keeps the public surface a single `.resolve` call and avoids passing the same two keyword arguments through five helpers.

## Consumers

| File | Use |
|------|-----|
| `lib/hive/commands/approve.rb` | `Hive::TaskResolver.new(@target, project_filter: @project_filter).resolve` in `do_call`. |
| `lib/hive/commands/findings.rb` | Same pattern. |
| `lib/hive/commands/finding_toggle.rb` | Same pattern, used by both `accept-finding` and `reject-finding`. |

## Backlinks

- [[commands/approve]] · [[commands/findings]]
- [[modules/task]] — the `Hive::Task` value object the resolver returns
- [[modules/stages]] — the stage list the slug search walks
