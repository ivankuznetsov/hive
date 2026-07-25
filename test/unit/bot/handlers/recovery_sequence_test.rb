require "test_helper"
require "hive/bot/handlers/recovery_sequence"
require "hive/commands/init"
require "hive/commands/workflow"
require "hive/workflows/project"

class HiveBotRecoverySequenceTest < Minitest::Test
  include HiveTestHelper

  Result = Struct.new(:action, :text, :command_argv, :commands, :project, :slug,
                      :alert_reset, :clear_keyboard, :recovery, keyword_init: true)

  def test_build_returns_one_shared_recovery_request_for_retryable_review_error
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260525-abcd", stage: "6-review",
      marker: "review_error", match_attr: "pass=2",
      result_class: Result, clear_keyboard: false
    )

    assert_equal :dispatch_recovery, result.action
    assert_equal "hive", result.project
    assert_equal "stuck-260525-abcd", result.slug
    assert_nil result.commands
    assert_equal "review_error", result.recovery.fetch(:marker)
    assert_equal({ "pass" => "2" }, result.recovery.fetch(:attrs))
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

  # A non-coding workflow has no entry in the coding verb-by-stage table, so
  # before U6 a generic recovery row got "No retry verb". With the row's
  # workflow threaded in, it retries via the universal `hive run`, scoped by
  # --stage (run has no --from).
  def test_retry_verb_for_generic_workflow_is_run
    assert_equal "run",
                 Hive::Bot::Handlers::RecoverySequence.retry_verb_for_stage("2-gather", workflow: "research")
  end

  def test_build_routes_generic_workflow_row_to_shared_recovery
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "generic-260620-aaaa", stage: "2-gather",
      marker: "error", match_attr: nil, workflow: "research",
      result_class: Result, clear_keyboard: false
    )

    assert_equal :dispatch_recovery, result.action
    assert_equal "research", result.recovery.fetch(:workflow)
    assert_equal "2-gather", result.recovery.fetch(:stage)
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

  # Every ERROR/REVIEW_ERROR remains retryable from both callback and
  # slash-handler paths; stage guards re-evaluate the state after the clear.
  def test_build_retries_dirty_worktree_via_match_attr
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260528-aaaa", stage: "8-finalize",
      marker: "error", match_attr: "reason=dirty_worktree",
      result_class: Result, clear_keyboard: true
    )

    assert_equal :dispatch_recovery, result.action
    assert_nil result.commands
  end

  def test_build_retries_ensure_clean_on_exit_failed_via_match_attr
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260528-bbbb", stage: "8-finalize",
      marker: "error", match_attr: "reason=ensure_clean_on_exit_failed",
      result_class: Result, clear_keyboard: false
    )

    assert_equal :dispatch_recovery, result.action
    assert_nil result.commands
  end

  def test_build_retries_ensure_clean_on_exit_failed_via_attrs
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260528-cccc", stage: "8-finalize",
      marker: "error", match_attr: nil,
      attrs: { "reason" => "ensure_clean_on_exit_failed", "residue_paths" => "wiki/modules/daemon.md" },
      result_class: Result, clear_keyboard: false
    )

    assert_equal :dispatch_recovery, result.action
    assert_nil result.commands
  end

  def test_build_retries_fix_status_check_failed_via_attrs
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260530-aaaa", stage: "6-review",
      marker: "review_error", match_attr: nil,
      attrs: { "phase" => "fix", "reason" => "fix_status_check_failed", "pass" => "1" },
      result_class: Result, clear_keyboard: false
    )

    assert_equal :dispatch_recovery, result.action
    assert_nil result.commands
  end

  def test_build_retries_marker_id_plus_reason_match_attr
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260528-eeee", stage: "8-finalize",
      marker: "error",
      match_attr: "marker_id=abc123,reason=ensure_clean_on_exit_failed",
      result_class: Result, clear_keyboard: false
    )

    assert_equal :dispatch_recovery, result.action
    assert_nil result.commands
  end

  # Other `:error` reasons keep the existing retry behaviour (clear +
  # retry verb) — the new manual-only routing must be narrowly scoped.
  def test_build_still_dispatches_for_other_error_reasons
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260528-dddd", stage: "8-finalize",
      marker: "error", match_attr: "reason=unpushed_commits",
      result_class: Result, clear_keyboard: false
    )

    assert_equal :dispatch_recovery, result.action
    assert_nil result.commands
  end
end
