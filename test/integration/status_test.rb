require "test_helper"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/status"
require "hive/events"
require "hive/task_meta"

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
        assert_includes out, "#1"
        assert_includes out, "#2"
        assert_includes out, "⏸"
      end
    end
  end

  def test_status_json_includes_slug_id_and_display_name
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "named status row").call }
        folder = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "named-status-row-*")].first
        Hive::TaskMeta.update_display_name(folder, "Named Status Row")

        out, = capture_io { Hive::Commands::Status.new(json: true).call }
        row = JSON.parse(out).dig("projects", 0, "tasks", 0)

        assert_equal File.basename(folder), row["slug"]
        assert_equal 1, row["id"]
        assert_equal "Named Status Row", row["display_name"]
      end
    end
  end

  def test_status_json_renders_content_fixture_stage_set
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          capture_io { Hive::Commands::Init.new(dir, workflow: "content_fixture").call }
          project = File.basename(dir)
          capture_io { Hive::Commands::New.new(project, "content status").call }
          slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "content-status-*")].first)
          move_content_task(dir, slug, "1-inbox", "2-research", "research.md", "<!-- COMPLETE -->\n")
          seed_content_task(dir, "3-draft", "draft-row-260620-abcd", "draft.md", "<!-- COMPLETE -->\n")

          out, = capture_io { Hive::Commands::Status.new(json: true).call }
          rows = JSON.parse(out).dig("projects", 0, "tasks")

          assert_equal %w[2-research 3-draft], rows.map { |row| row.fetch("stage") }.sort
          assert(rows.all? { |row| row.fetch("workflow") == "content_fixture" })
          refute(rows.any? { |row| row.fetch("stage") == "2-brainstorm" || row.fetch("stage") == "5-open-pr" })
        end
      end
    end
  end

  def test_status_json_renders_mixed_coding_and_content_tasks
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          capture_io { Hive::Commands::Init.new(dir).call }
          project = File.basename(dir)
          capture_io { Hive::Commands::New.new(project, "coding status row").call }
          capture_io { Hive::Commands::New.new(project, "content status row", workflow: "content_fixture").call }

          out, = capture_io { Hive::Commands::Status.new(json: true).call }
          rows = JSON.parse(out).dig("projects", 0, "tasks")

          coding = rows.find { |row| row.fetch("slug").start_with?("coding-status-row-") }
          content = rows.find { |row| row.fetch("slug").start_with?("content-status-row-") }
          assert_equal "coding", coding.fetch("workflow")
          assert_equal "ready_to_brainstorm", coding.fetch("action")
          assert_equal "content_fixture", content.fetch("workflow")
          assert_equal "ready_to_advance", content.fetch("action")
          assert_match(/\Ahive approve /, content.fetch("suggested_command"))
        end
      end
    end
  end

  def test_status_json_preserves_subsecond_task_mtimes
    payload = Hive::Commands::Status.new(json: true).send(:task_payload, {
      stage: "2-brainstorm",
      slug: "answered-260614-abcd",
      id: 1,
      display_name: "Answered",
      folder: "/tmp/task",
      state_file: "/tmp/task/brainstorm.md",
      worktree_path: nil,
      pr_url: nil,
      marker_name: :waiting,
      marker_attrs: {},
      mtime: Time.utc(2026, 6, 14, 18, 31, 27, 899_132),
      folder_mtime: Time.utc(2026, 6, 14, 18, 31, 28, 111_222),
      claude_pid: nil,
      claude_pid_alive: nil,
      live_task_lock: false,
      action_key: "needs_input",
      action_label: "Needs your input",
      suggested_command: "hive brainstorm answered-260614-abcd --from 2-brainstorm",
      next_action: nil,
      diagnostic: nil
    })

    assert_equal "2026-06-14T18:31:27.899132Z", payload["mtime"]
    assert_equal "2026-06-14T18:31:28.111222Z", payload["folder_mtime"]
  end

  def test_status_text_uses_display_name_and_slug_fallback
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "pretty row").call }
        capture_io { Hive::Commands::New.new(project, "fallback row").call }
        pretty = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "pretty-row-*")].first
        fallback = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "fallback-row-*")].first
        Hive::TaskMeta.update_display_name(pretty, "Pretty Row")

        out, = capture_io { Hive::Commands::Status.new.call }

        assert_match(/#1\s+—\s+Pretty Row/, out)
        assert_match(/#2\s+—\s+#{Regexp.escape(File.basename(fallback))}/, out)
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

  def seed_content_task(dir, stage_dir, slug, state_file, body)
    folder = File.join(dir, ".hive-state", "stages", stage_dir, slug)
    Hive::TaskMeta.write(folder, id: nil, slug: slug, display_name: nil, workflow: "content_fixture")
    File.write(File.join(folder, state_file), body)
  end

  def move_content_task(dir, slug, from_stage, to_stage, state_file, body)
    from = File.join(dir, ".hive-state", "stages", from_stage, slug)
    to = File.join(dir, ".hive-state", "stages", to_stage, slug)
    FileUtils.mkdir_p(File.dirname(to))
    FileUtils.mv(from, to)
    File.write(File.join(to, state_file), body)
  end
end
