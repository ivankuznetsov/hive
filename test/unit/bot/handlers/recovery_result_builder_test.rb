require "test_helper"
require "hive/bot/handlers/recovery_result_builder"
require "hive/recovery/retry_policy"
require "hive/commands/init"
require "hive/commands/workflow"
require "hive/workflows/project"

class HiveBotRecoveryResultBuilderTest < Minitest::Test
  include HiveTestHelper

  Result = Struct.new(:action, :text, :command_argv, :commands, :project, :slug,
                      :alert_reset, :clear_keyboard, :recovery, keyword_init: true)

  def test_build_returns_one_shared_recovery_request_for_retryable_review_error
    result = Hive::Bot::Handlers::RecoveryResultBuilder.build(
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
    result = Hive::Bot::Handlers::RecoveryResultBuilder.build(
      project: "hive", slug: "stale-260525-abcd", stage: "4-execute",
      marker: "execute_stale", match_attr: nil,
      result_class: Result, clear_keyboard: true
    )

    assert_equal :reply, result.action
    assert_match(/no automatic recovery/, result.text)
  end

  def test_build_requires_max_pass_review_escalation_edits_before_retry
    Dir.mktmpdir("hive-review-escalation") do |folder|
      FileUtils.mkdir_p(File.join(folder, "reviews"))
      File.write(File.join(folder, "reviews", "escalations-02.md"), "# Questions\n")
      row = Struct.new(:folder).new(folder)

      result = Hive::Bot::Handlers::RecoveryResultBuilder.build(
        project: "hive", slug: "stale-260525-abcd", stage: "6-review",
        marker: "review_stale", match_attr: "marker_id=m2",
        attrs: { "pass" => "2", "marker_id" => "m2" }, row: row,
        result_class: Result, clear_keyboard: true
      )

      assert_equal :reply, result.action
      assert_match(/Edit the current review escalation/, result.text)
    end
  end

  def test_build_short_circuits_on_no_retry_verb_stage
    result = Hive::Bot::Handlers::RecoveryResultBuilder.build(
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
                 Hive::Recovery::RetryPolicy.verb_for("2-gather", workflow: "research")
  end

  def test_build_routes_generic_workflow_row_to_shared_recovery
    result = Hive::Bot::Handlers::RecoveryResultBuilder.build(
      project: "hive", slug: "generic-260620-aaaa", stage: "2-gather",
      marker: "error", match_attr: nil, workflow: "research",
      result_class: Result, clear_keyboard: false
    )

    assert_equal :dispatch_recovery, result.action
    assert_equal "research", result.recovery.fetch(:workflow)
    assert_equal "2-gather", result.recovery.fetch(:stage)
  end

  # An inert generic terminal stage has no runner. Active terminal stages are
  # different: descriptors explicitly allow agent/council producers in the
  # last slot, and those stages remain runnable until their deliverable lands.
  def test_retry_verb_for_generic_terminal_stage_is_nil
    with_registered_workflow(research_workflow) do
      assert_nil Hive::Recovery::RetryPolicy.verb_for("3-report", workflow: "research")
    end
  end

  def test_retry_verb_for_active_generic_terminal_stages_is_run
    %i[agent council].each do |kind|
      workflow = active_terminal_workflow(kind)
      with_registered_workflow(workflow) do
        assert_equal "run",
                     Hive::Recovery::RetryPolicy.verb_for(
                       "2-produce", workflow: workflow.id
                     ),
                     "terminal #{kind} stages own a real runner"
      end
    end
  end

  def test_retry_verb_for_generic_non_terminal_stage_is_run
    with_registered_workflow(research_workflow) do
      assert_equal "run",
                   Hive::Recovery::RetryPolicy.verb_for("2-gather", workflow: "research")
    end
  end

  def test_build_short_circuits_for_generic_terminal_stage
    with_registered_workflow(research_workflow) do
      result = Hive::Bot::Handlers::RecoveryResultBuilder.build(
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
      assert_nil Hive::Recovery::RetryPolicy.verb_for("2-hold", workflow: "agent_entry"),
                 "an inert middle stage has no agent runner; hive run there would always fail"
      assert_equal "run",
                   Hive::Recovery::RetryPolicy.verb_for("1-draft", workflow: "agent_entry"),
                   "the :agent entry stage still re-runs via hive run"
    end
  end

  # The bot process never pre-loads project overlays, and a project-authored
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

        assert_nil Hive::Recovery::RetryPolicy.verb_for(
          "3-done", workflow: "flow", project: project
        ), "the custom terminal stage must classify as no-retry (the overlay was loaded)"
        assert_nil Hive::Recovery::RetryPolicy.verb_for(
          "1-inbox", workflow: "flow", project: project
        ), "the custom inert entry stage must classify as no-retry"
        assert_equal "run", Hive::Recovery::RetryPolicy.verb_for(
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
                 Hive::Recovery::RetryPolicy.verb_for("6-review")
  end

  def test_alert_reset_omits_optional_keys_when_blank
    assert_equal({ project: "hive", slug: "s", stage: "6-review" },
                 Hive::Bot::Handlers::RecoveryResultBuilder.alert_reset("hive", "s", "6-review"))
    assert_equal({ project: "hive", slug: "s", stage: "6-review", marker: "review_error" },
                 Hive::Bot::Handlers::RecoveryResultBuilder.alert_reset("hive", "s", "6-review", "review_error"))
    assert_equal({ project: "hive", slug: "s", stage: "6-review",
                   marker: "review_error", match_attr: "pass=2" },
                 Hive::Bot::Handlers::RecoveryResultBuilder.alert_reset(
                   "hive", "s", "6-review", "review_error", "pass=2"
                 ))
  end

  def active_terminal_workflow(kind)
    terminal = if kind == :council
      Hive::Workflow::Stage.new(
        name: "produce", index: 2, state_file: "status.md", kind: :council,
        reviewers: [
          Hive::Workflow::Reviewer.new(name: "one", prompt: "Review.")
        ],
        council: Hive::Workflow::Council.new(quorum: 1)
      )
    else
      Hive::Workflow::Stage.new(
        name: "produce", index: 2, state_file: "status.md", kind: :agent
      )
    end
    Hive::Workflow.new(
      id: :"recovery_terminal_#{kind}",
      stages: [
        Hive::Workflow::Stage.new(
          name: "inbox", index: 1, state_file: "idea.md", kind: :inert
        ),
        terminal
      ]
    )
  end

  # Every ERROR/REVIEW_ERROR remains retryable from both callback and
  # slash-handler paths; the coordinator re-evaluates state under its lock.
  def test_build_retries_dirty_worktree_via_match_attr
    result = Hive::Bot::Handlers::RecoveryResultBuilder.build(
      project: "hive", slug: "stuck-260528-aaaa", stage: "8-finalize",
      marker: "error", match_attr: "reason=dirty_worktree",
      result_class: Result, clear_keyboard: true
    )

    assert_equal :dispatch_recovery, result.action
    assert_nil result.commands
  end

  def test_build_retries_ensure_clean_on_exit_failed_via_match_attr
    result = Hive::Bot::Handlers::RecoveryResultBuilder.build(
      project: "hive", slug: "stuck-260528-bbbb", stage: "8-finalize",
      marker: "error", match_attr: "reason=ensure_clean_on_exit_failed",
      result_class: Result, clear_keyboard: false
    )

    assert_equal :dispatch_recovery, result.action
    assert_nil result.commands
  end

  def test_build_retries_ensure_clean_on_exit_failed_via_attrs
    result = Hive::Bot::Handlers::RecoveryResultBuilder.build(
      project: "hive", slug: "stuck-260528-cccc", stage: "8-finalize",
      marker: "error", match_attr: nil,
      attrs: { "reason" => "ensure_clean_on_exit_failed", "residue_paths" => "wiki/modules/daemon.md" },
      result_class: Result, clear_keyboard: false
    )

    assert_equal :dispatch_recovery, result.action
    assert_nil result.commands
  end

  def test_build_retries_fix_status_check_failed_via_attrs
    result = Hive::Bot::Handlers::RecoveryResultBuilder.build(
      project: "hive", slug: "stuck-260530-aaaa", stage: "6-review",
      marker: "review_error", match_attr: nil,
      attrs: { "phase" => "fix", "reason" => "fix_status_check_failed", "pass" => "1" },
      result_class: Result, clear_keyboard: false
    )

    assert_equal :dispatch_recovery, result.action
    assert_nil result.commands
  end

  def test_build_retries_marker_id_plus_reason_match_attr
    result = Hive::Bot::Handlers::RecoveryResultBuilder.build(
      project: "hive", slug: "stuck-260528-eeee", stage: "8-finalize",
      marker: "error",
      match_attr: "marker_id=abc123,reason=ensure_clean_on_exit_failed",
      result_class: Result, clear_keyboard: false
    )

    assert_equal :dispatch_recovery, result.action
    assert_nil result.commands
  end

  # Other `:error` reasons use the same coordinator admission path; the
  # manual-only routing stays narrowly scoped.
  def test_build_still_dispatches_for_other_error_reasons
    result = Hive::Bot::Handlers::RecoveryResultBuilder.build(
      project: "hive", slug: "stuck-260528-dddd", stage: "8-finalize",
      marker: "error", match_attr: "reason=unpushed_commits",
      result_class: Result, clear_keyboard: false
    )

    assert_equal :dispatch_recovery, result.action
    assert_nil result.commands
  end
end
