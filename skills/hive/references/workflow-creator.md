# Natural-language workflow creator

This is the `hive-workflow-creator` contract inside the canonical `/hive`
skill. It creates one new owner-authored project workflow. It never edits,
repairs, overwrites, or partially merges an existing workflow.

## Gate before mutation

The minimum Hive version: {{HIVE_VERSION}}. First run `hive version` and parse
the bare semantic version. If it is older, stop before inspecting or writing
project workflow paths and say exactly: “Hive {{HIVE_VERSION}} or newer is
required; run `hive update`, then retry.” Do not invent a compatibility adapter.

After the version passes, run `hive workflow list --json` in the target project
and inspect `.hive-state/config.yml` when present. Record the project’s current
agent/model choices, built-ins, managed workflows, and owner-authored IDs.
Infer a safe lowercase-hyphen ID. A reserved or existing ID is a hard stop:
leave every file byte-identical and report Hive’s `suggested_id` (or the first
available numeric suffix obtained from the same ID inventory). Never silently
switch IDs and continue.

Determine whether the project is initialized before scaffolding. For a fresh
target, obtain the authoritative preview with:

```bash
hive init --new-workflow ID --minimal --preview --json
```

Summarize its project files, hive/state worktree, global registration,
wiki/context hooks, and explicitly disabled services and automation. Wait for
one explicit confirmation. If confirmation is declined, absent, or ambiguous,
stop and leave the target unchanged. After approval, run the same command
without `--preview`. Never add a force option, select a starter template, or
initialize an existing target through the minimal route.

For an initialized project, scaffold only after all gates pass:

```bash
hive workflow new ID --json
```

Use a built-in sample only when its semantics genuinely match the request;
otherwise keep the neutral blank scaffold. Modify only `descriptor_path` and
the newly returned instruction directory. Treat any collision returned by the
CLI as authoritative and stop with its deterministic alternative.

## Infer, populate, and validate

Translate the original request into the smallest complete graph:

- Preserve the requested stage order and use sequential automatic edges by default.
- Infer one durable artifact/state file per stage and reusable instruction text for agent stages.
- Omit stage `agent` and `model` when project inheritance is sufficient.
- Use `permissions: yolo` for ordinary local agent work unless the request or a high-consequence boundary requires less authority.
- Add a human stage only for a materially necessary decision or irreversible/high-consequence boundary. Never infer branching, specialist models, or external destinations.
- Never publish externally, deploy, message, tag, or release from an inferred stage. A separate destination and explicit authorization are mandatory.

Write only the newly scaffolded paths, then run:

```bash
hive workflow validate ID --json
```

Success requires `valid: true`, the intended ordered stages and kinds, exact
automatic edges, exact human outcomes, and every instruction path present.
On any diagnostic, stop and report it; do not claim success or create a task.

After successful validation, commit the populated graph to the Hive state
worktree. Retain `ID` and `descriptor_path` from the scaffold response, then
derive the state root and commit only the new workflow paths:

```bash
state_root="$(dirname "$(dirname "$descriptor_path")")"
git -C "$state_root" add -- "workflows/$ID.yml" "workflows/$ID"
git -C "$state_root" commit -m "feat(workflow): define $ID workflow" -- \
  "workflows/$ID.yml" "workflows/$ID"
```

The commit is part of workflow creation. If it fails, stop and report it; do
not claim success or create a task from an uncommitted graph.

## Task side-effect boundary

No task by default. A creation-only request ends after validation and the
populated-graph commit, then prints an exact shell-quoted next command:

```bash
hive new PROJECT --workflow ID "ORIGINAL REQUEST"
```

Only when the original request explicitly says to create or run a task, derive
one stable opaque key from project + workflow ID + normalized original request
and keep it unchanged across retries. Create at most once with:

```bash
hive new PROJECT --workflow ID --idempotency-key KEY --json "ORIGINAL REQUEST"
```

If the original request also explicitly said run, invoke the reported first
stage only when `created: true`; `created: false` means a retry and must not
dispatch that stage again. Then query `hive status --operational --json` and
report the slug, current stage, daemon disposition, and expected next
transition from live state.

## Required completion summary

Always report:

- created files (descriptor plus every instruction/reference path);
- neutral scaffold or the genuinely reused template;
- applied defaults, including ID, stage order, artifacts, inheritance,
  permissions, automatic transitions, and every checkpoint/outcome;
- validation result and normalized graph;
- task side effect (`none`, `created: true`, or `created: false`);
- the exact next command when no task was created; and
- any question or explicit choice that remains material.

Do not describe a workflow as created until Hive has loaded and validated it.
