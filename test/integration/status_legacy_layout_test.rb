require "test_helper"
require "hive/commands/init"
require "hive/commands/status"

# Reproduces the regression where a stage rename in `Hive::Stages::DIRS`
# silently makes pre-rename tasks invisible to `hive status` and the TUI.
# `Status#collect_rows` walks only canonical stages, so a task left in a
# legacy stage directory (e.g. `6-pr/` from the pre-PR-first layout)
# becomes unreachable from every operator surface until the operator
# happens to run `hive migrate`.
#
# These tests assert that Status surfaces the legacy directories in both
# JSON and text output so the operator gets a visible nudge instead of a
# silent truncation.
class StatusLegacyLayoutTest < Minitest::Test
  include HiveTestHelper

  def test_json_payload_surfaces_legacy_stage_dirs_with_task_counts
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        seed_legacy_task(dir, "6-pr", "stuck-on-old-layout-260516-aaaa")
        seed_legacy_task(dir, "5-review", "also-stuck-260516-bbbb")
        seed_legacy_task(dir, "5-review", "second-old-260516-cccc")

        payload = Hive::Commands::Status.new.json_payload(Hive::Config.registered_projects)
        project = payload.fetch("projects").first

        legacy = project["legacy_stage_dirs"]
        refute_nil legacy, "project payload must expose a legacy_stage_dirs field"
        by_dir = legacy.to_h { |entry| [ entry["dir"], entry["task_count"] ] }
        assert_equal 1, by_dir["6-pr"], "6-pr should report its one hidden task"
        assert_equal 2, by_dir["5-review"], "5-review should report both hidden tasks"
      end
    end
  end

  def test_text_output_warns_when_legacy_stage_dirs_exist
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        seed_legacy_task(dir, "6-pr", "stuck-on-old-layout-260516-aaaa")

        out, _err = capture_io { Hive::Commands::Status.new.call }
        assert_includes out, "6-pr", "warning must name the legacy directory"
        assert_includes out, "hive migrate", "warning must point at the fix command"
      end
    end
  end

  def test_legacy_stage_dirs_field_absent_when_layout_is_clean
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }

        payload = Hive::Commands::Status.new.json_payload(Hive::Config.registered_projects)
        project = payload.fetch("projects").first
        refute project.key?("legacy_stage_dirs"),
               "clean projects must not carry the legacy_stage_dirs field"
      end
    end
  end

  def test_empty_legacy_stage_dir_is_not_reported
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        # Stage dir exists but holds no task subfolders — `hive init` may
        # leave behind a `.gitkeep` from a prior layout. Only stage dirs
        # that actually shadow live state should trigger the warning.
        FileUtils.mkdir_p(File.join(dir, ".hive-state", "stages", "6-pr"))
        File.write(File.join(dir, ".hive-state", "stages", "6-pr", ".gitkeep"), "")

        payload = Hive::Commands::Status.new.json_payload(Hive::Config.registered_projects)
        project = payload.fetch("projects").first
        refute project.key?("legacy_stage_dirs"),
               "an empty legacy stage dir must not raise a false positive"
      end
    end
  end

  private

  def seed_legacy_task(project_dir, stage, slug)
    folder = File.join(project_dir, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "task.md"), "x\n")
  end
end
