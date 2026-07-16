# Hive e2e scenarios

The YAML scenarios in this directory drive the real `bin/hive` executable in
an isolated copy of `test/e2e/sample-project/`. Use `_template.yml` as the DSL
reference and run the harness with:

```bash
bundle exec rake e2e:lib_test
bin/hive-e2e run
bin/hive-e2e run --filter incident-regression --json
```

## Incident metadata and activation

Every scenario tagged `incident-regression` must declare a non-empty
`description`, a stable lowercase-kebab `incident_id`, and a `sibling_task_id`
such as `"#9767"`. A sibling-gated fixture also declares `pending: true`.

Pending scenarios are parsed and included in `report.json#scenario_metadata`,
but their steps are not executed, they add no row to `scenarios`, and they do
not change the existing passed/failed/setup-failed summary counts. This keeps
unavailable contracts visible without calling the fixture passed. To activate
one, consume the sibling implementation's exact persisted state and reason
code, replace the activation guard with terminal-state assertions, and only
then remove `pending: true`. Enabled incident scenarios must finish below five
seconds; their combined duration must remain below thirty seconds.

## Incident index

| Incident ID | Scenario | Sibling | Reconciler under test | State |
|---|---|---|---|---|
| `accepted-attempt-caller-loss` | [incident_attempt_adoption_after_caller_loss.yml](incident_attempt_adoption_after_caller_loss.yml) | `#9767` | durable attempt ownership and daemon adoption | Pending |
| `generation-scoped-no-worktree-marker` | [incident_generation_scoped_no_worktree_marker.yml](incident_generation_scoped_no_worktree_marker.yml) | `#9768` | generation-scoped marker reconciliation | Pending |
| `finalize-pr-lifecycle-gate` | [incident_finalize_pr_lifecycle_gate.yml](incident_finalize_pr_lifecycle_gate.yml) | `#9769` | finalize and PR merge watcher | Pending |
| `plan-only-dependency-gate` | [incident_plan_only_dependency_gate.yml](incident_plan_only_dependency_gate.yml) | `#9771` | dependency resolver and daemon dispatch | Pending |
| `repository-routing` | [incident_repository_routing.yml](incident_repository_routing.yml) | `#9771` | project/repository dispatcher or babysitter | Pending |
| `provider-limit-retry` | [incident_provider_limit_retry.yml](incident_provider_limit_retry.yml) | `#9770` | provider-limit healer and retry owner | Pending |

## Hermetic GitHub scripting

Every blocking, background, and tmux-launched Hive subprocess receives the
checked-in `test/e2e/fixtures/gh` shim as the first `gh` on `PATH`. The shim is
default-deny: no script, an exhausted script, unexpected argv, cwd mismatch, or
repository mismatch exits non-zero immediately. There is no host-`gh` fallback
and therefore no real GitHub read or mutation from this harness.

Install an ordered interaction sequence with `script_gh`:

```yaml
- kind: script_gh
  interactions:
    - args: [pr, view, "42", --json, state,isDraft]
      cwd: "{sandbox}"
      repository: github.example/acme/widgets
      response: {state: OPEN, isDraft: true}
      exit_status: 0
```

Interactions are consumed atomically so repeated identical reads can model a
staged lifecycle. The run home records `gh-stub/script.json`, `state.json`, and
`audit.jsonl`; failure capture copies that evidence and the generated repro
script. The executor also fails if a scenario finishes with expected
interactions unconsumed.

## Process and fake-agent isolation

`spawn_background` owns an attached process group and `stop_process` ends and
reaps it. Scenario teardown independently stops every registered background
group on success, assertion failure, or timeout. Do not detach a daemon or add
a fixed sleep to keep a fixture alive.

All Claude and Codex launches resolve to `test/fixtures/fake-claude`. For
cross-process ordering, set `HIVE_FAKE_CLAUDE_READY_FILE` and
`HIVE_FAKE_CLAUDE_RELEASE_FILE`: the fixture atomically writes its PID to the
ready file and waits until the harness creates the release file. Assertions
poll those observable conditions; elapsed-time sleeps are not synchronization.

CI runs the harness in a separate job, retains its run directory, and enforces
the incident budget from the generated report:

```bash
bundle exec ruby test/e2e/check_incident_budget.rb test/e2e/runs
```
