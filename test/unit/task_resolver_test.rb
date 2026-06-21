require "test_helper"
require "hive/task_resolver"
require "hive/task_meta"

class TaskResolverTest < Minitest::Test
  include HiveTestHelper

  def test_path_target_rejects_mismatched_stage_filter
    with_tmp_global_config do |home|
      project_root = File.join(home, "project-a")
      folder = File.join(project_root, ".hive-state", "stages", "3-plan", "demo-task")
      FileUtils.mkdir_p(folder)
      write_registered_project(home, "project-a", project_root)

      error = assert_raises(Hive::InvalidTaskPath) do
        Hive::TaskResolver.new(folder, stage_filter: "brainstorm").resolve
      end

      assert_includes error.message, "TARGET is at 3-plan"
      assert_includes error.message, "--stage/--from says 2-brainstorm"
    end
  end

  def test_numeric_target_resolves_task_by_meta_id
    with_tmp_global_config do |home|
      project_root = File.join(home, "project-a")
      folder = task_folder(project_root, "2-brainstorm", "demo-task")
      Hive::TaskMeta.write(folder, id: 42, slug: "demo-task", display_name: "Demo Task")
      write_registered_project(home, "project-a", project_root)

      assert_equal folder, Hive::TaskResolver.new("42").resolve.folder
      assert_equal folder, Hive::TaskResolver.new("demo-task").resolve.folder
    end
  end

  def test_numeric_target_respects_stage_filter
    with_tmp_global_config do |home|
      project_root = File.join(home, "project-a")
      folder = task_folder(project_root, "2-brainstorm", "demo-task")
      Hive::TaskMeta.write(folder, id: 42, slug: "demo-task", display_name: nil)
      write_registered_project(home, "project-a", project_root)

      assert_equal folder, Hive::TaskResolver.new("42", stage_filter: "brainstorm").resolve.folder
      error = assert_raises(Hive::InvalidTaskPath) do
        Hive::TaskResolver.new("42", stage_filter: "plan").resolve
      end
      assert_includes error.message, "no task folder for id 42"
    end
  end

  def test_slug_target_resolves_registered_generic_stage_dirs
    descriptor = dispatch_workflow

    with_registered_workflow(descriptor) do
      with_tmp_global_config do |home|
        project_root = File.join(home, "project-a")
        folder = task_folder(project_root, "2-gather", "generic-task")
        Hive::TaskMeta.write(folder, id: 43, slug: "generic-task", display_name: nil, workflow: descriptor.id.to_s)
        write_registered_project(home, "project-a", project_root)

        assert_equal folder, Hive::TaskResolver.new("generic-task").resolve.folder
        assert_equal folder, Hive::TaskResolver.new("generic-task", stage_filter: "gather").resolve.folder
      end
    end
  end

  # U9-3 tolerance: a stage filter that resolves in NO scanned project's
  # workflows is skipped per-project rather than aborting the cross-project scan
  # (the case it protects is a filter valid in a DIFFERENT project than the one
  # scanned first — see the user-workflow e2e for the positive path). A
  # genuinely unknown filter therefore degrades to "no task folder" instead of
  # raising "unknown stage" mid-scan.
  def test_unknown_stage_filter_is_tolerated_and_degrades_to_not_found
    descriptor = dispatch_workflow

    with_registered_workflow(descriptor) do
      error = assert_raises(Hive::InvalidTaskPath) do
        Hive::TaskResolver.new("generic-task", stage_filter: "nope").resolve
      end

      assert_includes error.message, "no task folder for slug 'generic-task'"
      assert_includes error.message, "stage 'nope'"
    end
  end

  def test_numeric_target_with_no_match_raises_id_specific_error
    with_tmp_global_config do |home|
      project_root = File.join(home, "project-a")
      task_folder(project_root, "2-brainstorm", "demo-task")
      write_registered_project(home, "project-a", project_root)

      error = assert_raises(Hive::InvalidTaskPath) { Hive::TaskResolver.new("42").resolve }
      assert_includes error.message, "no task folder for id 42"
    end
  end

  def test_duplicate_numeric_id_is_ambiguous
    with_tmp_global_config do |home|
      project_root = File.join(home, "project-a")
      folder_a = task_folder(project_root, "2-brainstorm", "demo-task")
      folder_b = task_folder(project_root, "3-plan", "other-task")
      Hive::TaskMeta.write(folder_a, id: 42, slug: "demo-task", display_name: nil)
      Hive::TaskMeta.write(folder_b, id: 42, slug: "other-task", display_name: nil)
      write_registered_project(home, "project-a", project_root)

      error = assert_raises(Hive::AmbiguousSlug) { Hive::TaskResolver.new("42").resolve }
      assert_includes error.message, "task id 42 is duplicated"
      assert_equal 2, error.candidates.size
    end
  end

  private

  def task_folder(project_root, stage, slug)
    folder = File.join(project_root, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    File.realpath(folder)
  end

  def write_registered_project(home, name, project_root)
    File.write(
      File.join(home, "config.yml"),
      {
        "registered_projects" => [
          {
            "name" => name,
            "path" => project_root,
            "hive_state_path" => File.join(project_root, ".hive-state")
          }
        ]
      }.to_yaml
    )
  end
end
