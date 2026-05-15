<p align="center">
  <img src="docs/assets/logo.svg" alt="Hive" width="96" height="96">
</p>

# Hive

Hive is a multi-agent orchestrator that ships software ideas from rough note to pull request through a folder-as-agent pipeline.

Each task is a directory. The directory's stage folder is the task state, so moving a folder forward is the approval gesture and every artefact stays inspectable with normal filesystem tools. Compound engineering is the practice of making each step's output strong enough for the next step to run autonomously: brainstorm fixes the requirements, plan fixes the approach, execute writes code, review hardens it, and PR stages ship it.

```text
1-inbox  ->  2-brainstorm  ->  3-plan  ->  4-execute  ->  5-open-pr  ->  6-review  ->  7-finalize  ->  8-done
capture       refine           design      build          draft PR       harden        publish         archive
```

Read the model in depth in [docs/concepts.md](docs/concepts.md).

## Install

```bash
git clone https://github.com/ivankuznetsov/hive ~/Dev/hive && cd ~/Dev/hive && bundle install && ln -s ~/Dev/hive/bin/hive ~/.local/bin/hive
```

Requires Ruby 3.4, git >= 2.40, `claude` >= 2.1.118, `codex` >= 0.125.0 for the default execute agent, and authenticated `gh`. See [docs/getting-started.md](docs/getting-started.md) for the first run.

## Install As A Prompt

Paste this into Claude Code or Codex when you want the agent to install Hive for you:

```markdown
Install Hive from the canonical GitHub source into ~/Dev/hive and put the hive binary on PATH.

Before changing anything:
- If ~/Dev/hive already exists, stop and ask whether to reuse it, pull it, or choose another directory.
- If `claude` is missing or `claude --version` is older than 2.1.118, stop and report the missing prerequisite.
- If `codex` is missing or `codex --version` is older than 0.125.0, stop and report that the default execute agent will not work until Codex is installed.
- If `gh auth status` fails, stop and ask the user to authenticate GitHub CLI.
- If ~/.local/bin is not on PATH, stop and ask which PATH directory should receive the symlink.

Run these commands in order:

git clone https://github.com/ivankuznetsov/hive ~/Dev/hive
cd ~/Dev/hive
bundle install
mkdir -p ~/.local/bin
ln -sf ~/Dev/hive/bin/hive ~/.local/bin/hive
hive --version

Report the installed version and the path returned by `command -v hive`.
```

## Quickstart

```bash
cd ~/Dev/your-project
hive init .                                      # attach .hive-state to this repo
hive new your-project "add tag autocomplete"     # create 1-inbox/<slug>/idea.md
hive status                                      # see the next useful action
hive brainstorm <slug>                           # write brainstorm.md, then answer questions inline
hive plan <slug>                                 # write or refine plan.md
hive develop <slug>                              # create the feature worktree and implementation commit
hive open-pr <slug>                              # push the branch and open a draft PR
hive review <slug>                               # run CI, reviewers, triage, fixes, and browser test
hive finalize <slug>                             # refresh the PR body and mark it ready
hive archive <slug>                              # after merge, move the task to 8-done
```

Walk through the same shape on a real completed xbookmark task in [docs/getting-started.md](docs/getting-started.md).

## Documentation

- [docs/getting-started.md](docs/getting-started.md) - five-minute first run against a real project.
- [docs/concepts.md](docs/concepts.md) - folder-as-agent, the eight stages, and compound engineering.
- [docs/architecture.md](docs/architecture.md) - how stages, agents, files, config, and worktrees compose.
- [docs/cli.md](docs/cli.md) - current command surface from `bin/hive`.
- [docs/recipes.md](docs/recipes.md) - concrete workflows, including the xbookmark dogfood replay.
- [docs/faq.md](docs/faq.md) - troubleshooting and design questions.
- [wiki/index.md](wiki/index.md) - deeper engineering reference maintained by the LLM wiki.
