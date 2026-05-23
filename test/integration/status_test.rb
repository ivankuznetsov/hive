require "test_helper"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/status"
require "hive/events"

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
          folder = File.join(dir, ".hive-state", "stages", "6-review", slug)
          FileUtils.mkdir_p(folder)
          File.write(File.join(folder, "task.md"), marker)
        end

        out, _err = capture_io { Hive::Commands::Status.new.call }
        assert_includes out, "review-waiting"
        assert_includes out, "review-ci-stale"
        assert_includes out, "review-complete"
      end
    end
  end

  # Direct assertion: the status JSON payload never references the
  # events.jsonl file or any message body written there. Replaces an
  # earlier "before/after equality with Time.now frozen" formulation,
  # whose only purpose was to neutralise volatile timestamps so the two
  # snapshots could be compared byte-for-byte. The fixed-time helper
  # globally aliased Time.now, leaving a window where a parallel test
  # could observe the fake clock; refuting on the JSON payload directly
  # tests the same contract without that monkey-patch.
  def test_status_json_ignores_events_artifacts
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "events-ignored-260522-aaaa"
        folder = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(folder)
        state_file = File.join(folder, "brainstorm.md")
        File.write(state_file, "## Round 1\n<!-- WAITING -->\n")
        sentinel = "events-sentinel-must-not-appear-in-status"
        Hive::Events.emit(task_folder: folder, slug: slug, stage: "2-brainstorm",
                          event_type: :stage_enter, message: sentinel)
        assert File.exist?(File.join(folder, "events.jsonl")), "emit must have produced events.jsonl on disk"
        assert File.exist?(File.join(folder, "status.md")), "emit must have produced status.md on disk"

        out, = capture_io { Hive::Commands::Status.new(json: true).call }
        refute_match(/events\.jsonl/, out, "status --json must not reference events.jsonl")
        refute_match(/#{Regexp.escape(sentinel)}/, out, "status --json must not leak event messages")
        refute_match(/"status\.md"/, out, "status --json must not reference status.md")
      end
    end
  end
end
