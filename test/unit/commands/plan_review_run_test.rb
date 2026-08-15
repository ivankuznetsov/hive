require "test_helper"
require "hive/commands/plan_review_run"

class PlanReviewRunCommandTest < Minitest::Test
  include HiveTestHelper

  Task = Struct.new(:slug, keyword_init: true)
  CommitTask = Struct.new(
    :slug, :project_root, :hive_state_path, :stage_index, :stage_name,
    keyword_init: true
  )
  Record = Struct.new(:state, keyword_init: true)
  Projection = Struct.new(:record, keyword_init: true) do
    def summary = { "state" => record.state }
  end

  def test_dispatches_only_the_non_authority_automation_service
    task = Task.new(slug: "demo-260812-abcd")
    projection = Projection.new(record: Record.new(state: "awaiting_decision"))
    calls = []
    command = Hive::Commands::PlanReviewRun.new(
      task.slug, resolver: -> { task },
      automation: ->(task:) { calls << task; projection },
      committer: ->(resolved, result) { calls << [ resolved, result ] }
    )

    out, = capture_io { assert_equal({ "state" => "awaiting_decision" }, command.call) }

    assert_equal [ task, [ task, projection ] ], calls
    assert_includes out, "plan review awaiting_decision"
  end

  def test_default_resolver_scopes_task_lookup_to_the_plan_stage
    task = Task.new(slug: "demo-260812-abcd")
    resolver = Object.new
    resolver.define_singleton_method(:resolve) { task }
    observed = nil
    factory = lambda do |target, **kwargs|
      observed = { target:, kwargs: }
      resolver
    end
    command = Hive::Commands::PlanReviewRun.new(
      task.slug, project: "demo",
      automation: ->(task:) { Projection.new(record: Record.new(state: "approved")) },
      committer: ->(*) { nil }
    )

    with_replaced_singleton_method(Hive::TaskResolver, :new, factory) do
      capture_io { command.call }
    end

    assert_equal task.slug, observed.fetch(:target)
    assert_equal "demo", observed.dig(:kwargs, :project_filter)
    assert_equal Hive::PlanReview::TransitionGuard::PLAN_STAGE,
                 observed.dig(:kwargs, :stage_filter)
  end

  def test_default_committer_records_a_hive_commit_under_the_commit_lock
    Dir.mktmpdir("plan-review-run-commit") do |root|
      state = File.join(root, ".hive-state")
      FileUtils.mkdir_p(state)
      task = CommitTask.new(
        slug: "demo-260812-abcd", project_root: root, hive_state_path: state,
        stage_index: 3, stage_name: "plan"
      )
      observed = nil
      ops = Object.new
      ops.define_singleton_method(:hive_commit) { |**kwargs| observed = kwargs }
      command = Hive::Commands::PlanReviewRun.new(
        task.slug, resolver: -> { task },
        automation: ->(task:) { Projection.new(record: Record.new(state: "approved")) }
      )

      with_replaced_singleton_method(Hive::GitOps, :new, ->(*) { ops }) do
        capture_io { command.call }
      end

      assert_equal "3-plan", observed.fetch(:stage_name)
      assert_equal task.slug, observed.fetch(:slug)
      assert_equal "run plan review automation", observed.fetch(:action)
    end
  end
end
