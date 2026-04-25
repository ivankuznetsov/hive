require "test_helper"
require "hive/markers"
require "hive/lock"
require "hive/config"
require "hive/task"
require "hive/agent"

class AgentTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    %w[HIVE_FAKE_CLAUDE_OUTPUT HIVE_FAKE_CLAUDE_EXIT
       HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT
       HIVE_FAKE_CLAUDE_HANG HIVE_FAKE_CLAUDE_LOG_DIR].each { |k| ENV.delete(k) }
  end

  def make_task(dir, stage = "2-brainstorm", slug = "agent-test-260424-aaaa")
    folder = File.join(dir, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    Hive::Task.new(folder)
  end

  def test_writes_marker_and_log_on_success
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task.state_file
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n<!-- WAITING -->\n"

      result = Hive::Agent.new(task: task, prompt: "test", max_budget_usd: 1, timeout_sec: 5).run!

      assert_equal 0, result[:exit_code]
      assert_equal :waiting, result[:status]
      assert_equal :waiting, Hive::Markers.current(task.state_file).name
      assert File.exist?(result[:log_file])
    end
  end

  def test_marks_error_when_subprocess_exits_nonzero
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      ENV["HIVE_FAKE_CLAUDE_EXIT"] = "1"

      result = Hive::Agent.new(task: task, prompt: "test", max_budget_usd: 1, timeout_sec: 5).run!

      assert_equal :error, result[:status]
      marker = Hive::Markers.current(task.state_file)
      assert_equal :error, marker.name
      assert_equal "exit_code", marker.attrs["reason"]
    end
  end

  def test_timeout_sigterms_subprocess
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      ENV["HIVE_FAKE_CLAUDE_HANG"] = "5"

      t0 = Time.now
      result = Hive::Agent.new(task: task, prompt: "test", max_budget_usd: 1, timeout_sec: 1).run!
      elapsed = Time.now - t0

      assert result[:timed_out], "expected timeout flag"
      assert_equal :timeout, result[:status]
      assert_operator elapsed, :<, 4
      marker = Hive::Markers.current(task.state_file)
      assert_equal :error, marker.name
      assert_equal "timeout", marker.attrs["reason"]
    end
  end

  def test_args_include_dangerous_flag_and_add_dir
    with_tmp_dir do |dir|
      task = make_task(dir)
      log_dir = Dir.mktmpdir("fake-claude-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir
      File.write(task.state_file, "<!-- WAITING -->\n")
      Hive::Agent.new(task: task, prompt: "do work", max_budget_usd: 5, timeout_sec: 5,
                      add_dirs: [ dir ]).run!
      argv_log = File.read(File.join(log_dir, "fake-claude-argv.log"))
      assert_includes argv_log, "arg=--dangerously-skip-permissions"
      assert_includes argv_log, "arg=--add-dir"
      assert_includes argv_log, "arg=#{dir}"
      assert_includes argv_log, "arg=--max-budget-usd"
      assert_includes argv_log, "arg=5"
      assert_includes argv_log, "arg=--no-session-persistence"
      assert_includes argv_log, "arg=do work"
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end

  # Regression: real claude requires --verbose whenever -p is paired with
  # --output-format=stream-json. Smoke test caught this; the original argv test
  # didn't assert it. Keep this assertion permanent so future drift fails fast.
  def test_argv_includes_verbose_when_stream_json
    with_tmp_dir do |dir|
      task = make_task(dir)
      log_dir = Dir.mktmpdir("fake-claude-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir
      File.write(task.state_file, "<!-- WAITING -->\n")
      Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5).run!
      argv_log = File.read(File.join(log_dir, "fake-claude-argv.log"))
      assert_includes argv_log, "arg=-p"
      assert_includes argv_log, "arg=--output-format"
      assert_includes argv_log, "arg=stream-json"
      assert_includes argv_log, "arg=--verbose",
                      "claude requires --verbose with stream-json + -p (regression: missed in smoke)"
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end

  # Regression: real claude streams ~50KB of stream-json events. The reader
  # thread + Process.wait race needs to keep the exit code captured even when
  # the pipe gets a heavy fill.
  def test_exit_code_captured_with_large_stream_output
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      # Generate ~50 KB of JSON-line output so the reader thread is non-trivial.
      ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = (1..2000).map do |i|
        %({"type":"stream_event","i":#{i},"pad":"#{'x' * 20}"})
      end.join("\n")
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task.state_file
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n<!-- WAITING -->\n"
      result = Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 10).run!
      assert_equal 0, result[:exit_code], "exit code must be 0 even after heavy stream output"
      assert_equal :waiting, result[:status]
      assert_equal :waiting, Hive::Markers.current(task.state_file).name
    end
  end

  # Regression: claude's Edit/Write tools rewrite atomically (write tempfile
  # then rename), changing the file's inode. The earlier inode-tracking
  # heuristic falsely flagged that as a "concurrent edit". Verify hive does
  # not error out when the agent's writes change inode.
  def test_atomic_rename_writes_do_not_trigger_false_error
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")

      # Build a fake-claude that writes via temp+rename (changes inode).
      atomic_bin = File.join(dir, "atomic-fake-claude")
      File.write(atomic_bin, <<~SH)
        #!/usr/bin/env bash
        target="#{task.state_file}"
        tmp="$(mktemp)"
        printf '## Round 1\\n<!-- WAITING -->\\n' > "$tmp"
        mv "$tmp" "$target"
        exit 0
      SH
      File.chmod(0o755, atomic_bin)
      ENV["HIVE_CLAUDE_BIN"] = atomic_bin

      pre_inode = File.stat(task.state_file).ino
      result = Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5).run!
      post_inode = File.stat(task.state_file).ino

      refute_equal pre_inode, post_inode, "fake must rotate the inode for this test to be meaningful"
      assert_equal :waiting, result[:status],
                   "atomic-rename writes must not be misclassified as concurrent edits"
      assert_equal :waiting, Hive::Markers.current(task.state_file).name
    end
  end
end
