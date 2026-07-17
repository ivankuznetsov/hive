require "test_helper"
require "hive/commands/run"

class CommandsRunTest < Minitest::Test
  include HiveTestHelper
  TaskDouble = Struct.new(
    :slug, :stage_name, :stage_index, :folder, :state_file,
    :hive_state_path, :project_root, :project_name, :worktree_path,
    :workflow,
    keyword_init: true
  )
  MarkerDouble = Struct.new(:name, :attrs, keyword_init: true)
  RebaseResultDouble = Struct.new(
    :reason, :attempted, :succeeded, :commits_behind,
    :agent_resolutions, :post_rebase_warnings,
    keyword_init: true
  )

  def command(**kwargs)
    Hive::Commands::Run.new("some-slug", **kwargs)
  end

  def task(folder: "/tmp/hive-task", stage_name: "brainstorm", stage_index: 2,
           state_file: nil, hive_state_path: nil, workflow: Hive::Workflows::Registry.default)
    TaskDouble.new(
      slug: "some-slug",
      stage_name: stage_name,
      stage_index: stage_index,
      folder: folder,
      state_file: state_file || File.join(folder, "brainstorm.md"),
      hive_state_path: hive_state_path || File.join(folder, "..", "..", ".."),
      project_root: "/tmp/project",
      project_name: "project",
      worktree_path: "/tmp/worktree",
      workflow: workflow
    )
  end

  def marker(name, attrs = {})
    MarkerDouble.new(name: name, attrs: attrs)
  end

  def rebase_result(**overrides)
    RebaseResultDouble.new({
      reason: :ok,
      attempted: true,
      succeeded: true,
      commits_behind: 0,
      agent_resolutions: 0,
      post_rebase_warnings: []
    }.merge(overrides))
  end

  def test_log_rebase_outcome_reports_success_failure_and_post_warnings
    run = command
    t = task

    _out, err = capture_io do
      run.send(:log_rebase_outcome, t, rebase_result(commits_behind: 2, agent_resolutions: 1))
      run.send(:log_rebase_outcome, t, rebase_result(commits_behind: 3, agent_resolutions: 0))
      run.send(:log_rebase_outcome, t, rebase_result(post_rebase_warnings: [ "worktree.yml stale" ]))
      run.send(:log_rebase_outcome, t, rebase_result(reason: :conflict, succeeded: false))
    end

    assert_includes err, "2 commits"
    assert_includes err, "1 conflict resolved by agent"
    assert_includes err, "3 commits"
    assert_includes err, "post-rebase warning: worktree.yml stale"
    assert_includes err, "rebase attempt failed (conflict)"
  end

  def test_pick_runner_rejects_unknown_stage_name
    err = assert_raises(Hive::StageError) do
      command.send(:pick_runner, task(stage_name: "mystery"))
    end

    assert_match(/no runner for stage mystery/, err.message)
  end

  def test_pick_runner_passes_task_workflow_to_resolver
    run = command
    descriptor = research_workflow
    t = task(stage_name: "gather")
    t.workflow = descriptor
    calls = []
    replacement = lambda do |resolved_task, descriptor:|
      calls << [ resolved_task, descriptor ]
      :runner
    end

    with_replaced_singleton_method(Hive::Stages::Resolver, :resolve, replacement) do
      assert_equal :runner, run.send(:pick_runner, t)
    end

    assert_equal [ [ t, descriptor ] ], calls
  end

  def test_pick_runner_uses_on_disk_task_workflow_selector
    with_tmp_dir do |dir|
      with_registered_workflow(research_workflow) do
        folder = File.join(dir, ".hive-state", "stages", "2-gather", "x-260424-7a3b")
        FileUtils.mkdir_p(folder)
        File.write(File.join(folder, "meta.yml"), "workflow: research\n")

        t = Hive::Task.new(folder)
        runner = command.send(:pick_runner, t)

        assert_equal :research, t.workflow.id
        assert_equal %w[intake gather report], t.stage_names
        assert_equal File.join(folder, "notes.md"), t.state_file
        assert_equal Hive::Stages::Agent.method(:run!), runner
      end
    end
  end

  def test_quiet_report_still_raises_for_error_markers
    with_tmp_dir do |dir|
      t = task(folder: dir)
      File.write(t.state_file, "# state\n")
      Hive::Markers.set(t.state_file, :review_error, phase: "fix")

      err = assert_raises(Hive::TaskInErrorState) do
        command(quiet: true).send(:report, t, {})
      end

      assert_match(/stage recorded :review_error/, err.message)
    end
  end

  def test_report_checks_execute_transition_before_emitting_completion
    with_tmp_dir do |dir|
      t = task(folder: dir, stage_name: "execute", stage_index: 4)
      File.write(t.state_file, "# state\n<!-- EXECUTE_COMPLETE -->\n")
      checked = []
      guard = lambda do |guarded_task, config:|
        checked << [ guarded_task, config ]
        raise Hive::WrongStage, "condition gate blocked"
      end
      cfg = { conditions: { mode: "conditions" } }

      error = with_replaced_singleton_method(Hive::Config, :load, ->(_root) { cfg }) do
        with_replaced_singleton_method(Hive::Conditions::TransitionGuard, :validate!, guard) do
          assert_raises(Hive::WrongStage) do
            capture_io { command.send(:report, t, commit: nil, status: :execute_complete) }
          end
        end
      end

      assert_equal "condition gate blocked", error.message
      assert_equal [ [ t, cfg ] ], checked
    end
  end

  def test_report_json_uses_disabled_rebase_fallback_and_cleanup_instructions
    run = command(json: true)
    t = task

    out, _err = capture_io do
      run.send(
        :report_json,
        t,
        { commit: "done", cleanup_instructions: "remove worktree" },
        marker(:manual_steering)
      )
    end

    payload = JSON.parse(out)
    assert_equal "hive-run", payload.fetch("schema")
    assert_equal "remove worktree", payload.fetch("cleanup_instructions")
    assert_equal "disabled", payload.fetch("rebase").fetch("reason")
    assert_equal({ "kind" => Hive::Schemas::NextActionKind::NO_OP, "reason" => "manual_steering" },
                 payload.fetch("next_action"))
  end

  def test_json_next_action_covers_stale_review_and_unknown_markers
    run = command
    t = task(folder: "/tmp/task-folder")

    execute_stale = run.send(:json_next_action, t, marker(:execute_stale))
    guardrail = run.send(:json_next_action, t, marker(:review_waiting, "reason" => "fix_guardrail", "pass" => "3"))
    partial = run.send(:json_next_action, t,
                       marker(:review_error, "reason" => "reviewer_partial_failure", "phase" => "reviewers", "pass" => "4"))
    scope_failure = run.send(
      :json_next_action,
      t,
      marker(:review_error, "reason" => "fix_auto_commit_scope_failed", "files" => "reviews/auto-commit-scope-01.md")
    )
    signing_failure = run.send(
      :json_next_action,
      t,
      marker(:review_error, "reason" => "fix_auto_commit_signing_failed", "phase" => "fix")
    )
    unknown = run.send(:json_next_action, t, marker(:surprise_marker))

    assert_equal Hive::Schemas::NextActionKind::RECOVER_STALE, execute_stale.fetch("kind")
    assert_equal "/tmp/task-folder/reviews/fix-guardrail-03.md", guardrail.fetch("target")
    assert_match(/checkbox count/, guardrail.fetch("instructions"))
    assert_equal Hive::Schemas::NextActionKind::EDIT, partial.fetch("kind")
    assert_equal "/tmp/task-folder/reviews/errors-04.md", partial.fetch("target")
    assert_equal "reviewer_partial_failure", partial.fetch("reason")
    assert_equal "reviewers", partial.fetch("phase")
    assert_match(/partial coverage/, partial.fetch("instructions"))
    assert_equal Hive::Schemas::NextActionKind::EDIT, scope_failure.fetch("kind")
    assert_equal "/tmp/task-folder/reviews/auto-commit-scope-01.md", scope_failure.fetch("target")
    assert_match(/scope artifact/, scope_failure.fetch("instructions"))
    assert_equal Hive::Schemas::NextActionKind::EDIT, signing_failure.fetch("kind")
    assert_equal "/tmp/worktree", signing_failure.fetch("target")
    assert_match(/signing config/, signing_failure.fetch("instructions"))
    assert_match(/commit or revert/, signing_failure.fetch("instructions"))
    assert_match(/sign_policy/, signing_failure.fetch("instructions"))
    refute signing_failure.key?("rerun_with")
    assert_equal({ "kind" => Hive::Schemas::NextActionKind::NO_OP }, unknown)
  end

  def test_next_stage_dir_uses_task_workflow_sequence
    run = command
    t = task(stage_name: "gather", stage_index: 2, workflow: research_workflow)

    assert_equal File.join(t.hive_state_path, "stages", "3-report"),
                 run.send(:next_stage_dir, t)
  end

  def test_json_next_action_generic_complete_approves_to_descriptor_stage
    run = command

    with_tmp_global_config do
      with_tmp_dir do |dir|
        folder = File.join(dir, ".hive-state", "stages", "2-gather", "some-slug")
        FileUtils.mkdir_p(folder)
        state_file = File.join(folder, "notes.md")
        File.write(state_file, "# notes\n")
        Hive::Markers.set(state_file, :complete)
        t = task(
          folder: folder,
          stage_name: "gather",
          stage_index: 2,
          state_file: state_file,
          hive_state_path: File.join(dir, ".hive-state"),
          workflow: research_workflow
        )

        action = run.send(:json_next_action, t, marker(:complete))

        assert_equal Hive::Schemas::NextActionKind::APPROVE, action.fetch("kind")
        assert_equal "2-gather", action.fetch("from_stage")
        assert_match(%r{/\.hive-state/stages/3-report/\z}, action.fetch("to"))
        assert_equal "3-report", action.fetch("to_stage")
        assert_equal "hive approve some-slug --from 2-gather", action.fetch("command")
      end
    end
  end

  def test_json_next_action_collision_workflow_avoids_coding_stage
    run = command

    with_tmp_global_config do
      with_tmp_dir do |dir|
        folder = File.join(dir, ".hive-state", "stages", "2-brainstorm", "some-slug")
        FileUtils.mkdir_p(folder)
        state_file = File.join(folder, "brainstorm.md")
        File.write(state_file, "# brainstorm\n")
        Hive::Markers.set(state_file, :complete)
        t = task(
          folder: folder,
          stage_name: "brainstorm",
          stage_index: 2,
          state_file: state_file,
          hive_state_path: File.join(dir, ".hive-state"),
          workflow: collision_workflow
        )

        action = run.send(:json_next_action, t, marker(:complete))

        assert_equal Hive::Schemas::NextActionKind::APPROVE, action.fetch("kind")
        assert_match(%r{/\.hive-state/stages/3-report/\z}, action.fetch("to"))
        assert_equal "3-report", action.fetch("to_stage")
        refute_match(%r{/3-plan/\z}, action.fetch("to"))
      end
    end
  end

  def test_json_next_action_generic_terminal_complete_is_no_op
    run = command
    t = task(stage_name: "report", stage_index: 3, workflow: research_workflow)

    assert_equal({ "kind" => Hive::Schemas::NextActionKind::NO_OP, "reason" => "final_stage" },
                 run.send(:json_next_action, t, marker(:complete)))
  end

  # CleanExit's `:error reason=ensure_clean_on_exit_failed` used to
  # fall through the bare NO_OP branch, stranding agents. Now it
  # surfaces an EDIT envelope keyed on the worktree root, with the
  # parsed `residue_paths` array and the copy-paste recovery
  # command. Other `:error` reasons keep the NO_OP shape so the new
  # branch is narrowly scoped.
  def test_json_next_action_surfaces_residue_paths_for_ensure_clean_on_exit_failed
    run = command
    t = task(folder: "/tmp/hive-task", stage_name: "finalize", stage_index: 8)

    clean_exit_failure = run.send(
      :json_next_action,
      t,
      marker(:error,
             "reason" => "ensure_clean_on_exit_failed",
             "residue_paths" => "wiki/notes.md, lib/foo.rb",
             "marker_id" => "abc123")
    )
    other_error = run.send(
      :json_next_action,
      t,
      marker(:error, "reason" => "git_status_failed", "marker_id" => "abc123")
    )

    assert_equal Hive::Schemas::NextActionKind::EDIT, clean_exit_failure.fetch("kind")
    assert_equal "/tmp/worktree", clean_exit_failure.fetch("target")
    assert_equal "ensure_clean_on_exit_failed", clean_exit_failure.fetch("reason")
    assert_equal [ "wiki/notes.md", "lib/foo.rb" ], clean_exit_failure.fetch("residue_paths")
    assert_equal [ "error" ], clean_exit_failure.fetch("markers_to_clear")
    assert_match(/commit or discard/, clean_exit_failure.fetch("instructions"))
    assert_match(/reason=ensure_clean_on_exit_failed/, clean_exit_failure.fetch("instructions"))
    assert clean_exit_failure.key?("rerun_with"),
           "ensure_clean_on_exit_failed must include rerun_with so agents have a copy-paste verb"

    # Other :error reasons keep the generic NO_OP shape.
    assert_equal Hive::Schemas::NextActionKind::NO_OP, other_error.fetch("kind")
    assert_equal({ "reason" => "git_status_failed", "marker_id" => "abc123" }, other_error.fetch("error"))
  end

  def test_report_text_covers_manual_and_stale_guidance
    run = command
    t = task

    out, _err = capture_io do
      run.send(:report_text, t, {}, marker(:execute_stale))
      run.send(:report_text, t, {}, marker(:manual_steering))
    end

    assert_includes out, "remove EXECUTE_STALE marker"
    assert_includes out, "manual steering active"
  end

  def test_report_text_review_error_prints_phase_and_reason_before_raising
    run = command
    t = task

    _out, err = capture_io do
      @error = assert_raises(Hive::TaskInErrorState) do
        run.send(:report_text, t, {}, marker(:review_error, "phase" => "fix", "reason" => "failed"))
      end
    end

    assert_match(/stage recorded :review_error/, @error.message)
    assert_includes err, "phase: fix"
    assert_includes err, "reason: failed"
  end

  def test_emit_error_envelope_swallows_json_generation_errors
    run = command(json: true)
    original = JSON.method(:generate)
    JSON.define_singleton_method(:generate) do |*_args|
      raise JSON::GeneratorError, "bad json"
    end

    capture_io do
      run.send(:emit_error_envelope, Hive::InternalError.new("bad"))
    end

    assert run.instance_variable_get(:@stdout_written)
  ensure
    JSON.define_singleton_method(:generate, original) if original
  end

  def test_condition_gate_error_envelope_preserves_gate_and_recovery_action
    error = Hive::ConditionGateBlocked.new(
      "blocked",
      current_stage: "4-execute", target_stage: "5-open-pr",
      condition_gate: {
        "status" => "blocked", "transition" => "execute_to_open_pr",
        "diagnostics" => [ { "condition" => "AgentHealthy", "state" => "unsatisfied" } ],
        "waivers" => []
      },
      next_action: {
        "kind" => Hive::Schemas::NextActionKind::RUN,
        "reason" => "attempt_lost"
      }
    )

    out, = capture_io { command(json: true).send(:emit_error_envelope, error) }
    payload = JSON.parse(out)
    assert_equal "blocked", payload.dig("condition_gate", "status")
    assert_equal "AgentHealthy",
                 payload.dig("condition_gate", "diagnostics", 0, "condition")
    assert_equal Hive::Schemas::NextActionKind::RUN, payload.dig("next_action", "kind")
    assert_equal "4-execute", payload.fetch("current_stage")
    assert_equal "5-open-pr", payload.fetch("target_stage")
  end

  def test_durable_call_dispatches_worker_without_running_body_in_caller
    result = Hive::Attempts::ClientResult.new(
      status: :terminal, exit_status: 0, outcome: "succeeded",
      receipt: {}, attempt_id: "attempt-1"
    )
    entrypoint = Object.new
    calls = []
    entrypoint.define_singleton_method(:dispatch) { |**kwargs| calls << kwargs; result }
    run = command(durable: true, json: true, no_rebase: true, attempt_entrypoint: entrypoint)
    resolved = task(folder: "/tmp/task-folder", stage_name: "execute", stage_index: 4)
    run.define_singleton_method(:resolve_task) { resolved }
    run.define_singleton_method(:do_call) { flunk "durable caller executed worker body" }

    assert_same result, run.call
    assert_equal 1, calls.length
    assert_equal "4-execute", calls.first.fetch(:intended_stage)
    assert_equal [ "hive", "run", "/tmp/task-folder", "--json", "--no-rebase" ],
                 calls.first.fetch(:argv)
  end

  def test_attempt_context_executes_existing_body_without_redispatch
    run = command(durable: true)
    calls = []
    run.define_singleton_method(:do_call) { calls << :worker; :done }

    value = with_attempt_context(
      attempt_id: "attempt-1", task_generation: 1, ownership_generation: "generation-1"
    ) do
      run.call
    end

    assert_equal :done, value
    assert_equal [ :worker ], calls
  end

  def test_admitted_worker_revalidates_generation_inside_task_lock_before_config
    run = command(durable: true)
    resolved = task(folder: "/tmp/task-folder", stage_name: "execute", stage_index: 4)
    run.define_singleton_method(:resolve_task) { resolved }
    inside_lock = false
    context = Object.new
    context.define_singleton_method(:validate_generation!) do |_task|
      raise "generation validation escaped task lock" unless inside_lock

      raise Hive::ConcurrentRunError, "stale durable generation"
    end
    lock = lambda do |*_args, **_kwargs, &block|
      inside_lock = true
      block.call
    ensure
      inside_lock = false
    end

    with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
      with_replaced_singleton_method(Hive::Lock, :with_task_lock, lock) do
        with_replaced_singleton_method(Hive::DependencySnapshot, :enforce_admission!, ->(_task) { true }) do
          with_replaced_singleton_method(Hive::Config, :load, ->(*) { raise "config loaded before generation gate" }) do
            assert_raises(Hive::ConcurrentRunError) { run.call }
          end
        end
      end
    end
  end

  def test_failed_durable_json_attempt_without_stdout_emits_one_error_document
    result = Hive::Attempts::ClientResult.new(
      status: :terminal, exit_status: Hive::ExitCodes::SOFTWARE, outcome: "failed",
      receipt: {}, attempt_id: "attempt-empty", stdout_bytes: 0
    )
    entrypoint = Object.new
    entrypoint.define_singleton_method(:dispatch) { |**_kwargs| result }
    run = command(durable: true, json: true, attempt_entrypoint: entrypoint)
    resolved = task(folder: "/tmp/task-folder", stage_name: "execute", stage_index: 4)
    run.define_singleton_method(:resolve_task) { resolved }

    out, = capture_io do
      error = assert_raises(Hive::AttemptExecutionError) { run.call }
      assert_equal Hive::ExitCodes::SOFTWARE, error.exit_code
    end

    assert_equal 1, out.lines.length
    payload = JSON.parse(out)
    assert_equal "hive-run", payload.fetch("schema")
    assert_equal "internal", payload.fetch("error_kind")
    assert_equal Hive::ExitCodes::SOFTWARE, payload.fetch("exit_code")
    assert_includes payload.fetch("message"), "attempt-empty"
  end

  def test_failed_durable_json_attempt_with_worker_stdout_does_not_duplicate_it
    result = Hive::Attempts::ClientResult.new(
      status: :terminal, exit_status: Hive::ExitCodes::SOFTWARE, outcome: "failed",
      receipt: {}, attempt_id: "attempt-output", stdout_bytes: 12
    )
    entrypoint = Object.new
    entrypoint.define_singleton_method(:dispatch) { |**_kwargs| result }
    run = command(durable: true, json: true, attempt_entrypoint: entrypoint)
    resolved = task(folder: "/tmp/task-folder", stage_name: "execute", stage_index: 4)
    run.define_singleton_method(:resolve_task) { resolved }

    out, = capture_io do
      exit_error = assert_raises(SystemExit) { run.call }
      assert_equal Hive::ExitCodes::SOFTWARE, exit_error.status
    end
    assert_empty out
  end

  def test_lost_durable_json_attempt_with_worker_stdout_does_not_duplicate_it
    result = Hive::Attempts::ClientResult.new(
      status: :lost, exit_status: Hive::ExitCodes::TEMPFAIL, outcome: "lost",
      receipt: nil, attempt_id: "attempt-lost-output", stdout_bytes: 12
    )
    entrypoint = Object.new
    entrypoint.define_singleton_method(:dispatch) { |**_kwargs| result }
    run = command(durable: true, json: true, attempt_entrypoint: entrypoint)
    resolved = task(folder: "/tmp/task-folder", stage_name: "execute", stage_index: 4)
    run.define_singleton_method(:resolve_task) { resolved }

    out, = capture_io do
      exit_error = assert_raises(SystemExit) { run.call }
      assert_equal Hive::ExitCodes::TEMPFAIL, exit_error.status
    end
    assert_empty out
  end

  def test_lost_durable_attempt_emits_versioned_json_error_envelope
    resolved = task(folder: "/tmp/task-folder", stage_name: "execute", stage_index: 4)
    attempt = Struct.new(:attempt_id).new("attempt-lost")
    dispatch_result = Hive::Attempts::DispatchResult.new(
      status: :accepted, attempt: attempt, receipt: nil,
      attach_descriptor: { "attempt_id" => attempt.attempt_id }, reason: nil
    )
    dispatcher = Object.new
    dispatcher.define_singleton_method(:dispatch) { |**_kwargs| dispatch_result }
    client = Object.new
    client.define_singleton_method(:attach) do |id|
      Hive::Attempts::ClientResult.new(
        status: :lost, exit_status: Hive::ExitCodes::TEMPFAIL,
        outcome: "lost", receipt: nil, attempt_id: id
      )
    end
    entrypoint = Hive::Attempts::Entrypoint.new(
      store: Object.new, dispatcher: dispatcher, client: client,
      config_loader: ->(_root) { Hive::Config.merge_defaults({}) }
    )
    run = command(durable: true, json: true, attempt_entrypoint: entrypoint)
    run.define_singleton_method(:resolve_task) { resolved }

    out, = capture_io do
      @lost_error = assert_raises(Hive::ConcurrentRunError) { run.call }
    end

    payload = JSON.parse(out)
    assert_equal "hive-run", payload.fetch("schema")
    assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-run"), payload.fetch("schema_version")
    assert_equal "concurrent_run", payload.fetch("error_kind")
    assert_equal Hive::ExitCodes::TEMPFAIL, payload.fetch("exit_code")
    assert_includes payload.fetch("message"), "attempt-lost"
  end
end
