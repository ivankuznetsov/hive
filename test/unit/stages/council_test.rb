require "test_helper"
require "hive/markers"
require "hive/stages/council"

class StagesCouncilTest < Minitest::Test
  include HiveTestHelper

  TaskStub = Struct.new(
    :project_root, :folder, :state_file, :stage_name, :slug,
    :stage_index, :log_dir, :project_name, :workflow,
    keyword_init: true
  )

  def task_for(project, workflow: council_workflow)
    stage = workflow.stage_named("review")
    folder = File.join(project, ".hive-state", "stages", stage.dir, "demo-260708-abcd")
    FileUtils.mkdir_p(folder)
    TaskStub.new(
      project_root: project,
      folder: folder,
      state_file: File.join(folder, stage.state_file),
      stage_name: "review",
      slug: "demo-260708-abcd",
      stage_index: stage.index,
      log_dir: File.join(project, ".hive-state", "logs", "demo-260708-abcd"),
      project_name: File.basename(project),
      workflow: workflow
    )
  end

  def test_consensus_first_round_writes_triage_and_complete_marker
    with_tmp_dir do |project|
      workflow = council_workflow
      task = task_for(project, workflow: workflow)
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")

      with_stubbed_spawn([ "Verdict: ready\n\n## Findings\n- OK\n", "Verdict: ready\n" ]) do
        result = Hive::Stages::Council.run!(task, {})

        marker = Hive::Markers.current(task.state_file)
        triage = File.join(task.folder, "reviews", "triage-01.md")
        assert_equal({ commit: "complete", status: :complete }, result)
        assert_equal :complete, marker.name
        assert File.exist?(triage), "triage-01.md must be written"
        triage_body = File.read(triage)
        assert_includes triage_body, "Readiness: 2/2 ready"
        assert_includes triage_body, "## Required edits"
        # Plan R2 lists all triage sections as required content.
        assert_includes triage_body, "## Accepted findings"
        assert_includes triage_body, "## Rejected findings"
      end
    end
  end

  def test_disagreement_with_human_exit_rule_waits_for_revision
    with_tmp_dir do |project|
      workflow = council_workflow(exit_rule: :human, quorum: 2)
      task = task_for(project, workflow: workflow)
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")

      with_stubbed_spawn([ "Verdict: ready\n", "Verdict: changes_requested\n\n## Required edits\n- Clarify API.\n" ]) do
        result = Hive::Stages::Council.run!(task, {})

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "round_waiting", status: :waiting }, result)
        assert_equal :waiting, marker.name
        assert_equal "needs_revision", marker.attrs.fetch("reason")
        assert_includes File.read(File.join(task.folder, "reviews", "triage-01.md")), "Open disagreements"
      end
    end
  end

  def test_consensus_exit_rule_with_revise_runs_another_round
    with_tmp_dir do |project|
      workflow = council_workflow(exit_rule: :consensus, max_rounds: 2, revise: true)
      task = task_for(project, workflow: workflow)
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")
      outputs = [
        "Verdict: ready\n",
        "Verdict: changes_requested\n\n## Required edits\n- Expand risks.\n",
        "Verdict: ready\n",
        "Verdict: ready\n"
      ]

      with_stubbed_spawn(outputs) do |captured|
        result = Hive::Stages::Council.run!(task, {})

        assert_equal({ commit: "complete", status: :complete }, result)
        assert_equal 5, captured.length, "two reviewer rounds plus one revise spawn"
        assert File.exist?(File.join(task.folder, "reviews", "triage-01.md"))
        assert File.exist?(File.join(task.folder, "reviews", "triage-02.md"))
      end
    end
  end

  def test_descriptor_limits_reach_every_reviewer_and_revise_agent_spawn
    with_tmp_dir do |project|
      workflow = council_workflow(
        exit_rule: :consensus,
        max_rounds: 2,
        revise: true,
        budget_usd: 7.5,
        timeout_sec: 61
      )
      task = task_for(project, workflow: workflow)
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")
      outputs = [
        "Verdict: ready\n",
        "Verdict: changes_requested\n\n## Required edits\n- Expand risks.\n",
        "Verdict: ready\n",
        "Verdict: ready\n"
      ]

      with_stubbed_spawn(outputs) do |captured|
        result = Hive::Stages::Council.run!(task, {})

        assert_equal({ commit: "complete", status: :complete }, result)
        assert_equal 5, captured.length
        assert captured.all? { |kwargs| kwargs.fetch(:max_budget_usd) == 7.5 }
        assert captured.all? { |kwargs| kwargs.fetch(:timeout_sec) == 61 }
      end
    end
  end

  def test_managed_council_children_launch_with_only_their_mapped_identity
    with_tmp_dir do |project|
      workflow = mixed_provider_council_workflow
      task = task_for(project, workflow: workflow)
      task.define_singleton_method(:managed_workflow?) { true }
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")
      outputs = [
        "Verdict: ready\n",
        "Verdict: changes_requested\n\n## Required edits\n- Expand risks.\n",
        "Verdict: ready\n",
        "Verdict: ready\n"
      ]

      with_stubbed_managed_scope(task) do
        with_stubbed_spawn(outputs) do |captured|
          result = Hive::Stages::Council.run!(task, {})

          assert_equal({ commit: "complete", status: :complete }, result)
          reviewer_one = captured.select { |kwargs| kwargs.fetch(:log_label) == "review-one" }
          reviewer_two = captured.select { |kwargs| kwargs.fetch(:log_label) == "review-two" }
          reviser = captured.select { |kwargs| kwargs.fetch(:log_label) == "review-revise" }
          assert_equal 2, reviewer_one.length
          assert reviewer_one.all? do |kwargs|
            kwargs.fetch(:profile).name == :pi &&
              kwargs.fetch(:model) == "pi-child" && kwargs[:effort].nil?
          end
          assert_equal 2, reviewer_two.length
          assert reviewer_two.all? do |kwargs|
            kwargs.fetch(:profile).name == :codex &&
              kwargs.fetch(:model) == "codex-child" && kwargs.fetch(:effort) == "medium"
          end
          assert_equal 1, reviser.length
          assert_equal :grok, reviser.first.fetch(:profile).name
          assert_equal "grok-child", reviser.first.fetch(:model)
          assert_nil reviser.first[:effort]
        end
      end
    end
  end

  def test_unmanaged_council_children_retain_parent_identity_fallback
    with_tmp_dir do |project|
      workflow = mixed_provider_council_workflow(managed_children: false)
      task = task_for(project, workflow: workflow)
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")

      with_stubbed_spawn([ "Verdict: ready\n", "Verdict: ready\n" ]) do |captured|
        result = Hive::Stages::Council.run!(task, {})

        assert_equal({ commit: "complete", status: :complete }, result)
        assert_equal 2, captured.length
        assert captured.all? { |kwargs| kwargs.fetch(:profile).name == :claude }
        assert captured.all? { |kwargs| kwargs.fetch(:model) == "claude-parent" }
        assert captured.all? { |kwargs| kwargs.fetch(:effort) == "high" }
      end
    end
  end

  def test_command_revise_runs_before_next_round
    with_tmp_dir do |project|
      revise = Hive::Workflow::Revise.new(
        command: "printf '\\ncommand revised round=%s\\n' \"$HIVE_COUNCIL_ROUND\" >> \"$HIVE_COUNCIL_INPUT\""
      )
      workflow = council_workflow(exit_rule: :consensus, max_rounds: 2, revise: revise)
      task = task_for(project, workflow: workflow)
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")
      outputs = [
        "Verdict: changes_requested\n\n## Required edits\n- Expand risks.\n",
        "Verdict: changes_requested\n\n## Required edits\n- Expand risks.\n",
        "Verdict: ready\n",
        "Verdict: ready\n"
      ]

      with_stubbed_spawn(outputs) do
        result = Hive::Stages::Council.run!(task, {})

        assert_equal({ commit: "complete", status: :complete }, result)
        assert_includes File.read(File.join(task.folder, "draft.md")), "command revised round=1"
      end
    end
  end

  def test_command_revise_failure_marks_error
    with_tmp_dir do |project|
      revise = Hive::Workflow::Revise.new(command: "printf 'revise boom' >&2; exit 9")
      workflow = council_workflow(exit_rule: :consensus, max_rounds: 2, revise: revise)
      task = task_for(project, workflow: workflow)
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")

      with_stubbed_spawn([ "Verdict: changes_requested\n", "Verdict: changes_requested\n" ]) do
        result = Hive::Stages::Council.run!(task, {})

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result)
        assert_equal "council_failed", marker.attrs.fetch("reason")
        assert_includes marker.attrs.fetch("message"), "council revise failed: revise boom"
      end
    end
  end

  def test_agent_revise_failure_marks_error
    with_tmp_dir do |project|
      workflow = council_workflow(exit_rule: :consensus, max_rounds: 2, revise: true)
      task = task_for(project, workflow: workflow)
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")

      with_revise_spawn_failure([ "Verdict: changes_requested\n", "Verdict: changes_requested\n" ]) do
        result = Hive::Stages::Council.run!(task, {})

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result)
        assert_equal "council_failed", marker.attrs.fetch("reason")
        assert_includes marker.attrs.fetch("message"), "council revise failed: revise agent failed"
      end
    end
  end

  def test_unstructured_review_defaults_to_not_ready
    with_tmp_dir do |project|
      workflow = council_workflow(quorum: 1)
      task = task_for(project, workflow: workflow)
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")
      review_path = File.join(task.folder, "reviews", "one-01.md")
      FileUtils.mkdir_p(File.dirname(review_path))
      File.write(review_path, "Looks close, probably ready soon.\n")

      triage = Hive::Stages::Council::Triage.run!(
        stage: workflow.stage_named("review"),
        review_paths: [ review_path ],
        round: 1,
        target_path: File.join(task.folder, "draft.md"),
        task_folder: task.folder
      )

      refute triage.ready
      assert_includes File.read(triage.path), "Readiness: 0/1 ready"
    end
  end

  def test_max_rounds_waits_instead_of_looping_forever
    with_tmp_dir do |project|
      workflow = council_workflow(exit_rule: :consensus, max_rounds: 1, revise: true)
      task = task_for(project, workflow: workflow)
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")

      with_stubbed_spawn([ "Verdict: changes_requested\n", "Verdict: changes_requested\n" ]) do |captured|
        result = Hive::Stages::Council.run!(task, {})

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "round_waiting", status: :waiting }, result)
        assert_equal "max_rounds", marker.attrs.fetch("reason")
        assert_equal 2, captured.length, "revise must not run after max_rounds is reached"
      end
    end
  end

  def test_max_rounds_can_complete_for_bounded_delivery_workflows
    with_tmp_dir do |project|
      workflow = council_workflow(exit_rule: :consensus, max_rounds: 1, revise: true)
      council = workflow.stage_named("review").council.with(on_max_rounds: :complete)
      stages = workflow.stages.map do |stage|
        stage.name == "review" ? stage.with(council: council) : stage
      end
      task = task_for(project, workflow: Hive::Workflow.new(id: workflow.id, stages: stages))
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")

      with_stubbed_spawn([ "Verdict: changes_requested\n", "Verdict: changes_requested\n" ]) do |captured|
        result = Hive::Stages::Council.run!(task, {})

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "complete", status: :complete }, result)
        assert_equal "max_rounds", marker.attrs.fetch("reason")
        assert_equal 2, captured.length, "revise must not run after max_rounds is reached"
      end
    end
  end

  def test_missing_input_marks_error
    with_tmp_dir do |project|
      task = task_for(project, workflow: council_workflow)

      result = Hive::Stages::Council.run!(task, {})

      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "error", status: :error }, result)
      assert_equal "missing_input", marker.attrs.fetch("reason")
    end
  end

  def test_command_reviewer_can_produce_review_file
    with_tmp_dir do |project|
      workflow = command_council_workflow
      task = task_for(project, workflow: workflow)
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")

      result = Hive::Stages::Council.run!(task, {})

      assert_equal({ commit: "complete", status: :complete }, result)
      assert_includes File.read(File.join(task.folder, "reviews", "shell-01.md")), "Verdict: ready"
    end
  end

  def test_command_reviewer_failure_surfaces_stage_error
    with_tmp_dir do |project|
      workflow = command_council_workflow(command: "printf 'boom' >&2; exit 7")
      task = task_for(project, workflow: workflow)
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")

      result = Hive::Stages::Council.run!(task, {})

      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "error", status: :error }, result)
      assert_equal "council_failed", marker.attrs.fetch("reason")
      assert_includes marker.attrs.fetch("message"), "council reviewer shell failed: boom"
    end
  end

  def test_command_reviewer_is_terminated_at_stage_timeout
    with_tmp_dir do |project|
      workflow = command_council_workflow(
        command: "sleep 3; printf 'Verdict: ready\\n' > \"$HIVE_COUNCIL_OUTPUT\"",
        timeout_sec: 0.1
      )
      task = task_for(project, workflow: workflow)
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Hive::Stages::Council.run!(task, {})
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "error", status: :error }, result)
      assert_equal "council_failed", marker.attrs.fetch("reason")
      assert_includes marker.attrs.fetch("message"), "timed out after 0.1s"
      assert_operator elapsed, :<, 1.0
    end
  end

  def test_command_revise_is_terminated_at_stage_timeout
    with_tmp_dir do |project|
      revise = Hive::Workflow::Revise.new(command: "sleep 3")
      workflow = council_workflow(
        exit_rule: :consensus,
        max_rounds: 2,
        revise: revise,
        timeout_sec: 0.1
      )
      task = task_for(project, workflow: workflow)
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = nil
      with_stubbed_spawn([ "Verdict: changes_requested\n", "Verdict: changes_requested\n" ]) do
        result = Hive::Stages::Council.run!(task, {})
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "error", status: :error }, result)
      assert_equal "council_failed", marker.attrs.fetch("reason")
      assert_includes marker.attrs.fetch("message"), "timed out after 0.1s"
      assert_operator elapsed, :<, 1.0
    end
  end

  def test_command_timeout_force_kills_a_process_group_that_ignores_term
    with_tmp_dir do |project|
      error = assert_raises(Hive::StageError) do
        Hive::Stages::Council::CommandRunner.run(
          {},
          "trap '' TERM; while :; do sleep 1; done",
          chdir: project,
          timeout_sec: 0.05,
          label: "stubborn council command"
        )
      end

      assert_equal "stubborn council command timed out after 0.05s", error.message
    end
  end

  def test_failed_reviewer_spawn_surfaces_error_marker
    with_tmp_dir do |project|
      task = task_for(project, workflow: council_workflow)
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")

      with_failing_spawn do
        result = Hive::Stages::Council.run!(task, {})

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result)
        assert_equal :error, marker.name
        assert_equal "council_failed", marker.attrs.fetch("reason")
      end
    end
  end

  def test_missing_reviewer_instruction_marks_council_io_error
    with_tmp_dir do |project|
      missing = File.join(project, "missing-reviewer.md")
      workflow = instruction_council_workflow(reviewer_instruction: missing)
      task = task_for(project, workflow: workflow)
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")

      result = Hive::Stages::Council.run!(task, {})

      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "error", status: :error }, result)
      assert_equal "council_io_error", marker.attrs.fetch("reason")
      assert_includes marker.attrs.fetch("message"), "No such file"
    end
  end

  def test_explicit_input_reviews_that_file_not_prior_stage_fallback
    with_tmp_dir do |project|
      workflow = council_workflow(input: "custom-input.md")
      task = task_for(project, workflow: workflow)
      # The prior stage's state_file (draft.md) is intentionally NOT created:
      # if `input:` were ignored the council would resolve to draft.md and
      # fail with missing_input rather than reviewing custom-input.md.
      File.write(File.join(task.folder, "custom-input.md"), "CUSTOM-INPUT-MARKER document\n")

      with_stubbed_spawn([ "Verdict: ready\n", "Verdict: ready\n" ]) do |captured|
        result = Hive::Stages::Council.run!(task, {})

        assert_equal({ commit: "complete", status: :complete }, result)
        prompts = captured.map { |kwargs| kwargs[:prompt].to_s }
        assert prompts.any? { |p| p.include?("CUSTOM-INPUT-MARKER") },
               "reviewer prompt must embed the explicit input: document"
      end
    end
  end

  def test_resume_after_waiting_re_triages_same_round
    with_tmp_dir do |project|
      workflow = council_workflow(exit_rule: :human, quorum: 2)
      task = task_for(project, workflow: workflow)
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")

      # First run: reviewers disagree, human exit_rule -> :waiting on round 1.
      with_stubbed_spawn([ "Verdict: ready\n", "Verdict: changes_requested\n" ]) do
        Hive::Stages::Council.run!(task, {})
      end
      marker = Hive::Markers.current(task.state_file)
      assert_equal :waiting, marker.name
      assert_equal "1", marker.attrs.fetch("round")

      # Human edits the document and re-runs. Pre-flight must re-triage the SAME
      # round (no round++), not open round 2.
      File.write(File.join(task.folder, "draft.md"), "Architecture draft, revised.\n")
      with_stubbed_spawn([ "Verdict: changes_requested\n", "Verdict: changes_requested\n" ]) do
        result = Hive::Stages::Council.run!(task, {})
        assert_equal({ commit: "round_waiting", status: :waiting }, result)
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal "1", marker.attrs.fetch("round"), "resume must not increment the round"
      refute File.exist?(File.join(task.folder, "reviews", "triage-02.md")),
             "resume-after-waiting must re-triage round 1, not open round 2"
    end
  end

  def test_complete_council_short_circuits_without_respawning
    with_tmp_dir do |project|
      task = task_for(project, workflow: council_workflow)
      File.write(File.join(task.folder, "draft.md"), "Architecture draft\n")

      with_stubbed_spawn([ "Verdict: ready\n", "Verdict: ready\n" ]) do
        Hive::Stages::Council.run!(task, {})
      end
      assert_equal :complete, Hive::Markers.current(task.state_file).name

      # Re-running a :complete council must not spawn any reviewers.
      with_stubbed_spawn([]) do |captured|
        result = Hive::Stages::Council.run!(task, {})
        assert_equal({ commit: "complete", status: :complete }, result)
        assert_empty captured, "a complete council must short-circuit without re-spawning"
      end
    end
  end

  def test_custom_triage_output_rounds_skip_non_round_suffixes
    with_tmp_dir do |project|
      workflow = council_workflow(triage_output: "audit/summary.md")
      task = task_for(project, workflow: workflow)
      FileUtils.mkdir_p(File.join(task.folder, "audit"))
      File.write(File.join(task.folder, "audit", "summary-02.md"), "prior round\n")
      File.write(File.join(task.folder, "audit", "summary-draft.md"), "ignore me\n")

      assert_equal 3, Hive::Stages::Council.next_round(task.folder, workflow.stage_named("review"))
    end
  end

  def test_action_for_none_and_unknown_marker_names
    assert_nil Hive::Stages::Council.action_for(:none)
    assert_equal "paused", Hive::Stages::Council.action_for(:paused)
  end

  def test_managed_council_children_require_mapped_agents_and_wrap_revise_prompts
    stage = Hive::Workflow::Stage.new(
      name: "review", index: 1, state_file: "review.md", kind: :council
    )
    task = Object.new
    task.define_singleton_method(:managed_workflow?) { true }
    task.define_singleton_method(:managed_prompt) { |slot, body| "#{slot}:#{body}" }

    reviewer = Hive::Workflow::Reviewer.new(name: "missing", prompt: "Review", permissions: "read-only")
    reviewer_runner = Hive::Stages::Council::Reviewer.new(
      task: task, cfg: {}, stage: stage, reviewer: reviewer, round: 1, target_path: "/tmp/draft.md"
    )
    assert_raises(Hive::ConfigError) { reviewer_runner.send(:launch_identity) }
    assert_equal "stages.review.reviewers.missing:body", reviewer_runner.send(:managed_prompt, "body")

    revise = Hive::Workflow::Revise.new(prompt: "Revise", permissions: "read-only")
    revise_runner = Hive::Stages::Council::Revise.new(
      task: task, cfg: {}, stage: stage, revise: revise, round: 1,
      target_path: "/tmp/draft.md", triage_path: "/tmp/triage.md"
    )
    assert_raises(Hive::ConfigError) { revise_runner.send(:launch_identity) }
    assert_equal "stages.review.revise:body", revise_runner.send(:managed_prompt, "body")
  end

  private

    def with_failing_spawn
      original = Hive::Stages::Base.method(:spawn_agent)
      Hive::Stages::Base.define_singleton_method(:spawn_agent) do |_task, **_kwargs|
        { status: :error, error_message: "reviewer spawn blew up" }
      end
      yield
    ensure
      Hive::Stages::Base.define_singleton_method(:spawn_agent) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end

    def with_stubbed_spawn(outputs)
      captured = []
      original = Hive::Stages::Base.method(:spawn_agent)
      Hive::Stages::Base.define_singleton_method(:spawn_agent) do |_task, **kwargs|
        captured << kwargs
        expected = kwargs[:expected_output]
        if kwargs[:log_label].to_s.end_with?("-revise")
          File.write(expected, "#{File.read(expected)}\nRevised.\n")
        else
          body = outputs.shift || "Verdict: ready\n"
          FileUtils.mkdir_p(File.dirname(expected))
          File.write(expected, body)
        end
        { status: :ok }
      end
      yield captured
    ensure
      Hive::Stages::Base.define_singleton_method(:spawn_agent) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end

    def with_revise_spawn_failure(outputs)
      captured = []
      original = Hive::Stages::Base.method(:spawn_agent)
      Hive::Stages::Base.define_singleton_method(:spawn_agent) do |_task, **kwargs|
        captured << kwargs
        if kwargs[:log_label].to_s.end_with?("-revise")
          { status: :error, error_message: "revise agent failed" }
        else
          body = outputs.shift || "Verdict: ready\n"
          FileUtils.mkdir_p(File.dirname(kwargs[:expected_output]))
          File.write(kwargs[:expected_output], body)
          { status: :ok }
        end
      end
      yield captured
    ensure
      Hive::Stages::Base.define_singleton_method(:spawn_agent) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end

    def with_stubbed_managed_scope(task)
      scope = {
        add_dirs: [ task.folder ], permission_mode: nil,
        allowed_tools: nil, disallowed_tools: nil
      }
      with_replaced_singleton_method(
        Hive::Stages::Base,
        :stage_permission_scope_or_mark!,
        ->(*, **) { scope }
      ) { yield }
    end

    def mixed_provider_council_workflow(managed_children: true)
      reviewers = if managed_children
        [
          Hive::Workflow::Reviewer.new(
            name: "one", skill: "/review", agent: "pi", model: "pi-child"
          ),
          Hive::Workflow::Reviewer.new(
            name: "two", skill: "/review", agent: "codex", model: "codex-child", effort: "medium"
          )
        ]
      else
        [
          Hive::Workflow::Reviewer.new(name: "one", skill: "/review"),
          Hive::Workflow::Reviewer.new(name: "two", skill: "/review")
        ]
      end
      revise = if managed_children
        Hive::Workflow::Revise.new(skill: "/revise", agent: "grok", model: "grok-child")
      else
        Hive::Workflow::Revise.new(skill: "/revise")
      end
      Hive::Workflow.new(
        id: :mixed_provider_council,
        stages: [
          Hive::Workflow::Stage.new(
            name: "draft", index: 1, state_file: "draft.md", kind: :agent, skill: "/draft"
          ),
          Hive::Workflow::Stage.new(
            name: "review", index: 2, state_file: "review.md", kind: :council,
            agent: "claude", model: "claude-parent", effort: "high",
            reviewers: reviewers,
            council: Hive::Workflow::Council.new(
              quorum: 2, max_rounds: 2, exit_rule: :consensus, revise: revise
            )
          ),
          Hive::Workflow::Stage.new(name: "done", index: 3, state_file: "done.md", kind: :inert)
        ]
      )
    end

    def council_workflow(quorum: 2, max_rounds: 1, exit_rule: :human, revise: false, input: nil,
                         triage_output: nil, budget_usd: nil, timeout_sec: nil)
      revise_config =
        case revise
        when Hive::Workflow::Revise
          revise
        when true
          Hive::Workflow::Revise.new(skill: "/revise")
        else
          nil
        end
      Hive::Workflow.new(
        id: :council_test,
        stages: [
          Hive::Workflow::Stage.new(name: "draft", index: 1, state_file: "draft.md", kind: :agent, skill: "/draft"),
          Hive::Workflow::Stage.new(
            name: "review",
            index: 2,
            state_file: "review.md",
            kind: :council,
            budget_usd: budget_usd,
            timeout_sec: timeout_sec,
            input: input,
            reviewers: [
              Hive::Workflow::Reviewer.new(name: "one", skill: "/review"),
              Hive::Workflow::Reviewer.new(name: "two", skill: "/review")
            ],
            council: Hive::Workflow::Council.new(
              quorum: quorum,
              max_rounds: max_rounds,
              exit_rule: exit_rule,
              triage_output: triage_output,
              revise: revise_config
            )
          ),
          Hive::Workflow::Stage.new(name: "done", index: 3, state_file: "done.md", kind: :inert)
        ]
      )
    end

    def command_council_workflow(command: "printf 'Verdict: ready\\n' > \"$HIVE_COUNCIL_OUTPUT\"",
                                 timeout_sec: nil)
      Hive::Workflow.new(
        id: :command_council,
        stages: [
          Hive::Workflow::Stage.new(name: "draft", index: 1, state_file: "draft.md", kind: :agent, skill: "/draft"),
          Hive::Workflow::Stage.new(
            name: "review",
            index: 2,
            state_file: "review.md",
            kind: :council,
            timeout_sec: timeout_sec,
            reviewers: [
              Hive::Workflow::Reviewer.new(
                name: "shell",
                command: command
              )
            ],
            council: Hive::Workflow::Council.new(quorum: 1)
          ),
          Hive::Workflow::Stage.new(name: "done", index: 3, state_file: "done.md", kind: :inert)
        ]
      )
    end

    def instruction_council_workflow(reviewer_instruction:)
      workflow = council_workflow
      review = workflow.stage_named("review")
      replacement = Hive::Workflow::Stage.new(
        name: review.name,
        index: review.index,
        state_file: review.state_file,
        kind: review.kind,
        reviewers: [
          Hive::Workflow::Reviewer.new(name: "one", instruction: reviewer_instruction)
        ],
        council: Hive::Workflow::Council.new(quorum: 1)
      )
      Hive::Workflow.new(id: workflow.id, stages: [ workflow.stages.first, replacement, workflow.stages.last ])
    end
end
