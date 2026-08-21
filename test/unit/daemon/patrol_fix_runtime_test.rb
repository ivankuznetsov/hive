require "test_helper"
require "hive/daemon/patrol_fix_runtime"

class HiveDaemonPatrolFixRuntimeTest < Minitest::Test
  include HiveTestHelper

  Row = Data.define(:project, :slug, :stage, :marker, :marker_attrs, :patrol_fix)

  class Projection
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(**arguments)
      @calls << arguments
      {
        "schema" => "hive-patrol-fix-operational-projection",
        "project" => arguments.fetch(:project).fetch("name"),
        "tasks" => arguments.fetch(:tasks)
      }
    end

    def unavailable(**)
      raise "unexpected unavailable projection"
    end
  end

  def test_groups_final_task_rows_by_project_and_preserves_only_current_hold
    with_tmp_dir do |dir|
      projection = Projection.new
      entries = %w[alpha beta].map do |name|
        root = File.join(dir, name)
        {
          "name" => name, "path" => root,
          "hive_state_path" => File.join(root, ".hive-state")
        }
      end
      runtime = Hive::Daemon::PatrolFixRuntime.new(
        registry: -> { entries }, config_loader: ->(_path) { { "loaded" => true } },
        operational_projection: projection
      )
      held = Row.new(
        project: "alpha", slug: "repair-auth", stage: "2-fix", marker: "error",
        marker_attrs: {
          "reason" => "limits_reached", "provider" => "codex",
          "retry_after" => "2026-08-21T14:00:00Z"
        },
        patrol_fix: { "state" => "current" }
      )

      rows = runtime.operational_projections(tasks: [ held ], now: Time.utc(2026, 8, 21, 12))

      assert_equal %w[alpha beta], rows.keys
      task = rows.dig("alpha", "tasks", 0)
      assert_equal "repair-auth", task.fetch("slug")
      assert_equal "codex", task.dig("held", "provider")
      assert_equal "2026-08-21T14:00:00Z", task.dig("held", "retry_after")
      assert_empty rows.dig("beta", "tasks")
      assert_equal 2, projection.calls.length
    end
  end
end
