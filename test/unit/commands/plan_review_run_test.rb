require "test_helper"
require "hive/commands/plan_review_run"

class PlanReviewRunCommandTest < Minitest::Test
  Task = Struct.new(:slug, keyword_init: true)
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
end
