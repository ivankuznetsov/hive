require "test_helper"
require "hive/commands/status"

class CommandsStatusTest < Minitest::Test
  include HiveTestHelper

  def test_json_payload_ignores_archived_manual_stage_sibling
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      active = File.join(hive_state, "stages", "4-execute", "active-task")
      archived = File.join(hive_state, "stages", "archived-manual", "manual-task")
      FileUtils.mkdir_p(active)
      FileUtils.mkdir_p(archived)
      File.write(File.join(active, "task.md"), "# Active\n<!-- EXECUTE_WAITING -->\n")
      File.write(File.join(archived, "task.md"), "# Archived manually\n<!-- MANUAL_STEERING -->\n")

      payload = Hive::Commands::Status.new.json_payload([
        { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      ])

      slugs = payload.fetch("projects").first.fetch("tasks").map { |task| task.fetch("slug") }
      assert_includes slugs, "active-task"
      refute_includes slugs, "manual-task"
      assert_equal [], payload.fetch("projects").first.fetch("legacy_stage_dirs"),
                   "archived-manual is an intentional status-private sibling, not a legacy stage"
      assert_nil payload.fetch("projects").first.fetch("legacy_migrate_command")
    end
  end

  def test_json_payload_emits_live_task_lock_as_strict_boolean
    # Fix #144 regression guard: external consumers (TUI, daemon, bots)
    # rely on `live_task_lock` to render the runner badge without
    # re-parsing the .lock file. Must be a strict boolean — never null —
    # even when the underlying classifier returned nil (no .lock file).
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      live_folder = File.join(hive_state, "stages", "4-execute", "live-task-260525-aaaa")
      idle_folder = File.join(hive_state, "stages", "4-execute", "idle-task-260525-bbbb")
      FileUtils.mkdir_p(live_folder)
      FileUtils.mkdir_p(idle_folder)
      File.write(File.join(live_folder, "task.md"), "<!-- EXECUTE_COMPLETE -->\n")
      File.write(File.join(live_folder, ".lock"), YAML.dump(
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid)
      ))
      File.write(File.join(idle_folder, "task.md"), "<!-- EXECUTE_COMPLETE -->\n")

      payload = Hive::Commands::Status.new.json_payload([
        { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      ])
      tasks = payload.fetch("projects").first.fetch("tasks")
      live = tasks.find { |t| t.fetch("slug") == "live-task-260525-aaaa" }
      idle = tasks.find { |t| t.fetch("slug") == "idle-task-260525-bbbb" }

      assert_equal true, live.fetch("live_task_lock")
      assert_equal false, idle.fetch("live_task_lock"),
                   "rows without a .lock must serialise as false, never nil"
    end
  end

  def test_json_payload_emits_folder_mtime_and_keeps_old_archived_tasks
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "9-done", "old-archived-260604-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "task.md"), "<!-- COMPLETE -->\n")
      old = Time.now - (5 * 86_400)
      File.utime(old, old, folder)

      payload = Hive::Commands::Status.new.json_payload([
        { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      ])
      tasks = payload.fetch("projects").first.fetch("tasks")
      archived = tasks.find { |task| task.fetch("slug") == "old-archived-260604-abcd" }

      refute_nil archived, "default JSON must keep old archived rows visible to bots and daemons"
      assert_equal old.utc.iso8601, archived.fetch("folder_mtime")
    end
  end

  # #270: a held brainstorm exposes its unanswered-question count so a
  # consumer can tell "daemon is holding this" from "broken". Every other
  # row reports 0.
  def test_json_payload_emits_unanswered_questions_for_held_brainstorm
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      bs = File.join(hive_state, "stages", "2-brainstorm", "bs-task-260525-cccc")
      ex = File.join(hive_state, "stages", "4-execute", "ex-task-260525-dddd")
      FileUtils.mkdir_p(bs)
      FileUtils.mkdir_p(ex)
      # Q1 unanswered, Q2 answered → count 1; WAITING marker → needs_input.
      File.write(File.join(bs, "brainstorm.md"),
                 "## Round 1\n### Q1.\nWhat?\n### A1.\n\n### Q2.\nWhy?\n### A2.\nyes\n<!-- WAITING -->\n")
      File.write(File.join(ex, "task.md"), "<!-- EXECUTE_COMPLETE -->\n")

      tasks = Hive::Commands::Status.new.json_payload([
        { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      ]).fetch("projects").first.fetch("tasks")
      brainstorm = tasks.find { |t| t.fetch("slug") == "bs-task-260525-cccc" }
      execute = tasks.find { |t| t.fetch("slug") == "ex-task-260525-dddd" }

      assert_equal "needs_input", brainstorm.fetch("action"),
                   "precondition: the brainstorm row is a needs_input hold"
      assert_equal 1, brainstorm.fetch("unanswered_questions")
      assert_equal 0, execute.fetch("unanswered_questions"),
                   "non-brainstorm rows always report 0"
    end
  end

  # #270: unanswered_question_count must never break `hive status` — a
  # parse error on a mid-write/malformed brainstorm.md degrades to 0.
  def test_unanswered_question_count_degrades_to_zero_on_parse_error
    with_tmp_dir do |dir|
      path = File.join(dir, "brainstorm.md")
      File.write(path, "## Round 1\n### Q1.\nWhat?\n### A1.\n\n")
      row = { action_key: Hive::Schemas::TaskActionKind::NEEDS_INPUT,
              stage: "2-brainstorm", state_file: path }
      with_replaced_singleton_method(Hive::BrainstormParser, :parse, ->(*) { raise "boom" }) do
        assert_equal 0, Hive::Commands::Status.new.send(:unanswered_question_count, row)
      end
    end
  end

  def test_call_rejects_empty_diagnose_and_write_without_diagnose
    error = assert_raises(Hive::Error) { Hive::Commands::Status.new(diagnose: "  ").call }
    assert_match(/--diagnose requires a non-empty task slug/, error.message)

    error = assert_raises(Hive::Error) { Hive::Commands::Status.new(write: true).call }
    assert_match(/--write requires --diagnose/, error.message)
  end

  def test_project_payload_and_text_render_report_missing_paths
    cmd = Hive::Commands::Status.new

    missing = cmd.project_payload(
      { "name" => "missing", "path" => "/tmp/no-such-hive-project", "hive_state_path" => "/tmp/nope/.hive-state" },
      project_count: 1
    )
    assert_equal "missing_project_path", missing.fetch("error")
    assert_equal [], missing.fetch("tasks")

    with_tmp_dir do |project_root|
      uninitialised = cmd.project_payload(
        { "name" => "plain", "path" => project_root, "hive_state_path" => File.join(project_root, ".hive-state") },
        project_count: 1
      )
      assert_equal "not_initialised", uninitialised.fetch("error")

      out, = capture_io do
        cmd.send(:render_project, { "name" => "plain", "path" => project_root,
                                    "hive_state_path" => File.join(project_root, ".hive-state") }, project_count: 1)
      end
      assert_includes out, "not initialised"
    end

    out, = capture_io do
      cmd.send(:render_project, { "name" => "missing", "path" => "/tmp/no-such-hive-project",
                                  "hive_state_path" => "/tmp/nope/.hive-state" }, project_count: 1)
    end
    assert_includes out, "missing project path"
  end

  def test_collect_rows_skips_invalid_entries_and_handles_live_agent_lock
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      execute_stage = File.join(hive_state, "stages", "4-execute")
      plan_stage = File.join(hive_state, "stages", "3-plan")
      FileUtils.mkdir_p(execute_stage)
      FileUtils.mkdir_p(plan_stage)
      File.write(File.join(execute_stage, "not-a-task.txt"), "skip me")
      FileUtils.mkdir_p(File.join(execute_stage, "BAD-SLUG"))

      live_folder = File.join(execute_stage, "live-agent-260522-abcd")
      FileUtils.mkdir_p(live_folder)
      File.write(File.join(live_folder, "task.md"), "<!-- AGENT_WORKING pid=1 -->\n")
      File.write(File.join(live_folder, ".lock"), YAML.dump("claude_pid" => Process.pid))
      File.write(File.join(live_folder, "worktree.yml"), "path: [")

      missing_state_folder = File.join(plan_stage, "missing-state-260522-abcd")
      FileUtils.mkdir_p(missing_state_folder)

      rows = Hive::Commands::Status.new.send(:collect_rows, hive_state)
      slugs = rows.map { |row| row.fetch(:slug) }

      assert_includes slugs, "live-agent-260522-abcd"
      assert_includes slugs, "missing-state-260522-abcd"
      refute_includes slugs, "BAD-SLUG"
      live = rows.find { |row| row[:slug] == "live-agent-260522-abcd" }
      assert_nil live.fetch(:worktree_path)
      assert_equal Process.pid.to_s, live.fetch(:claude_pid).to_s
      assert_equal true, live.fetch(:claude_pid_alive)
      assert_match(/agent_working pid=#{Process.pid}/, live.fetch(:state_label))

      liveness = Hive::Commands::Status.new.send(:liveness_kwargs_for, Hive::Task.new(live_folder))
      assert_equal true, liveness.fetch(:pid_alive)
    end
  end

  def test_live_task_lock_overrides_marker_derived_action
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "6-review", "reviewing-task-260524-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "task.md"), "<!-- EXECUTE_COMPLETE -->\n")
      File.write(File.join(folder, ".lock"), YAML.dump(
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid),
        "slug" => "reviewing-task-260524-abcd",
        "stage" => "review"
      ))

      cmd = Hive::Commands::Status.new
      rows = cmd.send(:annotate_actions,
                      cmd.send(:collect_rows, hive_state),
                      { "name" => "demo" },
                      1,
                      with_diagnostic: false)
      row = rows.find { |candidate| candidate[:slug] == "reviewing-task-260524-abcd" }

      assert_equal :execute_complete, row.fetch(:marker_name)
      assert_equal true, row.fetch(:live_task_lock)
      assert_equal "agent_running", row.fetch(:action_key)
      assert_equal "Agent running", row.fetch(:action_label)
      assert_nil row.fetch(:suggested_command)
      assert_match(/run_lock pid=#{Process.pid}/, row.fetch(:state_label))
    end
  end

  def test_agent_working_with_live_runner_lock_is_not_rendered_stale_before_claude_pid
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "5-open-pr", "opening-task-260524-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "pr.md"), "<!-- AGENT_WORKING -->\n")
      File.write(File.join(folder, ".lock"), YAML.dump(
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid),
        "slug" => "opening-task-260524-abcd",
        "stage" => "open-pr"
      ))

      cmd = Hive::Commands::Status.new
      rows = cmd.send(:annotate_actions,
                      cmd.send(:collect_rows, hive_state),
                      { "name" => "demo" },
                      1,
                      with_diagnostic: false)
      row = rows.find { |candidate| candidate[:slug] == "opening-task-260524-abcd" }

      assert_equal :agent_working, row.fetch(:marker_name)
      assert_equal true, row.fetch(:live_task_lock)
      assert_nil row.fetch(:claude_pid)
      assert_equal "agent_running", row.fetch(:action_key)
      assert_equal "Agent running", row.fetch(:action_label)
      assert_nil row.fetch(:suggested_command)
      assert_match(/run_lock pid=#{Process.pid}/, row.fetch(:state_label))
    end
  end

  def test_dead_task_lock_does_not_override_marker_derived_action
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "4-execute", "ready-task-260524-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "task.md"), "<!-- EXECUTE_COMPLETE -->\n")
      File.write(File.join(folder, ".lock"), YAML.dump(
        "pid" => 12_345,
        "process_start_time" => "old-start",
        "slug" => "ready-task-260524-abcd",
        "stage" => "execute"
      ))

      cmd = Hive::Commands::Status.new
      cmd.define_singleton_method(:pid_alive?) { |_pid| false }
      rows = cmd.send(:annotate_actions,
                      cmd.send(:collect_rows, hive_state),
                      { "name" => "demo" },
                      1,
                      with_diagnostic: false)
      row = rows.find { |candidate| candidate[:slug] == "ready-task-260524-abcd" }

      assert_equal false, row.fetch(:live_task_lock)
      assert_equal "ready_to_open_pr", row.fetch(:action_key)
      assert_equal "hive open-pr ready-task-260524-abcd --from 4-execute", row.fetch(:suggested_command)
    end
  end

  def test_live_task_lock_with_recorded_but_unreadable_live_start_time_is_stale
    # PID-reuse defense: a .lock written with a recorded process_start_time
    # whose live counterpart can no longer be read (containerised /proc,
    # PID has since exited and the kernel reused it) must be treated as
    # stale. Otherwise we'd misclassify a freshly-reused PID as live.
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "4-execute", "phantom-task-260525-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "task.md"), "<!-- EXECUTE_COMPLETE -->\n")
      File.write(File.join(folder, ".lock"), YAML.dump(
        "pid" => Process.pid,
        "process_start_time" => "recorded-but-unreadable-now",
        "slug" => "phantom-task-260525-abcd",
        "stage" => "execute"
      ))

      cmd = Hive::Commands::Status.new
      rows = nil
      with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { nil }) do
        rows = cmd.send(:annotate_actions,
                        cmd.send(:collect_rows, hive_state),
                        { "name" => "demo" },
                        1,
                        with_diagnostic: false)
      end
      row = rows.find { |candidate| candidate[:slug] == "phantom-task-260525-abcd" }

      assert_equal false, row.fetch(:live_task_lock),
                   "recorded start time + nil live start time must be classified as stale (PID may have been reused)"
    end
  end

  def test_live_task_lock_with_legacy_lock_omitting_process_start_time_is_live
    # Backwards-compat: .lock files written before the start-time guard
    # was introduced have no `process_start_time` key. Treat those as
    # live when the PID is alive — the alternative (treating legacy locks
    # as stale) would auto-classify in-flight runs from older hive
    # versions as recoverable, racing the daemon's auto-heal.
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "4-execute", "legacy-task-260525-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "task.md"), "<!-- EXECUTE_COMPLETE -->\n")
      File.write(File.join(folder, ".lock"), YAML.dump(
        "pid" => Process.pid,
        "slug" => "legacy-task-260525-abcd",
        "stage" => "execute"
      ))

      cmd = Hive::Commands::Status.new
      rows = cmd.send(:annotate_actions,
                      cmd.send(:collect_rows, hive_state),
                      { "name" => "demo" },
                      1,
                      with_diagnostic: false)
      row = rows.find { |candidate| candidate[:slug] == "legacy-task-260525-abcd" }

      assert_equal true, row.fetch(:live_task_lock),
                   "legacy lock without process_start_time must stay live while PID is alive"
      assert_equal "agent_running", row.fetch(:action_key)
    end
  end

  def test_live_task_lock_with_mismatched_process_start_time_is_treated_as_stale
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "4-execute", "executing-task-260524-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "task.md"), "<!-- EXECUTE_COMPLETE -->\n")
      File.write(File.join(folder, ".lock"), YAML.dump(
        "pid" => Process.pid,
        "process_start_time" => "wrong-start-1234",
        "slug" => "executing-task-260524-abcd",
        "stage" => "execute"
      ))

      cmd = Hive::Commands::Status.new
      rows = cmd.send(:annotate_actions,
                      cmd.send(:collect_rows, hive_state),
                      { "name" => "demo" },
                      1,
                      with_diagnostic: false)
      row = rows.find { |candidate| candidate[:slug] == "executing-task-260524-abcd" }

      assert_equal false, row.fetch(:live_task_lock)
      assert_equal "ready_to_open_pr", row.fetch(:action_key)
    end
  end

  def test_render_project_skips_empty_action_label_groups
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      folder = File.join(hive_state, "stages", "1-inbox", "queued-task-260522-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "idea.md"), "Idea\n")
      cmd = Hive::Commands::Status.new
      cmd.define_singleton_method(:action_labels) { |_rows| [ "Not present" ] }

      out, = capture_io do
        cmd.send(:render_project, { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state },
                 project_count: 1)
      end

      assert_includes out, "demo"
      refute_includes out, "queued-task-260522-abcd"
    end
  end

  def test_render_project_hides_old_clean_archived_rows_and_prints_summary
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      create_status_task(hive_state, "9-done", "old-archived-260604-abcd", marker: "COMPLETE", age_days: 5)

      out, = capture_io do
        Hive::Commands::Status.new.send(:render_project, status_project(project_root, hive_state), project_count: 1)
      end

      refute_includes out, "old-archived-260604-abcd"
      assert_includes out, "… and 1 archived >3d ago (hive archive to view)"
      refute_includes out, "no active tasks"
    end
  end

  def test_render_project_keeps_recent_archived_rows_without_summary
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      create_status_task(hive_state, "9-done", "recent-archived-260604-abcd", marker: "COMPLETE", age_days: 1)

      out, = capture_io do
        Hive::Commands::Status.new.send(:render_project, status_project(project_root, hive_state), project_count: 1)
      end

      assert_includes out, "Archived"
      assert_includes out, "recent-archived-260604-abcd"
      refute_includes out, "archived >3d ago"
    end
  end

  def test_render_project_keeps_old_archived_rows_with_unresolved_markers
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      create_status_task(hive_state, "9-done", "errored-archived-260604-abcd", marker: "ERROR", age_days: 10)

      out, = capture_io do
        Hive::Commands::Status.new.send(:render_project, status_project(project_root, hive_state), project_count: 1)
      end

      assert_includes out, "Error"
      assert_includes out, "errored-archived-260604-abcd"
      refute_includes out, "archived >3d ago"
    end
  end

  def test_render_project_reports_hidden_count_with_mixed_archived_rows
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      12.times do |idx|
        create_status_task(hive_state, "9-done", "old-archived-#{idx}-260604-abcd", marker: "COMPLETE", age_days: 5)
      end
      create_status_task(hive_state, "9-done", "recent-archived-260604-abcd", marker: "COMPLETE", age_days: 1)

      out, = capture_io do
        Hive::Commands::Status.new.send(:render_project, status_project(project_root, hive_state), project_count: 1)
      end

      assert_includes out, "recent-archived-260604-abcd"
      refute_includes out, "old-archived-0-260604-abcd"
      assert_includes out, "… and 12 archived >3d ago (hive archive to view)"
    end
  end

  def test_render_project_never_hides_old_non_archived_rows
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      create_status_task(hive_state, "4-execute", "old-execute-260604-abcd", marker: "EXECUTE_COMPLETE", age_days: 99)

      out, = capture_io do
        Hive::Commands::Status.new.send(:render_project, status_project(project_root, hive_state), project_count: 1)
      end

      assert_includes out, "old-execute-260604-abcd"
      refute_includes out, "archived >3d ago"
    end
  end

  def test_status_private_helpers_cover_error_and_fallback_paths
    cmd = Hive::Commands::Status.new
    assert_equal [], cmd.send(:detect_legacy_stage_dirs, "/tmp/no-such-hive-state")
    assert_match(/h ago/, cmd.send(:humanise_age, Time.now - 7_200))
    assert_match(/d ago/, cmd.send(:humanise_age, Time.now - 172_800))
    marker = Hive::Markers::State.new(
      name: :error,
      attrs: { "detail" => "line 1\nline 2", "marker_id" => "err-123" },
      raw: nil
    )
    assert_equal "error detail=line 1 line 2", cmd.send(:label_for, marker)
    assert_equal Hive::Schemas::StatusErrorKind::ERROR,
                 cmd.send(:error_kind_for, Hive::Error.new("generic"))

    with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::EPERM }) do
      assert_equal true, cmd.send(:pid_alive?, 12_345)
    end

    holder = { "pid" => 12_345, "process_start_time" => "recorded" }
    cmd.define_singleton_method(:pid_alive?) { |_pid| true }
    with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { raise RuntimeError, "blocked" }) do
      _out, err = capture_io do
        assert_nil cmd.send(:live_task_lock_holder, holder)
      end
      assert_includes err, "hive: status: failed to check liveness"
      assert_includes err, "RuntimeError: blocked"
    end

    with_replaced_singleton_method(Hive::Config, :load_global_daemon, -> { { "agent_marker_grace_sec" => "not-int" } }) do
      _out, err = capture_io do
        assert_equal Hive::TaskAction::DEFAULT_AGENT_MARKER_GRACE_SEC,
                     cmd.send(:agent_marker_grace_sec_from_config)
      end
      assert_includes err, "invalid daemon.agent_marker_grace_sec"
    end

    with_tmp_dir do |dir|
      task = Struct.new(:folder).new(dir)
      # Array-shaped (parseable but not a Hash) → silently nil, no warn.
      File.write(File.join(dir, ".lock"), "- not\n- a\n- hash\n")
      _out, err = capture_io do
        assert_nil cmd.send(:claude_pid_from_lock, cmd.send(:task_lock_holder, task))
      end
      assert_equal "", err,
                   "a parseable non-Hash .lock must not trigger the corrupt-lock warn"

      # Malformed YAML → rescue path, must emit warn so the degraded
      # classification ("no lock" despite something being on disk) is
      # observable in operator output.
      File.write(File.join(dir, ".lock"), "[")
      _out, err = capture_io do
        assert_nil cmd.send(:claude_pid_from_lock, cmd.send(:task_lock_holder, task))
      end
      assert_includes err, "hive: status: failed to read .lock"
      assert_includes err, "Psych"
    end
  end

  def test_project_name_and_error_envelope_fallback_branches
    cmd = Hive::Commands::Status.new

    with_tmp_dir do |project_root|
      folder = File.join(project_root, ".hive-state", "stages", "1-inbox", "named-task-260522-abcd")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)
      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [ { "name" => "registered", "path" => project_root } ] }) do
        assert_equal "registered", cmd.send(:project_name_for, task)
      end
    end

    with_replaced_singleton_method(JSON, :generate, ->(_payload) { raise JSON::GeneratorError, "nope" }) do
      out, = capture_io { cmd.send(:emit_error_envelope, Hive::Error.new("boom")) }
      assert_equal "", out
    end
  end

  def test_non_json_internal_error_does_not_emit_error_envelope
    cmd = Hive::Commands::Status.new(json: false)
    cmd.define_singleton_method(:do_call) { raise RuntimeError, "boom" }

    out, err, status = with_captured_exit { cmd.call }

    assert_equal Hive::ExitCodes::SOFTWARE, status
    assert_equal "", out
    assert_includes err, "internal error: RuntimeError: boom"
  end

  def test_emit_diagnose_result_text_branches
    cmd = Hive::Commands::Status.new
    task = Struct.new(:slug, :folder).new("diagnose-task-260522-abcd", "/tmp/diagnose-task")

    out, = capture_io do
      cmd.send(:emit_diagnose_result, task, { "summary" => "summary", "detail" => "detail" }, "/tmp/diagnostic.md")
    end
    assert_includes out, "wrote /tmp/diagnostic.md"

    out, = capture_io do
      cmd.send(:emit_diagnose_result, task, { "summary" => "summary", "detail" => "detail" }, nil)
    end
    assert_includes out, "summary"
    assert_includes out, "detail"

    out, = capture_io { cmd.send(:emit_diagnose_result, task, nil, nil) }
    assert_includes out, "no red-status diagnostic"
  end

  private

  def status_project(project_root, hive_state)
    { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
  end

  def create_status_task(hive_state, stage, slug, marker:, age_days:)
    folder = File.join(hive_state, "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    state_file = File.join(folder, stage == "9-done" ? "task.md" : "task.md")
    File.write(state_file, "<!-- #{marker} -->\n")
    old = Time.now - (age_days * 86_400)
    File.utime(old, old, state_file)
    File.utime(old, old, folder)
    folder
  end
end
