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
        assert_includes File.read(triage), "Readiness: 2/2 ready"
        assert_includes File.read(triage), "## Required edits"
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

  private

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

    def council_workflow(quorum: 2, max_rounds: 1, exit_rule: :human, revise: false)
      Hive::Workflow.new(
        id: :council_test,
        stages: [
          Hive::Workflow::Stage.new(name: "draft", index: 1, state_file: "draft.md", kind: :agent, skill: "/draft"),
          Hive::Workflow::Stage.new(
            name: "review",
            index: 2,
            state_file: "review.md",
            kind: :council,
            reviewers: [
              Hive::Workflow::Reviewer.new(name: "one", skill: "/review"),
              Hive::Workflow::Reviewer.new(name: "two", skill: "/review")
            ],
            council: Hive::Workflow::Council.new(
              quorum: quorum,
              max_rounds: max_rounds,
              exit_rule: exit_rule,
              revise: revise ? Hive::Workflow::Revise.new(skill: "/revise") : nil
            )
          ),
          Hive::Workflow::Stage.new(name: "done", index: 3, state_file: "done.md", kind: :inert)
        ]
      )
    end

    def command_council_workflow
      Hive::Workflow.new(
        id: :command_council,
        stages: [
          Hive::Workflow::Stage.new(name: "draft", index: 1, state_file: "draft.md", kind: :agent, skill: "/draft"),
          Hive::Workflow::Stage.new(
            name: "review",
            index: 2,
            state_file: "review.md",
            kind: :council,
            reviewers: [
              Hive::Workflow::Reviewer.new(
                name: "shell",
                command: "printf 'Verdict: ready\\n' > \"$HIVE_COUNCIL_OUTPUT\""
              )
            ],
            council: Hive::Workflow::Council.new(quorum: 1)
          ),
          Hive::Workflow::Stage.new(name: "done", index: 3, state_file: "done.md", kind: :inert)
        ]
      )
    end
end
