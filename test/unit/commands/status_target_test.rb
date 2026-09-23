require "test_helper"
require "hive/commands/status"

class CommandsStatusTargetTest < Minitest::Test
  include HiveTestHelper

  def setup
    Hive::RuntimeControlPlane.database.migrate!
  end

  def test_target_reads_only_the_requested_task_and_reachable_prerequisite_metadata
    with_tmp_dir do |root|
      project = status_project(root)
      target = write_task(project, "1-inbox", "selected-task", id: 2, depends_on: "terminal-base")
      prerequisite = write_task(project, "9-done", "terminal-base", id: 1)
      write_task(project, "1-inbox", "unrelated-active", id: 3)
      write_task(project, "9-done", "unrelated-terminal", id: 4)
      command = Hive::Commands::Status.new(json: true)
      command.define_singleton_method(:stage_task_entries) do |*|
        raise "target status must not enumerate stage children"
      end

      observe_task_reads do |metadata_reads, journal_reads|
        payload = target_payload(command, project, "selected-task", "1-inbox")

        assert_equal [ "selected-task" ], payload.fetch("tasks").map { |row| row.fetch("slug") }
        assert_equal false, payload.dig("tasks", 0, "blocked")
        assert_equal [ prerequisite, target ].sort, metadata_reads.uniq.sort
        assert_equal [ target ], journal_reads.uniq
      end
    end
  end

  def test_target_rechecks_dependency_metadata_after_each_request
    with_tmp_dir do |root|
      project = status_project(root)
      target = write_task(project, "1-inbox", "selected-task", id: 2, depends_on: "terminal-base")
      write_task(project, "9-done", "terminal-base", id: 1)
      command = Hive::Commands::Status.new(json: true)

      first = target_payload(command, project, "selected-task", "1-inbox").fetch("tasks").first
      assert_equal false, first.fetch("blocked")

      Hive::TaskMeta.write(
        target, id: 2, slug: "selected-task", display_name: nil, depends_on: "missing-base"
      )
      second = target_payload(command, project, "selected-task", "1-inbox").fetch("tasks").first
      assert_equal true, second.fetch("blocked")
      assert_equal "missing-base", second.fetch("depends_on")
      assert_equal "dependency_task_missing", second.dig("admission_error", "reason_code")
    end
  end

  def test_target_loads_transitive_cross_project_terminal_prerequisites_from_the_current_registry
    with_tmp_dir do |root|
      app = status_project(File.join(root, "app"))
      data = status_project(File.join(root, "data"), name: "data")
      data["repository_identity"] = "github.com/example/data"
      target = write_task(app, "1-inbox", "selected-task", id: 2, depends_on: "data:terminal-base")
      base = write_task(data, "9-done", "terminal-base", id: 2, depends_on: "terminal-parent")
      parent = write_task(data, "9-done", "terminal-parent", id: 1)
      write_task(data, "9-done", "unrelated-terminal", id: 3)
      command = Hive::Commands::Status.new(json: true)
      identity = ->(path) { path == data.fetch("path") ? data.fetch("repository_identity") : nil }

      observe_task_reads do |metadata_reads, journal_reads|
        with_replaced_singleton_method(Hive::RepositoryIdentity, :current, identity) do
          payload = target_payload(command, app, "selected-task", "1-inbox", projects: [ app, data ])
          assert_equal false, payload.dig("tasks", 0, "blocked")
          assert_nil payload.dig("tasks", 0, "admission_error")
        end
        assert_equal [ target, base, parent ].sort, metadata_reads.uniq.sort
        assert_equal [ target ], journal_reads.uniq
      end

      missing = target_payload(command, app, "selected-task", "1-inbox", projects: [ app ])
      assert_equal "dependency_project_unknown", missing.dig("tasks", 0, "admission_error", "reason_code")
    end
  end

  def test_target_uses_the_same_captured_workflow_config_for_admission_and_status
    with_tmp_dir do |root|
      project = status_project(root)
      write_task(project, "1-inbox", "selected-task", id: 2, depends_on: "finalizing-base")
      write_task(project, "8-finalize", "finalizing-base", id: 1)
      config_path = File.join(root, ".hive-state", "config.yml")
      File.write(config_path, "dependency_gate_stage: 8-finalize\n")
      original = Hive::DependencySnapshot.method(:targeted_admission_context)
      change_after_capture = lambda do |*args, **options|
        File.write(config_path, "dependency_gate_stage: 9-done\n")
        original.call(*args, **options)
      end
      command = Hive::Commands::Status.new(json: true)

      payload = with_replaced_singleton_method(
        Hive::DependencySnapshot, :targeted_admission_context, change_after_capture
      ) do
        target_payload(command, project, "selected-task", "1-inbox")
      end
      assert_equal false, payload.dig("tasks", 0, "blocked")

      refreshed = target_payload(command, project, "selected-task", "1-inbox")
      assert_equal true, refreshed.dig("tasks", 0, "blocked")
      assert_nil refreshed.dig("tasks", 0, "admission_error")
      assert_equal "8-finalize", refreshed.dig("tasks", 0, "dependency_stage")
    end
  end

  def test_target_preserves_ordinary_retention_and_explicit_archive_access
    with_tmp_dir do |root|
      project = status_project(root)
      now = Time.utc(2026, 9, 23)
      write_task(project, "9-done", "old-task", completed_at: now - 10 * 86_400)
      ordinary = target_payload(
        Hive::Commands::Status.new(json: true), project, "old-task", "9-done", now: now
      )
      archived = target_payload(
        Hive::Commands::Status.new(json: true, archive: true), project, "old-task", "9-done", now: now
      )

      assert_empty ordinary.fetch("tasks")
      assert_equal [ "old-task" ], archived.fetch("tasks").map { |row| row.fetch("slug") }
      refute archived.key?("hidden_archived_task_count")
    end
  end

  def test_target_returns_a_degraded_project_when_status_cannot_be_loaded
    with_tmp_dir do |root|
      project = status_project(root)
      write_task(project, "1-inbox", "selected-task")
      command = Hive::Commands::Status.new
      command.define_singleton_method(:prepare_project) { |*, **| raise IOError, "project unavailable" }

      payload = nil
      _output, warning = capture_io do
        payload = target_payload(command, project, "selected-task", "1-inbox")
      end

      assert_equal "project_load_failed", payload.fetch("error")
      assert_empty payload.fetch("tasks")
      assert_includes warning, "project \"demo\" payload failed"
    end
  end

  private

  def status_project(root, name: "demo")
    { "name" => name, "path" => root, "hive_state_path" => File.join(root, ".hive-state") }
  end

  def write_task(project, stage, slug, id: 1, depends_on: nil, completed_at: nil)
    folder = File.join(project.fetch("hive_state_path"), "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    state_file = stage == "1-inbox" ? "idea.md" : "task.md"
    marker = stage == "9-done" ? "COMPLETE" : "WAITING"
    File.write(File.join(folder, state_file), "<!-- #{marker} -->\n")
    Hive::TaskMeta.write(
      folder, id: id, slug: slug, display_name: nil,
      depends_on: depends_on, completed_at: completed_at
    )
    folder
  end

  def target_payload(command, project, slug, stage, projects: [ project ], **options)
    with_replaced_singleton_method(Hive::Config, :registered_projects, -> { projects }) do
      command.task_target_payload(project, slug: slug, stage: stage, **options)
    end
  end

  def observe_task_reads
    metadata_reads = []
    journal_reads = []
    original_meta = Hive::TaskMeta.method(:read_for_admission)
    original_reader = Hive::TaskProjection::Reader.method(:new)
    read_meta = lambda do |folder|
      metadata_reads << folder.to_s
      original_meta.call(folder)
    end
    new_reader = lambda do |**options|
      journal_reads << options.fetch(:task_folder).to_s
      original_reader.call(**options)
    end
    with_replaced_singleton_method(Hive::TaskMeta, :read_for_admission, read_meta) do
      with_replaced_singleton_method(Hive::TaskProjection::Reader, :new, new_reader) do
        yield metadata_reads, journal_reads
      end
    end
  end
end
