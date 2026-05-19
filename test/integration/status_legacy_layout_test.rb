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
        # Seed in non-alphabetical creation order so the sort_by in
        # `detect_legacy_stage_dirs` has something to sort. The
        # output must be alphabetical by `stage_dir`.
        seed_legacy_task(dir, "6-pr", "stuck-on-old-layout-260516-aaaa")
        seed_legacy_task(dir, "5-review", "also-stuck-260516-bbbb")
        seed_legacy_task(dir, "5-review", "second-old-260516-cccc")

        payload = Hive::Commands::Status.new.json_payload(Hive::Config.registered_projects)
        project = payload.fetch("projects").first

        legacy = project["legacy_stage_dirs"]
        refute_nil legacy, "project payload must expose a legacy_stage_dirs field"
        by_dir = legacy.to_h { |entry| [ entry["stage_dir"], entry["task_count"] ] }
        assert_equal 1, by_dir["6-pr"], "6-pr should report its one hidden task"
        assert_equal 2, by_dir["5-review"], "5-review should report both hidden tasks"
        assert_equal legacy.map { |e| e["stage_dir"] }.sort,
                     legacy.map { |e| e["stage_dir"] },
                     "legacy_stage_dirs must be sorted alphabetically by stage_dir"
        # Machine-readable parity of the text "run `hive migrate`"
        # recovery hint. Agents reading the JSON envelope must get a
        # ready-to-execute command string whenever legacy_stage_dirs is
        # non-empty; see issue #94.
        assert_equal "hive migrate", project["legacy_migrate_command"],
                     "legacy_migrate_command must surface the recovery command when " \
                     "legacy_stage_dirs is non-empty"
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
        assert_match(/1 task hidden in legacy stage dirs/, out,
                     "singular form of the warning must be used for one hidden task")
      end
    end
  end

  def test_text_output_pluralises_warning_when_multiple_hidden
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        seed_legacy_task(dir, "6-pr", "stuck-one-260516-aaaa")
        seed_legacy_task(dir, "6-pr", "stuck-two-260516-bbbb")

        out, _err = capture_io { Hive::Commands::Status.new.call }
        assert_match(/2 tasks hidden in legacy stage dirs/, out,
                     "plural form of the warning must be used for multiple hidden tasks")
      end
    end
  end

  def test_legacy_stage_dirs_field_is_empty_array_when_layout_is_clean
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }

        payload = Hive::Commands::Status.new.json_payload(Hive::Config.registered_projects)
        project = payload.fetch("projects").first
        assert_equal [], project["legacy_stage_dirs"],
                     "clean projects must emit legacy_stage_dirs as an empty array"
        # The diagnostic-field-always-present convention: `legacy_migrate_command`
        # must be `null` (not absent) when the project is clean, so agent
        # consumers can branch on the field without a `key?` probe. Issue #94.
        assert project.key?("legacy_migrate_command"),
               "legacy_migrate_command key must always be present"
        assert_nil project["legacy_migrate_command"],
                   "clean projects must emit legacy_migrate_command as nil"
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
        assert_equal [], project["legacy_stage_dirs"],
                     "an empty legacy stage dir must produce an empty legacy_stage_dirs array, not a false positive"
      end
    end
  end

  # `task_count` must only include slug-shaped children — stray sibling
  # directories with non-slug names (a `.logs` dot-folder, an
  # underscore-named scratch dir) must not inflate the number,
  # otherwise the operator sees a count that doesn't match what
  # `hive migrate` would actually move. (Note: bare `logs` happens to
  # match the slug regex — the test uses `.logs` and `scratch_dir` so
  # the gate it pins is `Hive::Stages.task_slug?`, not "any name with
  # letters in it".)
  def test_task_count_excludes_non_slug_subdirs
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        seed_legacy_task(dir, "6-pr", "real-task-260516-aaaa")
        # Dot-prefixed name fails the leading `[a-z]` anchor.
        FileUtils.mkdir_p(File.join(dir, ".hive-state", "stages", "6-pr", ".logs"))
        # Underscore is outside the `[a-z0-9-]` charset.
        FileUtils.mkdir_p(File.join(dir, ".hive-state", "stages", "6-pr", "scratch_dir"))

        payload = Hive::Commands::Status.new.json_payload(Hive::Config.registered_projects)
        project = payload.fetch("projects").first
        legacy = project["legacy_stage_dirs"]
        by_dir = legacy.to_h { |entry| [ entry["stage_dir"], entry["task_count"] ] }
        assert_equal 1, by_dir["6-pr"],
                     "non-slug subdirs (.logs, scratch_dir) must not inflate task_count"
      end
    end
  end

  def test_text_warns_under_project_header_when_rows_and_legacy_both_exist
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        # Canonical task in 4-execute (visible) AND legacy task in 6-pr (hidden).
        seed_legacy_task(dir, "4-execute", "real-260516-aaaa")
        seed_legacy_task(dir, "6-pr", "stuck-260516-bbbb")

        out, _err = capture_io { Hive::Commands::Status.new.call }
        assert_match(/hidden in legacy stage dirs/, out,
                     "warning must appear even when canonical rows are also present")
        assert_includes out, "real-260516-aaaa",
                        "canonical task row must still render under its action label"
        refute_includes out, "no active tasks",
                        "the no-active-tasks placeholder must not appear when rows are present"
      end
    end
  end

  # A stray file (not a directory) directly under `stages/` must not
  # raise — the detector should ignore non-directories.
  def test_non_directory_in_stages_root_is_ignored
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        File.write(File.join(dir, ".hive-state", "stages", ".DS_Store"), "")

        payload = nil
        # Must not crash on the non-directory child.
        payload = Hive::Commands::Status.new.json_payload(Hive::Config.registered_projects)
        project = payload.fetch("projects").first
        assert_equal [], project["legacy_stage_dirs"],
                     "stray non-directory entries in stages/ must be silently ignored"
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
