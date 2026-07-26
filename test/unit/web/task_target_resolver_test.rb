require "test_helper"
require "hive/web/task_target_resolver"

class WebTaskTargetResolverTest < Minitest::Test
  NativeTask = Data.define(:slug, :project_root, :folder, :stage_index, :stage_name)

  def test_cached_row_never_calls_the_fleet_status_producer_and_only_overlays_recovery
    Dir.mktmpdir("task-target") do |root|
      folder = File.join(root, ".hive-state", "stages", "4-execute", "ship-it")
      FileUtils.mkdir_p(folder)
      native = NativeTask.new(
        slug: "ship-it", project_root: root, folder: folder,
        stage_index: 4, stage_name: "execute"
      )
      status = Object.new
      status.define_singleton_method(:json_payload) { raise "fleet scan" }
      status.define_singleton_method(:project_payload) do |*, **|
        {
          "tasks" => [
            { "slug" => "ship-it", "folder" => folder, "stage" => "4-execute" }
          ]
        }
      end
      recovery = { "status" => "queued", "request_id" => "recovery-1" }
      row = {
        "slug" => "ship-it", "folder" => folder, "stage" => "stale",
        "recovery" => recovery
      }
      payload = { "projects" => [ { "name" => "demo", "tasks" => [ row ] } ] }

      result = Hive::Web::TaskTargetResolver.new(
        project: { "name" => "demo", "path" => root },
        slug: "ship-it", cached_payload: payload,
        status_command: status, task_resolver: -> { native }
      ).call

      assert_equal "targeted", result.source
      assert_equal "4-execute", result.attributes.fetch("stage")
      assert_same recovery, result.attributes.fetch("recovery")
    end
  end

  def test_cache_miss_scans_only_the_resolved_project_stage
    Dir.mktmpdir("task-target") do |root|
      folder = File.join(root, ".hive-state", "stages", "4-execute", "ship-it")
      FileUtils.mkdir_p(folder)
      native = NativeTask.new(
        slug: "ship-it", project_root: root, folder: folder,
        stage_index: 4, stage_name: "execute"
      )
      calls = []
      status = Object.new
      status.define_singleton_method(:json_payload) { raise "fleet scan" }
      status.define_singleton_method(:project_payload) do |project, **options|
        calls << [ project, options ]
        { "tasks" => [ { "slug" => "ship-it", "folder" => folder } ] }
      end

      result = Hive::Web::TaskTargetResolver.new(
        project: { "name" => "demo", "path" => root },
        slug: "ship-it", cached_payload: nil,
        status_command: status, task_resolver: -> { native }
      ).call

      assert_equal "targeted", result.source
      assert_equal 1, calls.size
      assert_equal [ "4-execute" ], calls.first.last.fetch(:stages)
      assert_equal "demo", calls.first.first.fetch("name")
    end
  end
end
