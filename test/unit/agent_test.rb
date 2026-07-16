require "test_helper"
require "time"
require "hive/markers"
require "hive/lock"
require "hive/config"
require "hive/task"
require "hive/agent"
require "hive/agent_limit"

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
       HIVE_FAKE_CLAUDE_HANG HIVE_FAKE_CLAUDE_LOG_DIR
       HIVE_SCREENOTE_BASE_URL].each { |k| ENV.delete(k) }
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

  def test_run_emits_agent_start_and_end_events
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task.state_file
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n<!-- WAITING -->\n"

      Hive::Agent.new(
        task: task,
        prompt: "test",
        max_budget_usd: 1,
        timeout_sec: 5,
        log_label: "brainstorm"
      ).run!

      events = File.readlines(File.join(task.folder, "events.jsonl"), chomp: true).map { |line| JSON.parse(line) }
      start_event = events.find { |event| event.fetch("event_type") == "agent_start" }
      end_event = events.find { |event| event.fetch("event_type") == "agent_end" }

      refute_nil start_event
      refute_nil end_event
      assert_equal "claude brainstorm", start_event.fetch("agent")
      assert_equal start_event.fetch("agent"), end_event.fetch("agent")
      assert_includes start_event.fetch("message"), "timeout_sec=5"
      assert_includes end_event.fetch("message"), "status=waiting"
      assert_includes end_event.fetch("message"), "exit_code=0"
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

  def test_collects_grok_streaming_text_chunks_verbatim
    with_tmp_dir do |dir|
      task = make_task(dir)
      bin = File.join(dir, "fake-grok")
      File.write(bin, <<~SH)
        #!/bin/sh
        printf '%s\n' '{"type":"text","data":"Here&apos;s"}'
        printf '%s\n' '{"type":"text","data":" a summary"}'
        printf '%s\n' '{"type":"end","stopReason":"end_turn"}'
      SH
      File.chmod(0o755, bin)
      profile = Hive::AgentProfile.new(
        name: :grok,
        bin_default: bin,
        headless_flag: "-p",
        prompt_style: :headless_flag_value,
        version_flag: "--version",
        skill_syntax_format: "/%{skill}",
        status_detection_mode: :exit_code_only
      )

      result = Hive::Agent.new(
        task: task, prompt: "test", max_budget_usd: 1, timeout_sec: 5,
        profile: profile
      ).run!

      assert_equal :ok, result[:status]
      assert_equal "Here&apos;s a summary", result[:final_message]
      assert_equal :structured, result[:final_message_source]
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

  def test_timeout_emits_agent_end_with_timeout_status
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      ENV["HIVE_FAKE_CLAUDE_HANG"] = "5"

      Hive::Agent.new(task: task, prompt: "test", max_budget_usd: 1, timeout_sec: 1).run!

      events = File.readlines(File.join(task.folder, "events.jsonl"), chomp: true).map { |line| JSON.parse(line) }
      end_event = events.reverse.find { |event| event.fetch("event_type") == "agent_end" }
      assert_includes end_event.fetch("message"), "status=timeout"
    end
  end

  def test_exception_before_handle_exit_emits_agent_end_with_exception_status
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      agent = Hive::Agent.new(task: task, prompt: "test", max_budget_usd: 1, timeout_sec: 5)
      agent.define_singleton_method(:spawn_and_wait) { raise "synthetic spawn failure" }

      assert_raises(RuntimeError) { agent.run! }

      events = File.readlines(File.join(task.folder, "events.jsonl"), chomp: true).map { |line| JSON.parse(line) }
      end_event = events.reverse.find { |event| event.fetch("event_type") == "agent_end" }
      assert_includes end_event.fetch("message"), "status=exception"
      assert_includes end_event.fetch("message"), "RuntimeError: synthetic spawn failure"
    end
  end

  def test_cli_flags_refuse_non_claude_profiles
    with_tmp_dir do |dir|
      profile = Hive::AgentProfiles.lookup(:codex)
      agent = Hive::Agent.new(task: make_task(dir), prompt: "test",
                              max_budget_usd: 1, timeout_sec: 5,
                              profile: profile,
                              cli_flags: [ "--model", "sonnet" ])

      error = assert_raises(ArgumentError) { agent.send(:build_cmd) }
      assert_match(/claude-specific/, error.message,
                   "handing codex --model sonnet would fail or silently mean something else")
    end
  end

  def test_cli_flags_ride_the_headless_argv
    with_tmp_dir do |dir|
      agent = Hive::Agent.new(task: make_task(dir), prompt: "test",
                              max_budget_usd: 1, timeout_sec: 5,
                              cli_flags: [ "--model", "sonnet", "--effort", "medium" ])

      cmd = agent.send(:build_cmd)

      assert_equal %w[--model sonnet], cmd.each_cons(2).find { |a, _| a == "--model" },
                   "config model pins must reach the headless claude argv"
      assert_equal %w[--effort medium], cmd.each_cons(2).find { |a, _| a == "--effort" }
    end
  end

  def test_declared_safe_mode_capability_is_not_added_to_unrelated_claude_runs
    with_tmp_dir do |dir|
      agent = Hive::Agent.new(
        task: make_task(dir), prompt: "test", max_budget_usd: 1, timeout_sec: 5,
        profile: Hive::AgentProfiles.lookup(:claude)
      )

      refute_includes agent.send(:build_cmd), "--safe-mode"
    end
  end

  def test_claude_headless_tool_scope_flags_ride_the_argv
    with_tmp_dir do |dir|
      agent = Hive::Agent.new(
        task: make_task(dir),
        prompt: "test",
        max_budget_usd: 1,
        timeout_sec: 5,
        allowed_tools: %w[Read LS],
        disallowed_tools: %w[Write Bash]
      )

      cmd = agent.send(:build_cmd)

      assert_equal %w[--allowedTools Read,LS], cmd.each_cons(2).find { |a, _| a == "--allowedTools" }
      assert_equal %w[--disallowedTools Write,Bash], cmd.each_cons(2).find { |a, _| a == "--disallowedTools" }
      assert_operator cmd.index("--allowedTools"), :<, cmd.index("--max-budget-usd")
    end
  end

  def test_non_claude_profiles_omit_tool_scope_flags
    with_tmp_dir do |dir|
      profile = Hive::AgentProfiles.lookup(:codex)
      agent = Hive::Agent.new(
        task: make_task(dir),
        prompt: "test",
        max_budget_usd: 1,
        timeout_sec: 5,
        profile: profile,
        allowed_tools: %w[Read LS],
        disallowed_tools: %w[Write Bash]
      )

      cmd = agent.send(:build_cmd)

      refute_includes cmd, "--allowedTools"
      refute_includes cmd, "--disallowedTools"
    end
  end

  def test_codex_workspace_write_mode_replaces_dangerous_bypass_with_sandbox
    with_tmp_dir do |dir|
      profile = Hive::AgentProfiles.lookup(:codex)
      agent = Hive::Agent.new(
        task: make_task(dir), prompt: "test", max_budget_usd: nil,
        timeout_sec: 5, profile: profile,
        permission_mode: Hive::AgentProfile::WORKSPACE_WRITE_PERMISSION_MODE
      )

      cmd = agent.send(:build_cmd)

      assert_equal %w[--sandbox workspace-write], cmd.each_cons(2).find { |flag, _| flag == "--sandbox" }
      assert_includes cmd, "--ignore-user-config"
      assert_includes cmd, "--ignore-rules"
      refute_includes cmd, "--dangerously-bypass-approvals-and-sandbox"
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

  def test_screenote_base_url_is_scrubbed_from_the_agent_child_env
    with_tmp_dir do |dir|
      task = make_task(dir)
      log_dir = Dir.mktmpdir("fake-claude-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir
      ENV["HIVE_SCREENOTE_BASE_URL"] = "https://screenote.parent"
      File.write(task.state_file, "<!-- WAITING -->\n")

      Hive::Agent.new(task: task, prompt: "do work", max_budget_usd: 1, timeout_sec: 5).run!

      argv_log = File.read(File.join(log_dir, "fake-claude-argv.log"))
      assert_includes argv_log, "env_HIVE_SCREENOTE_BASE_URL=__unset__"
      refute_includes argv_log, "https://screenote.parent"
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end

  def test_claude_headless_permission_mode_auto_uses_permission_mode_flag
    with_tmp_dir do |dir|
      task = make_task(dir)
      log_dir = Dir.mktmpdir("fake-claude-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir
      File.write(task.state_file, "<!-- WAITING -->\n")
      Hive::Agent.new(
        task: task,
        prompt: "do work",
        max_budget_usd: 5,
        timeout_sec: 5,
        permission_mode: "auto"
      ).run!
      argv_log = File.read(File.join(log_dir, "fake-claude-argv.log"))
      assert_includes argv_log, "arg=--permission-mode"
      assert_includes argv_log, "arg=auto"
      refute_includes argv_log, "arg=--dangerously-skip-permissions"
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end

  # The default config resolves claude.permission_mode to "bypassPermissions",
  # which must map to the legacy --dangerously-skip-permissions flag (NOT
  # --permission-mode bypassPermissions). This is the branch every default
  # production run hits, so pin it explicitly.
  def test_claude_headless_permission_mode_bypass_uses_skip_flag
    with_tmp_dir do |dir|
      task = make_task(dir)
      log_dir = Dir.mktmpdir("fake-claude-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir
      File.write(task.state_file, "<!-- WAITING -->\n")
      Hive::Agent.new(
        task: task,
        prompt: "do work",
        max_budget_usd: 5,
        timeout_sec: 5,
        permission_mode: "bypassPermissions"
      ).run!
      argv_log = File.read(File.join(log_dir, "fake-claude-argv.log"))
      assert_includes argv_log, "arg=--dangerously-skip-permissions"
      refute_includes argv_log, "arg=--permission-mode"
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

  def test_captures_final_message_from_result_json
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = JSON.generate(
        "type" => "result",
        "subtype" => "success",
        "result" => "Final implementation summary"
      )
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task.state_file
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n<!-- WAITING -->\n"

      result = Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5).run!

      assert_equal "Final implementation summary", result[:final_message]
      assert_equal :waiting, result[:status]
    end
  end

  def test_captures_last_usage_from_profile_extractor
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = [
        JSON.generate(
          "type" => "stream_event",
          "event" => {
            "usage" => {
              "input_tokens" => 10,
              "output_tokens" => 5,
              "cache_read_input_tokens" => 2,
              "cache_creation_input_tokens" => 3
            }
          }
        ),
        JSON.generate(
          "type" => "result",
          "subtype" => "success",
          "result" => "done",
          "usage" => {
            "input_tokens" => 100,
            "output_tokens" => 50,
            "cache_read_input_tokens" => 20,
            "cache_creation_input_tokens" => 30
          },
          "modelUsage" => {
            "claude-opus-4-7" => { "inputTokens" => 100 }
          }
        )
      ].join("\n")
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task.state_file
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n<!-- WAITING -->\n"

      result = Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5).run!

      assert_equal({ input: 100, output: 50, cached: 50, model: "claude-opus-4-7" }, result[:usage])
      assert_equal "claude-opus-4-7", result[:model]
      assert_equal :waiting, result[:status]
    end
  end

  def test_profile_without_usage_extractor_returns_no_usage
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = JSON.generate(
        "type" => "result",
        "usage" => { "input_tokens" => 100, "output_tokens" => 50 }
      )
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task.state_file
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n<!-- WAITING -->\n"
      profile = Hive::AgentProfile.new(
        name: :no_usage,
        bin_default: FAKE_BIN,
        env_bin_override_key: "HIVE_CLAUDE_BIN",
        headless_flag: "-p",
        version_flag: "--version",
        skill_syntax_format: "/%{skill}",
        status_detection_mode: :state_file_marker
      )

      result = Hive::Agent.new(
        task: task,
        prompt: "x",
        max_budget_usd: 1,
        timeout_sec: 5,
        profile: profile
      ).run!

      assert_nil result[:usage]
      assert_nil result[:model]
      assert_equal :waiting, result[:status]
    end
  end

  def test_captures_final_message_from_codex_item_completed_json
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = JSON.generate(
        "type" => "item.completed",
        "item" => {
          "type" => "message",
          "role" => "assistant",
          "content" => [
            { "type" => "output_text", "text" => "Codex implementation summary" }
          ]
        }
      )
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task.state_file
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n<!-- WAITING -->\n"

      result = Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5).run!

      assert_equal "Codex implementation summary", result[:final_message]
      assert_equal :waiting, result[:status]
    end
  end

  def test_ignores_non_object_json_stream_events
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = JSON.generate([ "not", "an", "event" ])
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task.state_file
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n<!-- WAITING -->\n"

      result = Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5).run!

      assert_equal "", result[:final_message]
      assert_equal :waiting, result[:status]
    end
  end

  def test_codex_profile_reads_prompt_from_stdin
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      fake_codex = File.join(dir, "fake-codex")
      argv_log = File.join(dir, "argv.log")
      stdin_log = File.join(dir, "stdin.log")
      File.write(fake_codex, <<~SH)
        #!/usr/bin/env bash
        printf '%s\n' "$@" > "#{argv_log}"
        cat > "#{stdin_log}"
        exit 0
      SH
      File.chmod(0o755, fake_codex)
      profile = Hive::AgentProfile.new(
        name: :codex,
        bin_default: fake_codex,
        headless_flag: "exec",
        version_flag: "--version",
        skill_syntax_format: "/%{skill}",
        status_detection_mode: :exit_code_only
      )

      result = Hive::Agent.new(
        task: task,
        prompt: "large prompt body",
        max_budget_usd: 1,
        timeout_sec: 5,
        profile: profile,
        status_mode: :exit_code_only
      ).run!

      assert_equal :ok, result[:status]
      argv = File.read(argv_log).lines.map(&:chomp)
      assert_equal "exec", argv[0]
      assert_equal "-", argv[-1]
      refute_includes argv, "large prompt body"
      assert_equal "large prompt body", File.read(stdin_log)
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
      inode_log = File.join(dir, "atomic-inodes")
      File.write(atomic_bin, <<~RUBY)
        #!#{RbConfig.ruby}
        target = #{task.state_file.dump}
        inode_log = #{inode_log.dump}
        previous_inode = File.stat(target).ino
        tmp = "#{task.state_file}.atomic-\#{Process.pid}"
        File.write(tmp, "## Round 1\n<!-- WAITING -->\n")
        replacement_inode = File.stat(tmp).ino
        File.write(inode_log, [ previous_inode, replacement_inode ].join("\n"))
        File.rename(tmp, target)
        exit 0
      RUBY
      File.chmod(0o755, atomic_bin)
      ENV["HIVE_CLAUDE_BIN"] = atomic_bin

      result = Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5).run!
      post_inode = File.stat(task.state_file).ino
      previous_inode, replacement_inode = File.readlines(inode_log, chomp: true).map { |line| Integer(line) }

      refute_equal previous_inode, replacement_inode,
                   "fake must create the replacement before releasing the previous inode"
      assert_equal replacement_inode, post_inode,
                   "the replacement inode must become the final task state file"
      assert_equal :waiting, result[:status],
                   "atomic-rename writes must not be misclassified as concurrent edits"
      assert_equal :waiting, Hive::Markers.current(task.state_file).name
    end
  end

  def test_rejects_unknown_status_mode
    with_tmp_dir do |dir|
      task = make_task(dir)

      err = assert_raises(ArgumentError) do
        Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5, status_mode: :unknown)
      end

      assert_match(/unknown status_mode/, err.message)
    end
  end

  def test_legacy_class_method_warning_emits_once_outside_test_context
    old_hive_test = ENV.delete("HIVE_TEST")
    old_warned = Hive::Agent.instance_variable_get(:@legacy_warned)
    minitest = Object.const_get(:Minitest) if Object.const_defined?(:Minitest)
    Object.send(:remove_const, :Minitest) if minitest
    Hive::Agent.instance_variable_set(:@legacy_warned, {})

    _out, err = capture_io do
      Hive::Agent.maybe_warn_legacy_class_method(:bin)
      Hive::Agent.maybe_warn_legacy_class_method(:bin)
    end

    assert_equal 1, err.scan(/Hive::Agent\.bin/).size
  ensure
    ENV["HIVE_TEST"] = old_hive_test if old_hive_test
    Object.const_set(:Minitest, minitest) if minitest && !Object.const_defined?(:Minitest)
    Hive::Agent.instance_variable_set(:@legacy_warned, old_warned || {})
  end

  def test_spawn_and_wait_uses_pid_when_process_group_disappears
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task.state_file
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n<!-- WAITING -->\n"

      result = with_replaced_singleton_method(Process, :getpgid, ->(_pid) { raise Errno::ESRCH }) do
        Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5).run!
      end

      assert_equal result[:pid], result[:pgid]
      assert_equal :waiting, result[:status]
    end
  end

  def test_spawn_records_agent_pid_and_start_time_in_one_lock_update
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task.state_file
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n<!-- WAITING -->\n"
      updates = []
      start_time_pids = []

      with_replaced_singleton_method(Hive::Lock, :process_start_time, lambda { |pid|
        start_time_pids << pid
        "spawn-start-time"
      }) do
        with_replaced_singleton_method(Hive::Lock, :update_task_lock, lambda { |folder, additions|
          updates << [ folder, additions ]
        }) do
          result = Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5).run!

          assert_equal [ result[:pid] ], start_time_pids
          assert_equal [
            [
              task.folder,
              {
                "claude_pid" => result[:pid],
                "claude_pid_start_time" => "spawn-start-time"
              }
            ]
          ], updates
        end
      end
    end
  end

  def test_signaled_subprocess_reports_negative_exit_code
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      signal_bin = File.join(dir, "signal-agent")
      File.write(signal_bin, <<~RUBY)
        #!/usr/bin/env ruby
        Process.kill("TERM", Process.pid)
        sleep 1
      RUBY
      File.chmod(0o755, signal_bin)
      ENV["HIVE_CLAUDE_BIN"] = signal_bin

      result = Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5).run!

      assert_equal(-Signal.list.fetch("TERM"), result[:exit_code])
      assert_equal :error, result[:status]
      assert_equal((-Signal.list.fetch("TERM")).to_s, Hive::Markers.current(task.state_file).attrs["exit_code"])
    end
  end

  def test_kill_group_ignores_process_errors
    with_tmp_dir do |dir|
      agent = Hive::Agent.new(task: make_task(dir), prompt: "x", max_budget_usd: 1, timeout_sec: 5)

      with_replaced_singleton_method(Process, :kill, ->(_signal, _target) { raise Errno::EPERM }) do
        assert_nil agent.kill_group(123)
      end
    end
  end

  def test_sleep_grace_then_kill_ignores_kill_errors
    with_tmp_dir do |dir|
      agent = Hive::Agent.new(task: make_task(dir), prompt: "x", max_budget_usd: 1, timeout_sec: 5)
      start = Time.now
      times = [ start, start + 4 ]

      with_replaced_singleton_method(Time, :now, -> { times.shift || start + 4 }) do
        with_replaced_singleton_method(Process, :kill, ->(_signal, _target) { raise Errno::ESRCH }) do
          assert_nil agent.sleep_grace_then_kill(123, 456)
        end
      end
    end
  end

  def test_sleep_grace_then_kill_ignores_missing_child
    with_tmp_dir do |dir|
      agent = Hive::Agent.new(task: make_task(dir), prompt: "x", max_budget_usd: 1, timeout_sec: 5)

      with_replaced_singleton_method(Process, :wait, ->(_pid, _flags) { raise Errno::ECHILD }) do
        assert_nil agent.sleep_grace_then_kill(123, 456)
      end
    end
  end

  def test_state_file_marker_nil_exit_without_marker_sets_error
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      agent = Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5)
      result = { timed_out: false, exit_code: nil }

      agent.handle_exit(result)

      marker = Hive::Markers.current(task.state_file)
      assert_equal :error, result[:status]
      assert_equal :error, marker.name
      assert_equal "no_marker_no_exit_code", marker.attrs["reason"]
    end
  end

  def test_state_file_marker_classifies_provider_limits_before_exit_code
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      agent = Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5)
      result = {
        timed_out: false,
        exit_code: 1,
        final_message: "Error: RESOURCE_EXHAUSTED: quota exceeded"
      }

      # Floor to whole seconds: retry_after is a second-precision iso8601
      # stamp, so the lower bound must drop sub-second slack on `before`.
      before = Time.now.utc.floor
      agent.handle_exit(result)
      after = Time.now.utc

      marker = Hive::Markers.current(task.state_file)
      assert_equal :error, result[:status]
      assert_match(/\Alimits reached for claude:/, result[:error_message])
      assert_equal :error, marker.name
      assert_equal "limits_reached", marker.attrs["reason"]
      assert_match(/quota exceeded/, marker.attrs["message"])

      retry_after = Time.parse(marker.attrs.fetch("retry_after"))
      cooldown = Hive::AgentLimit::RETRY_COOLDOWN_SEC
      assert retry_after >= before + cooldown,
             "limits_reached marker must stamp a cooldown retry_after"
      assert retry_after <= after + cooldown
    end
  end

  def test_classifies_limit_from_limit_text_when_final_message_is_clean
    # Codex surfaces the usage-limit notice as a structured stream event, so
    # final_message ends up clean (e.g. "exit_code=1") while limit_text carries
    # the real signal. handle_exit must classify off limit_text, not just
    # final_message.
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      agent = Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5)
      result = {
        timed_out: false,
        exit_code: 1,
        final_message: "",
        limit_text: "You've hit your usage limit. Visit .../usage to purchase more credits."
      }

      agent.handle_exit(result)

      assert_equal :error, result[:status]
      assert_match(/\Alimits reached for claude:/, result[:error_message])
      assert_equal "limits_reached", Hive::Markers.current(task.state_file).attrs["reason"]
    end
  end

  def test_captures_usage_limit_from_structured_error_stream_event
    # End-to-end: a codex-style {"type":"error","message":"...usage limit..."}
    # JSON event (which MessageExtractor does not surface as a final message)
    # plus a nonzero exit must be reported as limits_reached, not exit_code=1.
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = JSON.generate(
        "type" => "error",
        "message" => "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again later."
      )
      ENV["HIVE_FAKE_CLAUDE_EXIT"] = "1"

      result = Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5).run!

      assert_match(/usage limit/i, result[:limit_text].to_s,
                   "limit text must be captured from the structured error stream event")
      assert_equal :error, result[:status]
      assert_match(/\Alimits reached for claude:/, result[:error_message].to_s,
                   "must classify as limits-reached, not a generic exit_code failure")
      assert_equal "limits_reached", Hive::Markers.current(task.state_file).attrs["reason"]
    end
  end

  def test_output_file_mode_classifies_limits_before_missing_expected_output
    with_tmp_dir do |dir|
      task = make_task(dir)
      profile = Hive::AgentProfiles.lookup(:codex)
      agent = Hive::Agent.new(
        task: task,
        prompt: "x",
        max_budget_usd: 1,
        timeout_sec: 5,
        profile: profile,
        status_mode: :output_file_exists,
        expected_output: File.join(task.folder, "missing.md")
      )
      result = {
        timed_out: false,
        exit_code: 1,
        final_message: "429 Too Many Requests: rate limit reached"
      }

      agent.handle_exit(result)

      assert_equal :error, result[:status]
      assert_match(/\Alimits reached for codex:/, result[:error_message])
      refute_match(/expected output file missing/, result[:error_message])
    end
  end

  def test_extract_final_message_handles_agent_and_assistant_shapes
    with_tmp_dir do |dir|
      agent = Hive::Agent.new(task: make_task(dir), prompt: "x", max_budget_usd: 1, timeout_sec: 5)

      assert_equal "agent says hi", agent.send(:extract_final_message, JSON.generate(
        "type" => "agent_message",
        "text" => " agent says hi "
      ))
      assert_nil agent.send(:extract_final_message, JSON.generate(
        "type" => "assistant",
        "message" => "not-a-hash"
      ))
      assert_equal "assistant content", agent.send(:extract_final_message, JSON.generate(
        "type" => "assistant",
        "message" => { "content" => [ { "type" => "text", "text" => "assistant content" } ] }
      ))
    end
  end
  def test_event_stage_falls_back_to_parent_folder_for_synthetic_task_without_stage_name
    task = Struct.new(:folder).new("/tmp/project/.hive-state/stages/6-review/synthetic")
    agent = Hive::Agent.allocate
    agent.instance_variable_set(:@task, task)

    assert_equal "6-review", agent.send(:event_stage)
  end
end
