# First run: Build and Content

Hive's two launch paths start from the same place: a clean git repository, a
completed Hive install, and the native local web UI. Build uses the built-in
`coding` workflow; Content uses the built-in `content` workflow.

These walkthroughs have a five-minute **acceptance target** for visible progress
and a first inspectable artifact. That target is not timing evidence. The files
under [`docs/fixtures/launch-paths/`](fixtures/launch-paths/) are deterministic,
explicitly synthetic fixtures; they do not claim a provider completed either
workflow or that a clean replay met the target.

## Prepare a clean project

```bash
cd ~/Dev/your-clean-project
hive init . --workflow coding   # use content for the Content path
hive setup --service
hive daemon status || hive daemon start --detach
hive web start --detach         # http://127.0.0.1:4567
```

Keep the daemon running (`hive daemon status`). The detached web command returns
control to this shell. In Hive web, **Add idea** creates the task. The
command-line equivalent is:

```bash
hive new . "your sample input"
```

## Use Hive's cross-surface state words

| Moment | Native label or control | What to do |
|---|---|---|
| Launch | **Add idea** | Submit one bounded sample input. |
| Queued | **Queued for the daemon** | Wait for the authoritative task snapshot to change. |
| Running | **Agent running** | Open the task; progress and logs update from durable state. |
| Approval waiting | **Needs your input** / **Approve** | Inspect the named artifact, answer or approve, then continue. |
| Provider limit | **Waiting on provider / scheduler** | Preserve the task and wait; do not clear a quota hold as if it succeeded. |
| Recoverable failure | **Needs recovery** / **Retry stage** | Inspect the diagnostic, then use the guarded retry. |
| Terminal failure | **Error** | Stop, diagnose, and repair the recorded cause before another run. |
| Success | **Archived** | The workflow is terminal and its files remain inspectable. |
| Artifact inspection | **Artifacts** | Expand the brief, plan, patch, review, or article in the task page. |
| Retry / resume | **Retry stage** | Hive clears the observed recoverable marker and queues the same stage. |
| Next action | Current action label plus **Approve** or **Run stage** | Follow the control shown for the current state. |

The labels and controls above come from Hive web, task actions, and the status
operational bands. `test/unit/launch_path_fixture_test.rb` pins every entry to
its real producer so the public walkthrough cannot drift quietly from the
product surface that owns it.

## Build: one safe health response

Initialize an empty Git repository with `--workflow coding`, then submit the
[Build sample input](fixtures/launch-paths/build/idea.md). The memorable outcome
is a minimal Rack service created from scratch with a small `/healthz` response
containing status, version, and revision. Inspect the
[brainstorm](fixtures/launch-paths/build/brainstorm.md),
[plan](fixtures/launch-paths/build/plan.md),
[illustrative patch](fixtures/launch-paths/build/patch.diff),
[review](fixtures/launch-paths/build/review.md), and
[outcome](fixtures/launch-paths/build/artifact.md) as separate evidence.

The patch includes the complete app and focused test, so it can be applied to
an empty repository and run with the documented commands. The final next action
is still a clean provider-backed replay. The fixture deliberately stops before
a pull request.

## Content: the handoff that survived

Initialize with `--workflow content`, then submit the
[Content sample input](fixtures/launch-paths/content/idea.md). Inspect the
[research](fixtures/launch-paths/content/research.md),
[outline](fixtures/launch-paths/content/outline.md),
[draft](fixtures/launch-paths/content/draft.md),
[critique](fixtures/launch-paths/content/critique.md), and
[article](fixtures/launch-paths/content/article.md). The terminal artifact is a
reviewable article, never automatic publication.

As of 2026-07-21, two private launch-validation tasks initially failed before
the research transition on an installed Hive 0.6.4 durable-attempt binding
error: `key not found: "approve"`. Exact supported approvals recovered the
tasks without rewriting task records. At the 2026-07-21T15:23:25Z observation,
one research stage had stopped at its provider budget while preserving its
artifact, and one outline stage was running after a single bounded retry. This
public guide deliberately omits private task identifiers, attempt identifiers,
costs, and artifact sizes. A reviewed terminal article and measured
first-artifact/full-completion times were not available, so this guide makes no
completion or speed claim.

## Recover without erasing evidence

- For **Needs recovery**, open the diagnostic and use **Retry stage**.
- For **Needs your input**, edit or approve only after inspecting the artifact.
- For **Waiting on provider / scheduler**, wait for capacity or dependency
  recovery; do not rewrite the task as successful.
- For **Error**, run `hive status --diagnose <slug>` and repair the stated cause.

After either path reaches a real reviewed outcome, record first-artifact time
and full-completion time separately. Do not derive either number from these
fixtures.
