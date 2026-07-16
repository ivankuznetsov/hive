require "test_helper"
require "hive/dependency_snapshot"
require "hive/task_meta"

# Direct coverage for the disk→resolver seam. Before this, `tasks`,
# `current_task`, `depends_on`, and `stacked_base` were exercised only
# indirectly through execute/open_pr happy-path stubs, so a regression in
# the glue (folder scanning, the meta-slug fallback, the warn-on-collapse
# path) would have slipped past every resolver-level test.
class DependencySnapshotTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(:slug, :id, :depends_on, :folder, :project_root, keyword_init: true)

  def test_tasks_reads_every_stage_folder_into_resolver_shape
    with_tmp_dir do |root|
      write_task_meta(root, "4-execute", "alpha-260618-aaaa", id: 1)
      write_task_meta(root, "8-finalize", "beta-260618-bbbb", id: 2)

      tasks = Hive::DependencySnapshot.tasks(root)
      alpha = tasks.find { |t| t[:slug] == "alpha-260618-aaaa" }
      beta = tasks.find { |t| t[:slug] == "beta-260618-bbbb" }

      refute_nil alpha, "every stage folder must surface in the snapshot"
      assert_equal 1, alpha[:id]
      assert_equal "4-execute", alpha[:stage]
      assert_equal 4, alpha[:stage_index]
      assert_equal 8, beta[:stage_index]
    end
  end

  def test_tasks_skips_non_directory_entries
    with_tmp_dir do |root|
      stage_dir = File.join(root, ".hive-state", "stages", "4-execute")
      FileUtils.mkdir_p(stage_dir)
      FileUtils.touch(File.join(stage_dir, ".DS_Store"))
      write_task_meta(root, "4-execute", "real-task", id: 1)

      slugs = Hive::DependencySnapshot.tasks(root).map { |t| t[:slug] }
      assert_includes slugs, "real-task"
      refute_includes slugs, ".DS_Store", "stray files under a stage dir must be skipped"
    end
  end

  def test_tasks_falls_back_to_folder_name_when_meta_slug_absent
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, ".hive-state", "stages", "4-execute", "no-meta-task"))

      row = Hive::DependencySnapshot.tasks(root).find { |t| t[:slug] == "no-meta-task" }
      refute_nil row, "folder name is the fallback slug when meta.yml is absent"
      assert_nil row[:id]
    end
  end

  def test_current_task_and_depends_on_project_task_fields
    task = FakeTask.new(slug: "dependent", id: 7, depends_on: "base", folder: "/x", project_root: "/x")

    assert_equal({ slug: "dependent", id: 7 }, Hive::DependencySnapshot.current_task(task))
    assert_equal "base", Hive::DependencySnapshot.depends_on(task)
  end

  def test_stacked_base_returns_prerequisite_slug_when_resolvable
    with_tmp_dir do |root|
      write_task_meta(root, "8-finalize", "base-task", id: 1)
      task = FakeTask.new(slug: "dependent", id: 2, depends_on: "base-task",
                          folder: execute_folder(root, "dependent"), project_root: root)

      assert_equal "base-task", Hive::DependencySnapshot.stacked_base(task, "main")
    end
  end

  def test_stacked_base_returns_nil_without_dependency
    with_tmp_dir do |root|
      task = FakeTask.new(slug: "solo", id: 1, depends_on: nil,
                          folder: execute_folder(root, "solo"), project_root: root)

      assert_nil Hive::DependencySnapshot.stacked_base(task, "main")
    end
  end

  def test_stacked_base_warns_and_returns_nil_for_unresolvable_dependency
    with_tmp_dir do |root|
      task = FakeTask.new(slug: "dependent", id: 2, depends_on: "ghost-task",
                          folder: execute_folder(root, "dependent"), project_root: root)

      result = nil
      _out, err = capture_io do
        result = Hive::DependencySnapshot.stacked_base(task, "main")
      end

      assert_nil result, "an unresolvable dependency collapses to the default (nil base_override)"
      assert_match(/did not resolve to a stacked base/, err,
                   "a silently collapsed stack request must leave a stderr breadcrumb")
    end
  end

  def test_stacked_base_does_not_treat_cross_project_dependency_as_branch_base
    with_tmp_dir do |root|
      task = FakeTask.new(slug: "dependent", id: 2, depends_on: "other:base-task",
                          folder: execute_folder(root, "dependent"), project_root: root)

      result = nil
      _out, err = capture_io { result = Hive::DependencySnapshot.stacked_base(task, "main") }

      assert_nil result
      assert_match(/scheduling-only/, err)
    end
  end

  def test_admission_context_preserves_corrupt_metadata_as_an_error
    with_tmp_dir do |root|
      slug = "corrupt-task"
      folder = File.join(root, ".hive-state", "stages", "4-execute", slug)
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"), "depends_on: [unterminated\n")

      context = Hive::DependencySnapshot.admission_context([
        { "name" => File.basename(root), "path" => root, "repository_identity" => nil }
      ])
      verdict = context.verdict(project: File.basename(root), slug: slug)

      assert verdict.error?
      assert_equal "dependency_metadata_unreadable", verdict.admission_error.reason_code
    end
  end

  def test_active_admission_context_preserves_cached_archived_error
    with_tmp_dir do |root|
      dependent = write_task_meta(root, "4-execute", "dependent-task", id: 2)
      Hive::TaskMeta.write(
        dependent,
        id: 2,
        slug: "dependent-task",
        display_name: nil,
        depends_on: "archived-task"
      )
      project = { "name" => File.basename(root), "path" => root, "repository_identity" => nil }
      cached_error = {
        "reason_code" => "dependency_metadata_invalid",
        "offending_ref" => "#{File.basename(root)}:archived-task",
        "safe_correction" => "Repair the archived task metadata."
      }

      context = Hive::DependencySnapshot.admission_context(
        [ project ],
        exclude_archived: true,
        extra_dependency_tasks: {
          root => [
            {
              "slug" => "archived-task",
              "id" => 1,
              "stage" => "9-done",
              "admission_error" => cached_error
            }
          ]
        }
      )
      verdict = context.verdict(project: File.basename(root), slug: "dependent-task")

      assert verdict.error?
      assert_equal "dependency_metadata_invalid", verdict.admission_error.reason_code
      assert_equal "Repair the archived task metadata.", verdict.admission_error.safe_correction
    end
  end

  private

  def write_task_meta(root, stage, slug, id:)
    folder = File.join(root, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    Hive::TaskMeta.write(folder, id: id, slug: slug, display_name: nil)
    folder
  end

  def execute_folder(root, slug)
    File.join(root, ".hive-state", "stages", "4-execute", slug)
  end
end
