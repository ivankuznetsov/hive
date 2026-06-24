require "test_helper"
require "json"
require "open3"
require "hive/config"
require "hive/git_ops"
require "hive/task"
require "hive/task_meta"

class DropCommandIntegrationTest < Minitest::Test
  include HiveTestHelper

  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)

  def with_cli_project
    with_tmp_global_config do |home|
      with_tmp_git_repo do |dir|
        ops = Hive::GitOps.new(dir)
        ops.hive_state_init
        Hive::Config.register_project(name: File.basename(dir), path: dir)
        yield(home, dir, File.basename(dir))
      end
    end
  end

  def with_two_cli_projects
    with_tmp_global_config do |home|
      with_tmp_git_repo do |dir1|
        with_tmp_git_repo do |dir2|
          Hive::GitOps.new(dir1).hive_state_init
          Hive::GitOps.new(dir2).hive_state_init
          project1 = "project-one"
          project2 = "project-two"
          Hive::Config.register_project(name: project1, path: dir1)
          Hive::Config.register_project(name: project2, path: dir2)
          yield(home, dir1, project1, dir2, project2)
        end
      end
    end
  end

  def create_task(dir, stage, slug)
    folder = File.join(dir, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    state_name = Hive::Task::STATE_FILES.fetch(stage.split("-", 2).last)
    File.write(File.join(folder, state_name), "# #{slug}\n<!-- WAITING -->\n")
    folder
  end

  def create_task_with_id(dir, stage, slug, id)
    folder = create_task(dir, stage, slug)
    Hive::TaskMeta.write(folder, id: id, slug: slug, display_name: nil)
    folder
  end

  def run_hive(home, *args)
    Open3.capture3({ "HIVE_HOME" => home }, HIVE_BIN, *args)
  end

  def test_bin_hive_drop_removes_multi_stage_slug_and_emits_json
    with_cli_project do |home, dir, project|
      slug = "cli-drop-260522-aaaa"
      folder2 = create_task(dir, "2-brainstorm", slug)
      folder3 = create_task(dir, "3-plan", slug)

      out, err, status = run_hive(home, "drop", slug, "--project", project, "--json")

      assert status.success?, err
      payload = JSON.parse(out)
      assert_equal "hive-drop", payload["schema"]
      assert_equal [ "2-brainstorm", "3-plan" ], payload["from_stages"]
      refute File.directory?(folder2)
      refute File.directory?(folder3)
    end
  end

  def test_bin_hive_drop_unknown_slug_exits_usage_with_error_envelope
    with_cli_project do |home, _dir, project|
      out, _err, status = run_hive(home, "drop", "missing-260522-aaaa", "--project", project, "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "invalid_task_path", payload["error_kind"]
    end
  end

  def test_bin_hive_drop_archived_slug_exits_usage
    with_cli_project do |home, dir, project|
      slug = "done-260522-aaaa"
      folder = create_task(dir, "9-done", slug)

      out, _err, status = run_hive(home, "drop", slug, "--project", project, "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      assert_equal "already_archived", JSON.parse(out)["error_kind"]
      assert File.directory?(folder)
    end
  end

  def test_bin_hive_drop_numeric_id_removes_task_and_emits_json
    with_cli_project do |home, dir, project|
      slug = "id-drop-260622-aaaa"
      folder = create_task_with_id(dir, "2-brainstorm", slug, 7448)
      assert File.directory?(folder), "task folder must exist before drop"

      out, err, status = run_hive(home, "drop", "7448", "--project", project, "--json")

      assert status.success?, err
      payload = JSON.parse(out)
      assert_equal "hive-drop", payload["schema"]
      assert_equal slug, payload["slug"]
      assert_equal project, payload["project"]
      assert_equal [ "2-brainstorm" ], payload["from_stages"]
      refute File.directory?(folder)
    end
  end

  def test_bin_hive_drop_unknown_numeric_id_exits_usage_with_error_envelope
    with_cli_project do |home, _dir, project|
      out, _err, status = run_hive(home, "drop", "9999", "--project", project, "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "invalid_task_path", payload["error_kind"]
      assert_includes payload["message"], "no task folder for id 9999"
    end
  end

  # Leading-zero numeric inputs are parsed with Ruby's Integer(), which reads a
  # leading zero as octal. `010` therefore parses to decimal 8 (octal 010), so
  # it does NOT resolve to the decimal id 10. Lock the current behavior: the
  # id-10 task is preserved and drop refuses with invalid_task_path. (If the
  # parse is ever switched to base-10, this test will flag the contract change.)
  def test_bin_hive_drop_leading_zero_id_010_does_not_resolve_to_decimal_id_10
    with_cli_project do |home, dir, project|
      slug = "leading-zero-010-260622-aaaa"
      folder = create_task_with_id(dir, "2-brainstorm", slug, 10)

      out, _err, status = run_hive(home, "drop", "010", "--project", project, "--json")

      refute status.success?, "drop 010 must not succeed against a decimal id-10 task"
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      assert_equal "invalid_task_path", JSON.parse(out)["error_kind"]
      assert File.directory?(folder), "id-10 task folder must survive `drop 010`"
    end
  end

  # `08` is not a valid octal literal, so Integer("08") raises before any
  # lookup. Lock the current behavior: drop fails with an internal-error
  # envelope (exit 70) and drops nothing, rather than treating `08` as
  # decimal id 8.
  def test_bin_hive_drop_leading_zero_id_08_errors_and_preserves_task
    with_cli_project do |home, dir, project|
      slug = "leading-zero-08-260622-aaaa"
      folder = create_task_with_id(dir, "2-brainstorm", slug, 8)

      out, _err, status = run_hive(home, "drop", "08", "--project", project, "--json")

      refute status.success?, "drop 08 must not succeed against a decimal id-8 task"
      assert_equal Hive::ExitCodes::SOFTWARE, status.exitstatus
      assert_equal "internal", JSON.parse(out)["error_kind"]
      assert File.directory?(folder), "id-8 task folder must survive `drop 08`"
    end
  end

  # `drop <id> --from STAGE` forwards the stage as a TaskResolver filter. A
  # matching stage resolves and drops; a mismatched (but otherwise valid) stage
  # narrows the id scan to a folder that doesn't hold the id, so it resolves to
  # nothing and refuses with invalid_task_path (NOT wrong_stage — that exit-4
  # contract is slug-only; see wiki/commands/drop.md).
  def test_bin_hive_drop_id_with_from_stage_mismatch_refuses_then_match_drops
    with_cli_project do |home, dir, project|
      slug = "id-from-260622-aaaa"
      folder = create_task_with_id(dir, "2-brainstorm", slug, 7449)

      out, _err, status = run_hive(home, "drop", "7449", "--project", project, "--from", "3-plan", "--json")

      refute status.success?, "id drop with a mismatched --from must not succeed"
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      assert_equal "invalid_task_path", JSON.parse(out)["error_kind"]
      assert File.directory?(folder), "task folder must survive a mismatched --from"

      out, err, status = run_hive(home, "drop", "7449", "--project", project, "--from", "2-brainstorm", "--json")

      assert status.success?, err
      payload = JSON.parse(out)
      assert_equal slug, payload["slug"]
      assert_equal [ "2-brainstorm" ], payload["from_stages"]
      refute File.directory?(folder), "task folder must be removed when --from matches"

      # A SHORT --from ref (`brainstorm`) must canonicalize to the same
      # 2-brainstorm dir and route through the resolver stage_filter, so a fresh
      # id drops by short ref exactly as the long-form ref above did.
      slug_short = "id-from-short-260622-aaaa"
      folder_short = create_task_with_id(dir, "2-brainstorm", slug_short, 7452)

      out, err, status = run_hive(home, "drop", "7452", "--project", project, "--from", "brainstorm", "--json")

      assert status.success?, err
      payload = JSON.parse(out)
      assert_equal slug_short, payload["slug"]
      assert_equal [ "2-brainstorm" ], payload["from_stages"]
      refute File.directory?(folder_short), "task folder must be removed when a short --from matches"
    end
  end

  # The id path reaches archived tasks through its own empty-active fallback
  # (drop.rb resolve_path_context), a distinct branch from the slug path's
  # guard. Dropping a 9-done task by id must still refuse with already_archived
  # and leave the folder intact — never hard-delete a completed task by id.
  def test_bin_hive_drop_archived_numeric_id_exits_usage_and_preserves_task
    with_cli_project do |home, dir, project|
      slug = "id-done-260622-aaaa"
      folder = create_task_with_id(dir, "9-done", slug, 7450)

      out, _err, status = run_hive(home, "drop", "7450", "--project", project, "--json")

      refute status.success?, "dropping an archived task by id must not succeed"
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      assert_equal "already_archived", JSON.parse(out)["error_kind"]
      assert File.directory?(folder), "archived task folder must survive drop by id"
    end
  end

  # Same id in two stages of ONE project routes through id_ambiguity_message,
  # which — unlike the slug-side ambiguity_message — emits one fixed "task id <n>
  # is duplicated" string regardless of project count. Drop must refuse with
  # ambiguous_slug and leave both folders intact.
  def test_bin_hive_drop_duplicate_numeric_id_within_one_project_is_ambiguous
    with_cli_project do |home, dir, project|
      slug1 = "dup-one-stage-260622-aaaa"
      slug2 = "dup-two-stage-260622-aaaa"
      folder1 = create_task_with_id(dir, "2-brainstorm", slug1, 7451)
      folder2 = create_task_with_id(dir, "3-plan", slug2, 7451)

      out, _err, status = run_hive(home, "drop", "7451", "--project", project, "--json")

      refute status.success?, "a duplicate id within one project must not drop"
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "ambiguous_slug", payload["error_kind"]
      assert_includes payload["message"], "task id 7451 is duplicated"
      assert File.directory?(folder1), "first duplicate folder must survive"
      assert File.directory?(folder2), "second duplicate folder must survive"
    end
  end

  def test_bin_hive_drop_duplicate_numeric_id_requires_project_and_then_drops_selected_project
    with_two_cli_projects do |home, dir1, project1, dir2, _project2|
      slug1 = "duplicate-id-one-260622-aaaa"
      slug2 = "duplicate-id-two-260622-aaaa"
      folder1 = create_task_with_id(dir1, "2-brainstorm", slug1, 7448)
      folder2 = create_task_with_id(dir2, "2-brainstorm", slug2, 7448)

      out, _err, status = run_hive(home, "drop", "7448", "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "ambiguous_slug", payload["error_kind"]
      assert_includes payload["message"], "task id 7448 is duplicated"
      assert File.directory?(folder1)
      assert File.directory?(folder2)

      out, err, status = run_hive(home, "drop", "7448", "--project", project1, "--json")

      assert status.success?, err
      payload = JSON.parse(out)
      assert_equal slug1, payload["slug"]
      assert_equal project1, payload["project"]
      refute File.directory?(folder1)
      assert File.directory?(folder2)
    end
  end
end
