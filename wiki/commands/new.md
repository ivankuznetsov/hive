---
title: hive new
type: command
source: bin/hive, lib/hive/commands/new.rb, templates/idea.md.erb
created: 2026-04-25
updated: 2026-07-21
tags: [command, capture, slug, task-id, commit-lock, workflow, dependencies, base-branch]
---

**TLDR**: `hive new PROJECT TEXT...` captures an idea: derives a slug, resolves the effective workflow (`--workflow` override, project `default_workflow`, then `coding`), scaffolds the descriptor's entry-stage folder plus state file and `meta.yml`, commits it on the `hive/state` branch, and best-effort starts display-name generation after the commit.

## Usage

```
hive new PROJECT [--workflow NAME] [--base BRANCH] [--depends-on ID_OR_SLUG_OR_PROJECT_SLUG] TEXT...
```

`PROJECT` must already be registered (via `hive init`); otherwise exit 1 with `"project not initialized"`. `TEXT...` is joined with single spaces and rendered into the workflow entry state's file. Empty text raises `Hive::Error("missing task text")`. `--workflow NAME` is validated against `Hive::Workflows::Registry`; unknown names fail before seeding a task and list valid names.

`--depends-on` accepts exactly one scalar reference. A bare slug or numeric id
is scoped to the new task's project; `other-project:task-slug` is the only
cross-project form. Lists, mappings, blanks, malformed separators, and
`project:<numeric-id>` are rejected. Creation validates syntax and stores the
normalized value; existence, repository identity, cycles, plan agreement, and
gate reachability are revalidated at status/dispatch boundaries.

`--base BRANCH` is structured input for a workflow whose terminal agent
declares `workspace: worktree` plus `handoff: draft_pr`. Hive validates and
stores it as `base_branch:`; it is never inferred from the task prose. When
omitted for such a workflow, Hive records the project's configured Git default
branch (or Git's detected default when configuration is blank). Other workflows
reject `--base`, and draft-PR workflows reject `--depends-on` stacking in v1.

The executable wrapper lifts standalone allow-listed `new` options from anywhere
outside an explicit `--`: `--workflow NAME`, `--workflow=NAME`, `--base BRANCH`,
`--base=BRANCH`,
`--depends-on VALUE`, `--depends-on=VALUE`, and Thor-style JSON booleans. The
first remaining positional is `PROJECT`; the rest remains literal task text
behind a `--` sentinel. That makes the canonical workflow-authoring hint work:
`hive new PROJECT --workflow my-flow "<your idea>"` pins the task instead of
capturing `--workflow my-flow` in `idea.md`. `--json` is lifted too, but `new`
still emits the plain text surface below.

Only the closed allow-list is lifted. `hive new PROJECT add --help docs`
captures `add --help docs` instead of rendering help,
`hive new PROJECT literal --json=yes text` captures the malformed-looking JSON
assignment literally instead of failing the wrapper boolean grammar, and
`hive new PROJECT --foo idea` captures `--foo idea` rather than treating `--foo`
as a command option. A `--workflow` substring inside one quoted argv element
also remains literal task text.

The human stdout surface is still plain text:

```
hive: captured <task>/idea.md
next: mv <task> <hive-state>/stages/<next-stage>/ && hive run <id-or-task>
```

When `Hive::TaskCounter.next_or_nil` allocates an id, the final token in the next-step hint is that numeric id. If the counter lock stays busy through its timeout, capture still succeeds and the hint falls back to `<task>`.

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
3. Parse `--depends-on` through `Hive::Dependencies.parse_reference`, then resolve the effective workflow. A CLI override wins over project `default_workflow`, which wins over `coding`. Draft-PR workflows reject dependency stacking and resolve an explicit or project-default `base_branch` before creating the task folder.
4. `mkdir -p <hive_state_path>/stages/<entry-stage>/<slug>` — exits 1 with `"slug collision"` if the directory already exists (rare; user retries to regenerate the random suffix).
5. Write the entry state from `templates/idea.md.erb`. Frontmatter:
   ```
   ---
   slug: <slug>
   created_at: <UTC-ISO>
   original_text: |
     <indented text>
   ---
   ```
   Body is the original text, or `body_override:` for programmatic rich-input callers, plus a trailing marker. Coding keeps `<!-- WAITING -->` for the historical inbox path. Non-coding workflows remove the waiting marker; if the entry stage is `kind: :inert`, capture writes `<!-- COMPLETE -->` so the real `hive approve` safety gate can move it forward.
6. If attachments were supplied, copy them into `assets/` beside the state file.
7. Allocate a monotonic task id via `Hive::TaskCounter.next_or_nil` and write `meta.yml` via `Hive::TaskMeta.write(task_dir, id:, slug:, display_name: nil, workflow: ...)`. Counter lock contention is fail-soft: id becomes null, but `meta.yml` is still written and the capture continues.

Managed selection is resolved once under the store's stable-read lock. Project
configuration is loaded lazily only for a legacy v1 selection that must derive
its compatibility snapshot; current v2 locks and unmanaged workflows do not
pay that validation cost.
8. Take `Hive::Lock.with_commit_lock(hive_state_path)`, then run `Hive::GitOps#hive_commit(stage_name: entry_stage.dir, slug:, action: "captured")` on `hive/state`. The lock only covers the short `git add && git commit` window, serializing concurrent web/TUI/bot `hive new` captures so git's shared worktree index lock is not raced. Diff-empty commits are skipped silently.
9. Best-effort spawn `hive generate-name <task_dir>` in its own process group, appending stdout/stderr to `<state_home>/logs/display-name.log`. Spawn or wait errors are swallowed so capture is not blocked by display-name generation; if the task still has a blank sidecar name later, a running daemon retries the same command from `Hive::Daemon::DisplayNameBackfiller`.
10. Print `hive: captured <path>` and the descriptor-derived `mv ... && hive run ...` next-step hint.

## Task metadata

Each captured task now gets `<task>/meta.yml`:

```yaml
id: 1
slug: add-inbox-filter-260603-abcd
display_name:
depends_on: api:base-task-260716-abcd
base_branch: main
```

`id` comes from the process-global counter at `Hive::Paths.task_counter_path` (`<state_home>/task-counter.yml`), protected by `<state_home>/.task-counter.lock`. `display_name` starts nil; `Hive::Task#display_label` falls back to the slug until name generation succeeds. `depends_on` is omitted when not supplied and remains the authoritative scheduling declaration when present. `workflow:` is omitted for plain coding captures, but set for explicit overrides and non-coding project defaults. `base_branch:` is omitted outside draft-PR workflows and is authoritative when present.

## Tests

- `test/integration/new_test.rb` covers slug derivation, dependency slug/numeric/`project:slug` grammar, reserved-slug rejection, collisions, rich capture, workflow pinning, counter-lock fallback, commit locking, and the captured commit.
- `test/integration/new_wrapper_argv_test.rb` drives the real `bin/hive` subprocess and pins wrapper-only argv behavior: canonical `PROJECT --workflow ID "text"`, before-project and trailing options, `--workflow=ID`, combined dependency/workflow flags, literal `--workflow` substrings, lifted-but-plain `--json`, missing text after lifted options, and unrecognized options as task text.
- `test/integration/tui_new_idea_attachments_test.rb` covers the TUI-internal rich submit path.

## Backlinks

- [[cli]] · [[commands/run]] · [[stages/inbox]]
- [[modules/config]] · [[modules/git_ops]]
- [[state-model]]
