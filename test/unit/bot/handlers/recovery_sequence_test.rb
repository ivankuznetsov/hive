require "test_helper"
require "hive/bot/handlers/recovery_sequence"
require "hive/commands/init"
require "hive/commands/workflow"
require "hive/workflows/project"

class HiveBotRecoverySequenceTest < Minitest::Test
  include HiveTestHelper

  Result = Struct.new(:action, :text, :command_argv, :commands, :project, :slug,
                      :alert_reset, :clear_keyboard, keyword_init: true)

  def test_build_returns_dispatch_commands_for_retryable_review_error
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260525-abcd", stage: "6-review",
      marker: "review_error", match_attr: "pass=2",
      result_class: Result, clear_keyboard: false
    )

    assert_equal :dispatch_commands, result.action
    assert_equal "hive", result.project
    assert_equal "stuck-260525-abcd", result.slug
    assert_equal 2, result.commands.length
    assert_equal "markers", result.commands[0][1]
    assert_equal "review", result.commands[1][1]
    refute result.clear_keyboard
  end

  def test_build_short_circuits_on_manual_only_marker
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stale-260525-abcd", stage: "4-execute",
      marker: "execute_stale", match_attr: nil,
      result_class: Result, clear_keyboard: true
    )

    assert_equal :reply, result.action
    assert_match(/no automatic recovery/, result.text)
  end

  def test_build_short_circuits_on_no_retry_verb_stage
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "done-260525-abcd", stage: "9-done",
      marker: "review_error", match_attr: nil,
      result_class: Result, clear_keyboard: false
    )

    assert_equal :reply, result.action
    assert_match(/No retry verb for stage 9-done/, result.text)
  end

  def test_retry_commands_skips_markers_clear_for_agent_working_marker
    commands = Hive::Bot::Handlers::RecoverySequence.retry_commands(
      project: "hive", slug: "any-260525-aaaa", stage: "6-review",
      marker: "AGENT_WORKING", match_attr: nil
    )

    assert_equal 1, commands.length, "agent_working marker must NOT add a markers clear step"
    assert_equal "review", commands[0][1]
  end

  def test_retry_commands_includes_match_attr_when_present
    commands = Hive::Bot::Handlers::RecoverySequence.retry_commands(
      project: "hive", slug: "stuck-260525-abcd", stage: "6-review",
      marker: "review_error", match_attr: "pass=2"
    )

    assert_includes commands[0], "--match-attr"
    assert_includes commands[0], "pass=2"
  end

  def test_retry_commands_omits_match_attr_when_invalid_shape
    commands = Hive::Bot::Handlers::RecoverySequence.retry_commands(
      project: "hive", slug: "stuck-260525-abcd", stage: "6-review",
      marker: "review_error", match_attr: "no_equals_sign"
    )

    refute_includes commands[0], "--match-attr"
  end

  # A non-coding workflow has no entry in the coding verb-by-stage table, so
  # before U6 a generic recovery row got "No retry verb". With the row's
  # workflow threaded in, it retries via the universal `hive run`, scoped by
  # --stage (run has no --from).
  def test_retry_verb_for_generic_workflow_is_run
    assert_equal "run",
                 Hive::Bot::Handlers::RecoverySequence.retry_verb_for_stage("2-gather", workflow: "research")
  end

  def test_retry_commands_for_generic_workflow_uses_hive_run_with_stage
    commands = Hive::Bot::Handlers::RecoverySequence.retry_commands(
      project: "hive", slug: "generic-260620-aaaa", stage: "2-gather",
      marker: "error", workflow: "research"
    )

    assert_equal 2, commands.length
    assert_equal %w[hive markers clear generic-260620-aaaa --name ERROR --project hive --json], commands[0]
    assert_equal %w[hive run generic-260620-aaaa --stage 2-gather --project hive --json], commands[1],
                 "generic retry must use `hive run --stage`, never an invalid `hive run --from`"
  end

  def test_build_dispatches_hive_run_for_generic_workflow_row
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "generic-260620-aaaa", stage: "2-gather",
      marker: "error", match_attr: nil, workflow: "research",
      result_class: Result, clear_keyboard: false
    )

    assert_equal :dispatch_commands, result.action
    assert_equal "run", result.commands.last[1]
    assert_includes result.commands.last, "--stage"
  end

  # The generic terminal (last) stage has no agent to re-run — offering
  # `hive run` there would raise StageError. With the workflow registered so the
  # descriptor can be introspected, the terminal stage yields nil (the generic
  # analog of the coding 9-done guard) while a non-terminal stage still runs.
  def test_retry_verb_for_generic_terminal_stage_is_nil
    with_registered_workflow(research_workflow) do
      assert_nil Hive::Bot::Handlers::RecoverySequence.retry_verb_for_stage("3-report", workflow: "research")
    end
  end

  def test_retry_verb_for_generic_non_terminal_stage_is_run
    with_registered_workflow(research_workflow) do
      assert_equal "run",
                   Hive::Bot::Handlers::RecoverySequence.retry_verb_for_stage("2-gather", workflow: "research")
    end
  end

  def test_build_short_circuits_for_generic_terminal_stage
    with_registered_workflow(research_workflow) do
      result = Hive::Bot::Handlers::RecoverySequence.build(
        project: "hive", slug: "done-260620-aaaa", stage: "3-report",
        marker: "error", match_attr: nil, workflow: "research",
        result_class: Result, clear_keyboard: false
      )

      assert_equal :reply, result.action
      assert_match(/No retry verb for stage 3-report/, result.text)
    end
  end

  # A non-:agent (inert/marker) MIDDLE stage has no agent runner —
  # Stages::Resolver.resolve raises StageError for kind != :agent — so offering
  # `hive run` there would queue a command that always fails. With the workflow
  # registered, the inert middle stage yields nil; the :agent middle still runs.
  def test_retry_verb_for_generic_inert_middle_stage_is_nil
    with_registered_workflow(agent_entry_workflow) do
      assert_nil Hive::Bot::Handlers::RecoverySequence.retry_verb_for_stage("2-hold", workflow: "agent_entry"),
                 "an inert middle stage has no agent runner; hive run there would always fail"
      assert_equal "run",
                   Hive::Bot::Handlers::RecoverySequence.retry_verb_for_stage("1-draft", workflow: "agent_entry"),
                   "the :agent entry stage still re-runs via hive run"
    end
  end

  # The bot/web process never pre-loads project overlays, and a project-authored
  # descriptor is registered ONLY in its project's overlay. The classifier must
  # load the row's project (resolved from its name) before introspecting the
  # descriptor — otherwise a custom terminal/inert stage falls through to
  # `hive run` and queues a retry that always fails (StageError). Unlike the
  # tests above (which register into the test runtime overlay), here the
  # descriptor is reachable ONLY via the project load.
  def test_generic_classifier_loads_the_rows_project_overlay
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        project = File.basename(project_root)
        capture_io { Hive::Commands::Init.new(project_root).call }
        capture_io { Hive::Commands::Workflow.new!("flow", project_root: project_root) }
        # Simulate a fresh bot process: nothing pre-loaded, descriptor NOT in
        # the test runtime overlay.
        Hive::Workflows::Project.reset!

        assert_nil Hive::Bot::Handlers::RecoverySequence.retry_verb_for_stage(
          "3-done", workflow: "flow", project: project
        ), "the custom terminal stage must classify as no-retry (the overlay was loaded)"
        assert_nil Hive::Bot::Handlers::RecoverySequence.retry_verb_for_stage(
          "1-inbox", workflow: "flow", project: project
        ), "the custom inert entry stage must classify as no-retry"
        assert_equal "run", Hive::Bot::Handlers::RecoverySequence.retry_verb_for_stage(
          "2-work", workflow: "flow", project: project
        ), "the custom :agent stage still re-runs via hive run"
      end
    end
  ensure
    Hive::Workflows::Project.reset!
  end

  def test_coding_workflow_retry_unchanged_when_workflow_omitted
    # Default (no workflow) keeps the coding verb table — the inline-button
    # callback path carries no workflow token and must not regress.
    assert_equal "review",
                 Hive::Bot::Handlers::RecoverySequence.retry_verb_for_stage("6-review")
  end

  def test_alert_reset_omits_optional_keys_when_blank
    assert_equal({ project: "hive", slug: "s", stage: "6-review" },
                 Hive::Bot::Handlers::RecoverySequence.alert_reset("hive", "s", "6-review"))
    assert_equal({ project: "hive", slug: "s", stage: "6-review", marker: "review_error" },
                 Hive::Bot::Handlers::RecoverySequence.alert_reset("hive", "s", "6-review", "review_error"))
    assert_equal({ project: "hive", slug: "s", stage: "6-review",
                   marker: "review_error", match_attr: "pass=2" },
                 Hive::Bot::Handlers::RecoverySequence.alert_reset(
                   "hive", "s", "6-review", "review_error", "pass=2"
                 ))
  end

  # `stages.ensure_clean_on_exit` plan: `:error reason=dirty_worktree`
  # and `:error reason=ensure_clean_on_exit_failed` must short-circuit
  # the Autofix dispatch with the operator-actionable reply, not the
  # generic "open it on a laptop" string. Asserting the callback path
  # specifically (no `attrs:` kwarg) — that's the one that needed the
  # `match_attr → attrs` resolution.
  def test_build_short_circuits_on_dirty_worktree_via_match_attr
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260528-aaaa", stage: "8-finalize",
      marker: "error", match_attr: "reason=dirty_worktree",
      result_class: Result, clear_keyboard: true
    )

    assert_equal :reply, result.action
    assert_match(/Hive can't auto-recover a dirty worktree/, result.text)
    assert_match(/commit or discard/, result.text)
  end

  def test_build_short_circuits_on_ensure_clean_on_exit_failed_via_match_attr
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260528-bbbb", stage: "8-finalize",
      marker: "error", match_attr: "reason=ensure_clean_on_exit_failed",
      result_class: Result, clear_keyboard: false
    )

    assert_equal :reply, result.action
    assert_match(/Hive can't auto-recover a dirty worktree/, result.text)
  end

  # Same routing on the slash-handler path that passes the full row.attrs
  # hash — the attrs-gated rule must fire there too.
  def test_build_short_circuits_on_ensure_clean_on_exit_failed_via_attrs
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260528-cccc", stage: "8-finalize",
      marker: "error", match_attr: nil,
      attrs: { "reason" => "ensure_clean_on_exit_failed", "residue_paths" => "wiki/modules/daemon.md" },
      result_class: Result, clear_keyboard: false
    )

    assert_equal :reply, result.action
    assert_match(/Hive can't auto-recover a dirty worktree/, result.text)
  end

  def test_build_short_circuits_on_fix_status_check_failed_via_attrs
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260530-aaaa", stage: "6-review",
      marker: "review_error", match_attr: nil,
      attrs: { "phase" => "fix", "reason" => "fix_status_check_failed", "pass" => "1" },
      result_class: Result, clear_keyboard: false
    )

    assert_equal :reply, result.action
    assert_match(/Git status cannot be read/, result.text)
  end

  # Real-world callback_data carries BOTH `marker_id=<hex>` (the
  # race-safe clear guard from `Hive::Markers.error_recovery_match_attr`)
  # AND `reason=<...>` (so manual_only? can route on reason without
  # re-reading the state file). Before F1, error_recovery_match_attr
  # returned `marker_id=<hex>` alone, attrs_from_match_attr
  # reconstructed `{ "marker_id" => "<hex>" }` with no `reason`, and
  # the manual-only check fell through to the dispatch path — sending
  # a retry against a dirty worktree.
  def test_build_short_circuits_on_marker_id_plus_reason_match_attr
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260528-eeee", stage: "8-finalize",
      marker: "error",
      match_attr: "marker_id=abc123,reason=ensure_clean_on_exit_failed",
      result_class: Result, clear_keyboard: false
    )

    assert_equal :reply, result.action
    assert_match(/Hive can't auto-recover a dirty worktree/, result.text)
  end

  # Other `:error` reasons keep the existing retry behaviour (clear +
  # retry verb) — the new manual-only routing must be narrowly scoped.
  def test_build_still_dispatches_for_other_error_reasons
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260528-dddd", stage: "8-finalize",
      marker: "error", match_attr: "reason=unpushed_commits",
      result_class: Result, clear_keyboard: false
    )

    assert_equal :dispatch_commands, result.action
    assert_equal 2, result.commands.length
    assert_equal "markers", result.commands[0][1]
  end
end
