---
title: hive new
type: command
source: lib/hive/commands/new.rb, templates/idea.md.erb
created: 2026-04-25
updated: 2026-04-25
tags: [command, capture, slug]
---

**TLDR**: `hive new PROJECT TEXT...` captures an idea: derives a slug, scaffolds `<hive-state>/stages/1-inbox/<slug>/idea.md`, and commits it on the `hive/state` branch.

## Usage

```
hive new PROJECT TEXT...
```

`PROJECT` must already be registered (via `hive init`); otherwise exit 1 with `"project not initialized"`. `TEXT...` is joined with single spaces and rendered into `idea.md`. Empty text raises `Hive::Error("missing task text")`.

## Slug derivation

`Commands::New#derive_slug` (`lib/hive/commands/new.rb:51`):

1. `unicode_normalize(:nfd)`, strip non-ASCII bytes.
2. Lowercase, collapse runs of non-alphanumerics to single spaces.
3. Take first 5 words → join with `-` → trim leading/trailing `-`.
4. Append `-<YYMMDD>-<4hex>` (random).
5. If the prefix doesn't start with `[a-z]` (e.g. all-Cyrillic input was filtered to empty), fall back to `task-<YYMMDD>-<4hex>`.

`SLUG_RE = /\A[a-z][a-z0-9-]{0,62}[a-z0-9]\z/` is the gate. `RESERVED_SLUGS` rejects: `head`, `fetch_head`, `orig_head`, `merge_head`, `master`, `main`, `origin`, `hive`. Any `..`, `/`, or `@` in the slug also rejects.

A `--slug` override is reserved on the constructor (`slug_override:`) but not exposed on the CLI in MVP.

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
   Body is the original text plus a trailing `<!-- WAITING -->` (so `1-inbox` shows ⏸ in `hive status`, even though `hive run` there is inert).
5. `Hive::GitOps#hive_commit(stage_name: "1-inbox", slug:, action: "captured")` on `hive/state`. Diff-empty commits are skipped silently.
6. Print `hive: captured <path>` and the `mv ... && hive run ...` next-step hint.

## Tests

- `test/integration/new_test.rb` covers slug derivation, reserved-slug rejection, idempotent collisions, and the captured commit.

## Backlinks

- [[cli]] · [[commands/run]] · [[stages/inbox]]
- [[modules/config]] · [[modules/git_ops]]
- [[state-model]]
