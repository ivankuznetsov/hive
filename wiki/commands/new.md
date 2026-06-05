---
title: hive new
type: command
source: lib/hive/commands/new.rb, templates/idea.md.erb
created: 2026-04-25
updated: 2026-06-03
tags: [command, capture, slug, task-id]
---

**TLDR**: `hive new PROJECT TEXT...` captures an idea: derives a slug, scaffolds `<hive-state>/stages/1-inbox/<slug>/idea.md` plus `meta.yml`, commits it on the `hive/state` branch, and best-effort starts display-name generation after the commit.

## Usage

```
hive new PROJECT TEXT...
```

`PROJECT` must already be registered (via `hive init`); otherwise exit 1 with `"project not initialized"`. `TEXT...` is joined with single spaces and rendered into `idea.md`. Empty text raises `Hive::Error("missing task text")`.

The human stdout surface is still plain text:

```
hive: captured <task>/idea.md
next: mv <task> <hive-state>/stages/2-brainstorm/ && hive run <id-or-task>
```

When `Hive::TaskCounter.next!` allocates an id, the final token in the next-step hint is that numeric id. If the counter lock is busy long enough to raise `Hive::ConcurrentRunError`, capture still succeeds and the hint falls back to `<task>`.

The CLI argv surface is unchanged. Internally, `Hive::Commands::New.new(project, text, body_override: nil, attachments: [[abs_path, dest_name], …])` also supports the TUI rich composer (the `attachments:` argument is an array of `[src_abs_path, dest_filename]` tuples, not a flat array of paths):

- `call!` performs the capture without calling `exit`, raising typed `ProjectNotFound`, `InvalidSlugError`, or `SlugCollisionError` for TUI callers.
- `body_override:` replaces the markdown body while frontmatter `original_text:` and slug derivation still use `text`.
- `attachments:` is an array of `[src_abs_path, dest_filename]`; files copy into `<task>/assets/<dest_filename>` before `Hive::GitOps#hive_commit` recursively adds the task folder (see [[modules/git_ops]]). Dest-filename validation raises `InvalidAttachmentError` on empty strings, embedded path separators, AND the two `File.basename`-fixed-point names `.` and `..` (both would otherwise slip past `name == File.basename(name)` and either overwrite `assets/` itself or escape via `FileUtils.cp`'s path-join).

Normal `hive new PROJECT TEXT...` still creates no `assets/` directory.

## Slug derivation

`Commands::New#derive_slug` (`lib/hive/commands/new.rb:51`):

1. `unicode_normalize(:nfd)`, strip non-ASCII bytes.
2. Lowercase, collapse runs of non-alphanumerics to single spaces.
3. Take first 5 words → join with `-` → trim leading/trailing `-`.
4. Cap the prefix at `DERIVED_PREFIX_MAX = 51` chars (12 reserved for the `-YYMMDD-XXXX` suffix under the 64-char `SLUG_RE` ceiling), re-stripping any trailing `-`.
5. Append `-<YYMMDD>-<4hex>` (random).
6. If the prefix doesn't start with `[a-z]` (e.g. all-Cyrillic input was filtered to empty), fall back to `task-<YYMMDD>-<4hex>`.

`SLUG_RE = /\A[a-z][a-z0-9-]{0,62}[a-z0-9]\z/` is the gate. `RESERVED_SLUGS` rejects: `head`, `fetch_head`, `orig_head`, `merge_head`, `master`, `main`, `origin`, `hive`, `hive-state`, `hive_state`, `state`. Any `..`, `/`, or `@` in the slug also rejects.

A `slug_override:` keyword is reserved on the constructor but not exposed as a CLI flag in MVP — the warning text on validation failure asks the user to rephrase the task text rather than pointing at a non-existent `--slug` option.

## Steps performed

1. `Hive::Config.find_project(name)` → resolve `hive_state_path`. Exits 1 if not found.
2. Validate slug → exits 1 with `"invalid slug"` or `"reserved or unsafe slug"` on failure.
3. `mkdir -p <hive_state_path>/stages/1-inbox/<slug>` — exits 1 with `"slug collision"` if the directory already exists (rare; user retries to regenerate the random suffix).
4. Write `idea.md` from `templates/idea.md.erb`. Frontmatter:
   ```
   ---
   slug: <slug>
   created_at: <UTC-ISO>
   original_text: |
     <indented text>
   ---
   ```
   Body is the original text, or `body_override:` for programmatic rich-input callers, plus a trailing `<!-- WAITING -->` (so `1-inbox` shows ⏸ in `hive status`, even though `hive run` there is inert).
5. If attachments were supplied, copy them into `assets/` beside `idea.md`.
6. Allocate a monotonic task id via `Hive::TaskCounter.next!` and write `meta.yml` via `Hive::TaskMeta.write(task_dir, id:, slug:, display_name: nil)`. Counter lock contention is fail-soft: id becomes null, but `meta.yml` is still written and the capture continues.
7. `Hive::GitOps#hive_commit(stage_name: "1-inbox", slug:, action: "captured")` on `hive/state`. Diff-empty commits are skipped silently.
8. Best-effort spawn `hive generate-name <task_dir>` in its own process group, appending stdout/stderr to `<state_home>/logs/display-name.log`. Spawn or wait errors are swallowed so capture is not blocked by display-name generation.
9. Print `hive: captured <path>` and the `mv ... && hive run ...` next-step hint.

## Task metadata

Each captured task now gets `<task>/meta.yml`:

```yaml
id: 1
slug: add-inbox-filter-260603-abcd
display_name:
```

`id` comes from the process-global counter at `Hive::Paths.task_counter_path` (`<state_home>/task-counter.yml`), protected by `<state_home>/.task-counter.lock`. `display_name` starts nil; `Hive::Task#display_label` falls back to the slug until a later writer fills it.

## Tests

- `test/integration/new_test.rb` covers slug derivation, reserved-slug rejection, idempotent collisions, rich body/attachment capture, `meta.yml` capture, counter-lock fallback, display-name subprocess spawning, and the captured commit.
- `test/integration/tui_new_idea_attachments_test.rb` covers the TUI-internal rich submit path.

## Backlinks

- [[cli]] · [[commands/run]] · [[stages/inbox]]
- [[modules/config]] · [[modules/git_ops]]
- [[state-model]]
