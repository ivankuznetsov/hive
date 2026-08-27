require "test_helper"
require "hive/commands/guarded_archive"
require "hive/commands/stage_action"

class GuardedArchiveTest < Minitest::Test
  include HiveTestHelper

  FakeStage = Struct.new(:dir)
  FakeWorkflow = Struct.new(:stages)

  def fake_task(folder:, state_file:, workflow_stages:, hive_state_path: "/tmp/hive-state")
    Struct.new(
      :folder, :state_file, :slug, :stage_index, :stage_name,
      :workflow, :hive_state_path, keyword_init: true
    ).new(
      folder: folder,
      state_file: state_file,
      slug: "guarded-task",
      stage_index: 4,
      stage_name: "execute",
      workflow: FakeWorkflow.new(workflow_stages),
      hive_state_path: hive_state_path
    )
  end

  def build_protocol(task, current_stage:, target_stage:, guards:, observations:)
    Hive::Commands::GuardedArchive.new(
      task: task,
      current_stage: current_stage,
      target_stage: target_stage,
      transition_guard: ->(locked) { guards << locked },
      observation_guard: ->(locked) { observations << locked }
    )
  end

  def test_terminal_task_with_complete_marker_is_a_noop_completion
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      File.write(state_file, "# task\n<!-- COMPLETE -->\n")
      task = fake_task(folder: dir, state_file: state_file, workflow_stages: [ FakeStage.new("4-execute") ])
      guards = []
      protocol = build_protocol(
        task, current_stage: dir, target_stage: dir, guards: guards, observations: []
      )
      runs = []
      protocol.define_singleton_method(:run_at) { |_folder| runs << _folder }
      completed = []
      events = Object.new
      events.define_singleton_method(:task_completed) { |t| completed << t; t }
      protocol.define_singleton_method(:publisher) { events }

      result = protocol.call

      assert_same task, result
      assert_empty runs, "an already-completed terminal task must not re-run Done"
      assert_equal [ task ], guards
      assert_equal [ task ], completed
    end
  end

  def test_markerless_terminal_task_resumes_without_rebase_and_without_completion_event
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      File.write(state_file, "# task\n")
      task = fake_task(folder: dir, state_file: state_file, workflow_stages: [ FakeStage.new("4-execute") ])
      guards = []
      protocol = build_protocol(
        task, current_stage: dir, target_stage: dir, guards: guards, observations: []
      )
      runs = []
      protocol.define_singleton_method(:run_at) { |folder| runs << folder }
      never_publish = Object.new
      never_publish.define_singleton_method(:task_completed) { |_t| flunk("markerless resume must not publish completion") }
      protocol.define_singleton_method(:publisher) { never_publish }

      with_replaced_singleton_method(Hive::Task, :new, ->(*) { task }) do
        result = protocol.call
        assert_same task, result
      end
      assert_equal [ dir ], runs, "resume must run Done in place"
      assert_equal [ task ], guards
    end
  end

  def test_active_stage_retirement_guards_upfront_and_inside_the_atomic_move_lock
    with_tmp_dir do |dir|
      state_root = File.join(dir, ".hive-state")
      source = File.join(state_root, "stages", "4-execute", "guarded-task")
      done = File.join(state_root, "stages", "9-done", "guarded-task")
      FileUtils.mkdir_p(source)
      state_file = File.join(source, "task.md")
      File.write(state_file, "# task\n")
      task = fake_task(
        folder: source, state_file: state_file,
        workflow_stages: [ FakeStage.new("4-execute") ],
        hive_state_path: state_root
      )
      last_stage_dir = File.join(state_root, "stages", "9-done")
      guards = []
      observations = []
      protocol = build_protocol(
        task, current_stage: "4-execute",
        target_stage: "9-done", guards: guards, observations: observations
      )
      approvals = []
      runs = []
      protocol.define_singleton_method(:run_at) { |folder| runs << folder }
      never_publish = Object.new
      never_publish.define_singleton_method(:task_completed) { |_t| flunk("completion belongs to the moved task, stubbed here") }
      protocol.define_singleton_method(:publisher) { never_publish }
      approve_stub = lambda do |folder, **kwargs|
        approvals << [ folder, kwargs ]
        # Simulate the atomic move performed under Approve's lock, then
        # exercise exactly the guard composition StageAction used to own.
        kwargs.fetch(:observation_guard).call(task)
        FileUtils.mkdir_p(File.dirname(done))
        FileUtils.mv(source, done)
        approver = Object.new
        approver.define_singleton_method(:call) { nil }
        approver
      end
      with_replaced_singleton_method(Hive::Commands::Approve, :new, approve_stub) do
        with_replaced_singleton_method(Hive::Task, :new, ->(*) { task }) do
          protocol.call
        end
      end

      assert_equal 1, approvals.length
      approval_folder, approval_kwargs = approvals.first
      assert_equal source, approval_folder
      assert_equal "9-done", approval_kwargs.fetch(:to)
      assert_equal "4-execute", approval_kwargs.fetch(:from)
      assert approval_kwargs.fetch(:force)
      assert approval_kwargs.fetch(:quiet)
      refute approval_kwargs.key?(:no_rebase)
      assert_equal [ File.join(last_stage_dir, "guarded-task") ], runs
      assert_equal [ task, task ], guards, "guard must run before the move and again inside the lock"
      assert_equal [ task ], observations, "observation must compose after the receipt guard inside the lock"
    end
  end

  def test_stage_action_boundary_carries_no_closure_specific_path
    refute_respond_to Hive::Commands::StageAction, :archive_with_closure
    source = File.read(File.expand_path("../../../lib/hive/commands/stage_action.rb", __dir__))
    refute_includes source, "TaskClosure"
    refute_includes source, "closure_receipt_digest"
    refute_includes source, "close_with_receipt"
  end
end
