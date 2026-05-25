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

  def test_status_private_helpers_cover_error_and_fallback_paths
    cmd = Hive::Commands::Status.new
    assert_equal [], cmd.send(:detect_legacy_stage_dirs, "/tmp/no-such-hive-state")
    assert_match(/h ago/, cmd.send(:humanise_age, Time.now - 7_200))
    assert_match(/d ago/, cmd.send(:humanise_age, Time.now - 172_800))
    marker = Hive::Markers::State.new(name: :error, attrs: { "detail" => "line 1\nline 2" }, raw: nil)
    assert_equal "error detail=line 1 line 2", cmd.send(:label_for, marker)
    assert_equal Hive::Schemas::StatusErrorKind::ERROR,
                 cmd.send(:error_kind_for, Hive::Error.new("generic"))

    with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::EPERM }) do
      assert_equal true, cmd.send(:pid_alive?, 12_345)
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
      File.write(File.join(dir, ".lock"), "- not\n- a\n- hash\n")
      assert_nil cmd.send(:lookup_claude_pid, task)
      File.write(File.join(dir, ".lock"), "[")
      assert_nil cmd.send(:lookup_claude_pid, task)
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
end
