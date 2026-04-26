require "test_helper"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/status"

class StatusTest < Minitest::Test
  include HiveTestHelper

  def test_no_projects_message
    with_tmp_global_config do
      out, _err = capture_io { Hive::Commands::Status.new.call }
      assert_includes out, "no projects registered"
    end
  end

  def test_groups_tasks_by_action_and_suggests_commands
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        capture_io do
          Hive::Commands::New.new(project, "task one").call
          Hive::Commands::New.new(project, "task two").call
        end

        # Move one to brainstorm, mark its state
        inboxes = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")]
        assert_equal 2, inboxes.size
        moved = File.join(dir, ".hive-state", "stages", "2-brainstorm", File.basename(inboxes.first))
        FileUtils.mkdir_p(File.dirname(moved))
        FileUtils.mv(inboxes.first, moved)
        File.write(File.join(moved, "brainstorm.md"), "## Round 1\n<!-- WAITING -->\n")

        out, _err = capture_io { Hive::Commands::Status.new.call }
        assert_includes out, project
        assert_includes out, "Ready to brainstorm"
        assert_includes out, "Needs your input"
        assert_includes out, "hive brainstorm"
        assert_includes out, "⏸"
      end
    end
  end

  def test_no_active_tasks_message
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        out, _err = capture_io { Hive::Commands::Status.new.call }
        assert_includes out, File.basename(dir)
        assert_includes out, "no active tasks"
      end
    end
  end

  def test_stale_agent_working_marker_shows_warning
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "stale-260424-aaaa"
        folder = File.join(dir, ".hive-state", "stages", "4-execute", slug)
        FileUtils.mkdir_p(folder)
        File.write(File.join(folder, "task.md"), "<!-- AGENT_WORKING pid=99999999 claude_pid=99999998 -->\n")
        out, _err = capture_io { Hive::Commands::Status.new.call }
        assert_includes out, "⚠"
        assert_includes out, "stale lock"
      end
    end
  end

  def test_review_markers_render_status_icons
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        markers = {
          "review-waiting-260426-aaaa" => "<!-- REVIEW_WAITING escalations=2 pass=1 -->\n",
          "review-ci-stale-260426-aaab" => "<!-- REVIEW_CI_STALE attempts=3 -->\n",
          "review-complete-260426-aaac" => "<!-- REVIEW_COMPLETE pass=1 browser=skipped -->\n"
        }
        markers.each do |slug, marker|
          folder = File.join(dir, ".hive-state", "stages", "5-review", slug)
          FileUtils.mkdir_p(folder)
          File.write(File.join(folder, "task.md"), marker)
        end

        out, _err = capture_io { Hive::Commands::Status.new.call }
        assert_includes out, "5-review/"
        assert_includes out, "⏸ review-waiting"
        assert_includes out, "⚠ review-ci-stale"
        assert_includes out, "✓ review-complete"
      end
    end
  end
end
