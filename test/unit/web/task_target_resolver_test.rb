require "test_helper"
require "hive/web/task_target_resolver"

class WebTaskTargetResolverTest < Minitest::Test
  include HiveTestHelper

  NativeTask = Data.define(:slug, :project_root, :folder, :stage_index, :stage_name)

  def test_target_resolution_does_not_read_unrelated_task_metadata
    Hive::RuntimeControlPlane.database.migrate!
    with_tmp_dir do |root|
      project = { "name" => "demo", "path" => root, "hive_state_path" => File.join(root, ".hive-state") }
      folders = %w[selected-task unrelated-task].map do |slug|
        folder = File.join(project.fetch("hive_state_path"), "stages", "1-inbox", slug)
        FileUtils.mkdir_p(folder)
        File.write(File.join(folder, "idea.md"), "<!-- WAITING -->\n")
        Hive::TaskMeta.write(folder, id: nil, slug: slug, display_name: nil)
        folder
      end
      reads = []
      original = Hive::TaskMeta.method(:read_for_admission)
      reader = ->(folder) { reads << folder.to_s; original.call(folder) }

      result = with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [ project ] }) do
        with_replaced_singleton_method(Hive::TaskMeta, :read_for_admission, reader) do
          Hive::Web::TaskTargetResolver.new(project: project, slug: "selected-task").call
        end
      end

      assert_equal "selected-task", result.attributes.fetch("slug")
      assert_equal [ folders.first ], reads.uniq
    end
  end

  def test_moved_tasks_use_the_current_folder_and_deleted_tasks_cannot_come_from_cache
    Hive::RuntimeControlPlane.database.migrate!
    with_tmp_dir do |root|
      project = { "name" => "demo", "path" => root, "hive_state_path" => File.join(root, ".hive-state") }
      folder = File.join(project.fetch("hive_state_path"), "stages", "1-inbox", "selected-task")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "idea.md"), "<!-- WAITING -->\n")
      Hive::TaskMeta.write(folder, id: 1, slug: "selected-task", display_name: nil)
      cached = {
        "projects" => [ project.merge("tasks" => [ {
          "slug" => "selected-task", "folder" => folder,
          "recovery" => { "status" => "queued", "request_id" => "old-recovery" }
        } ]) ]
      }
      resolver = Hive::Web::TaskTargetResolver.new(
        project: project, slug: "selected-task", cached_payload: cached
      )

      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [ project ] }) do
        assert_equal "1-inbox", resolver.call.attributes.fetch("stage")
        moved = File.join(project.fetch("hive_state_path"), "stages", "2-brainstorm", "selected-task")
        FileUtils.mkdir_p(File.dirname(moved))
        FileUtils.mv(folder, moved)
        File.write(File.join(moved, "brainstorm.md"), "<!-- WAITING -->\n")

        result = resolver.call
        assert_equal "2-brainstorm", result.attributes.fetch("stage")
        assert_equal moved, result.attributes.fetch("folder")
        refute result.attributes.key?("recovery")

        FileUtils.rm_rf(moved)
        assert_raises(Hive::InvalidTaskPath) { resolver.call }
      end
    end
  end

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
      status.define_singleton_method(:task_target_payload) do |*, **|
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

  def test_cache_miss_requests_only_the_resolved_project_task_and_stage
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
      status.define_singleton_method(:task_target_payload) do |project, **options|
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
      assert_equal "4-execute", calls.first.last.fetch(:stage)
      assert_equal "ship-it", calls.first.last.fetch(:slug)
      assert_equal "demo", calls.first.first.fetch("name")
    end
  end

  def test_default_task_resolver_is_scoped_to_the_selected_project
    Dir.mktmpdir("task-target") do |root|
      folder = File.join(root, ".hive-state", "stages", "4-execute", "ship-it")
      FileUtils.mkdir_p(folder)
      native = NativeTask.new(
        slug: "ship-it", project_root: root, folder: folder,
        stage_index: 4, stage_name: "execute"
      )
      constructor = nil
      fake_resolver = Object.new
      fake_resolver.define_singleton_method(:resolve) { native }
      replacement = lambda do |slug, project_filter:|
        constructor = [ slug, project_filter ]
        fake_resolver
      end
      status = Object.new
      status.define_singleton_method(:task_target_payload) do |*, **|
        { "tasks" => [ { "slug" => "ship-it", "folder" => folder } ] }
      end

      result = with_replaced_singleton_method(Hive::TaskResolver, :new, replacement) do
        Hive::Web::TaskTargetResolver.new(
          project: { "name" => "demo", "path" => root },
          slug: "ship-it", status_command: status
        ).call
      end

      assert_equal [ "ship-it", "demo" ], constructor
      assert_equal native, result.native_task
    end
  end

  def test_project_load_failure_is_an_actionable_error
    Dir.mktmpdir("task-target") do |root|
      folder = File.join(root, ".hive-state", "stages", "4-execute", "ship-it")
      FileUtils.mkdir_p(folder)
      native = NativeTask.new(
        slug: "ship-it", project_root: root, folder: folder,
        stage_index: 4, stage_name: "execute"
      )
      status = Object.new
      status.define_singleton_method(:task_target_payload) do |*, **|
        { "error" => "project_load_failed" }
      end

      error = assert_raises(Hive::Error) do
        Hive::Web::TaskTargetResolver.new(
          project: { "name" => "demo", "path" => root },
          slug: "ship-it", status_command: status, task_resolver: -> { native }
        ).call
      end

      assert_match(/project demo status is unavailable/, error.message)
    end
  end

  def test_foreign_native_task_is_rejected
    Dir.mktmpdir("task-target") do |root|
      foreign = Dir.mktmpdir("foreign-task")
      native = NativeTask.new(
        slug: "ship-it", project_root: foreign, folder: foreign,
        stage_index: 4, stage_name: "execute"
      )

      assert_raises(Hive::InvalidTaskPath) do
        Hive::Web::TaskTargetResolver.new(
          project: { "name" => "demo", "path" => root },
          slug: "ship-it", task_resolver: -> { native }
        ).call
      end
    ensure
      FileUtils.rm_rf(foreign) if foreign
    end
  end

  def test_missing_paths_compare_by_expanded_name
    root = File.expand_path("missing-project")
    folder = File.join(root, ".hive-state", "stages", "4-execute", "ship-it")
    native = NativeTask.new(
      slug: "ship-it", project_root: root, folder: folder,
      stage_index: 4, stage_name: "execute"
    )
    status = Object.new
    status.define_singleton_method(:task_target_payload) do |*, **|
      { "tasks" => [ { "slug" => "ship-it", "folder" => folder } ] }
    end

    result = Hive::Web::TaskTargetResolver.new(
      project: { "name" => "demo", "path" => root },
      slug: "ship-it", status_command: status, task_resolver: -> { native }
    ).call

    assert_equal "targeted", result.source
  end
end
