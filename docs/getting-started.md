# Getting Started

This page gets you through the first operator-driven loop: install Hive, attach it to a real project, capture an idea, run brainstorm, and promote the task to plan. The full pipeline can take longer because agents do real work; five minutes is the active time you spend driving the first handoffs.

The example is xbookmark, a real Hive dogfood task that finished as [xbookmark PR #1](https://github.com/ivankuznetsov/xbookmark/pull/1). The original task lived in a local `.hive-state/` branch, so this guide quotes the idea text and links to the replay artefacts committed in this repo.

## Prerequisites

You need Ruby 3.4, git >= 2.40, `claude` authenticated, `codex` installed for the default execute agent, `gh` authenticated, and a git checkout you can modify. The commands below use `~/Dev/xbookmark`; substitute your own project path and project name when running against another repo.

## Step 1 - Install

```bash
git clone https://github.com/ivankuznetsov/hive ~/Dev/hive && cd ~/Dev/hive && bundle install && mkdir -p ~/.local/bin && ln -sf ~/Dev/hive/bin/hive ~/.local/bin/hive
```

If `~/.local/bin` is not on your `PATH`, put the symlink in a directory that is before running the next step. The `-sf` form will overwrite an existing `hive` at the target path, so check `command -v hive` first if you already have one installed.

```bash
hive --version
hive daemon install
```

## Step 2 - Attach Hive To A Project

```bash
cd ~/Dev/xbookmark
hive init .
```

`hive init` creates `.hive-state/` as a worktree of the orphan `hive/state` branch, registers the project in `~/Dev/hive/config.yml`, and scaffolds the stage folders. Read the storage details in [docs/architecture.md#storage-layout](architecture.md#storage-layout).

## Step 3 - Capture The Idea

```bash
hive new xbookmark "I want to create a service that will connect to my X account and collect all the bookmarks, then use llm-wiki to create a knowledge graph from them."
```

The new task is now in `1-inbox/<slug>/idea.md`. Hive stores the text you typed verbatim, typos and all.

> What xbookmark actually had: the original idea.md (sampled in [docs/assets/xbookmark-walkthrough.txt](assets/xbookmark-walkthrough.txt) since it lives on xbookmark's local `hive/state` branch) looked like this, with the typo `conenct` preserved from the original prompt:
>
> ```yaml
> slug: i-want-to-create-a-260504-1253
> created_at: 2026-05-04T10:50:09Z
> original_text: |
>   I want to create a service that will conenct to my X (twitter) account and collect all the bookmarks...
> ```

## Step 4 - Watch Brainstorm Work

```bash
hive brainstorm <slug>
```

Hive promotes the task to `2-brainstorm/`, runs the configured planning agent, and writes `brainstorm.md`. When the file ends with `<!-- WAITING -->`, answer the questions inline and run the same command again:

```bash
$EDITOR .hive-state/stages/2-brainstorm/<slug>/brainstorm.md
hive brainstorm <slug> --from 2-brainstorm
```

`--from <stage>` is the retry-safety assertion explained in [docs/architecture.md#markers-and-idempotency](architecture.md#markers-and-idempotency); it is optional when you run a stage by hand.

When brainstorm is complete, the state file ends with `<!-- COMPLETE -->`.

## Step 5 - Promote To Plan

```bash
hive plan <slug> --from 2-brainstorm
```

Hive moves the task to `3-plan/`, writes `plan.md`, and pauses for edits if the plan ends with `<!-- WAITING -->`. From there the same promote-or-run pattern carries the task through `develop`, `open-pr`, `review`, `finalize`, and `archive`.

## What Just Happened

`hive new` wrote an `idea.md` file. `hive brainstorm` and `hive plan` moved the task directory between stage folders and ran the stage agents. The current marker at the bottom of each stage file tells Hive whether the next action is human input, another run, or promotion to the next stage.

## Artefacts

- [docs/assets/xbookmark-walkthrough.txt](assets/xbookmark-walkthrough.txt) replays the completed dogfood task.
- [docs/assets/xbookmark-state-tree.txt](assets/xbookmark-state-tree.txt) shows a mid-run `.hive-state/` layout (the task is paused in `3-plan/` to pair with Step 5 above).
- [docs/recipes.md#xbookmark-end-to-end](recipes.md#xbookmark-end-to-end) expands the same example through PR and archive.

Next, read [docs/concepts.md](concepts.md), [docs/cli.md](cli.md), or [docs/recipes.md](recipes.md).
