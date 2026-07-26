require "test_helper"
require "time"
require "hive/markers"
require "hive/lock"
require "hive/config"
require "hive/task"
require "hive/agent"
require "hive/agent_limit"
require "hive/workflow_package/runtime_policy"

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
       HIVE_FAKE_CLAUDE_OUTPUT_AFTER_WRITE HIVE_FAKE_CLAUDE_FINAL_OUTPUT
       HIVE_FAKE_CLAUDE_DELAY_BEFORE_WRITE HIVE_FAKE_CLAUDE_DELAY_AFTER_WRITE_OUTPUT
       HIVE_FAKE_CLAUDE_HANG HIVE_FAKE_CLAUDE_IGNORE_TERM HIVE_FAKE_CLAUDE_LOG_DIR
       HIVE_FAKE_CLAUDE_READY_FILE HIVE_FAKE_CLAUDE_RELEASE_FILE
       HIVE_SCREENOTE_BASE_URL].each { |k| ENV.delete(k) }
  end

  def make_task(dir, stage = "2-brainstorm", slug = "agent-test-260424-aaaa")
    folder = File.join(dir, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    Hive::Task.new(folder)
  end

  def run_delta_before_write(dir, max_turns: nil, max_tokens: nil)
    task = make_task(dir)
    output = File.join(dir, "findings.json")
    ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = [
      {
        "type" => "stream_event",
        "event" => {
          "type" => "content_block_start",
          "content_block" => { "type" => "tool_use", "name" => "Write" }
        }
      },
      {
        "type" => "stream_event",
        "event" => {
          "type" => "message_delta",
          "delta" => { "stop_reason" => "tool_use" },
          "usage" => { "input_tokens" => 20, "output_tokens" => 1 }
        }
      }
    ].map { |event| JSON.generate(event) }.join("\n")
    ENV["HIVE_FAKE_CLAUDE_DELAY_BEFORE_WRITE"] = "0.5"
    ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = output
    ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "{\"findings\":[]}\n"
    ENV["HIVE_FAKE_CLAUDE_OUTPUT_AFTER_WRITE"] = JSON.generate(
      "type" => "user", "tool_use_result" => { "type" => "create" }
    )
    ENV["HIVE_FAKE_CLAUDE_HANG"] = "10"

    Hive::Agent.new(
      task: task, prompt: "x", max_budget_usd: 1,
      max_turns: max_turns, max_tokens: max_tokens,
      timeout_sec: 8, status_mode: :output_file_exists,
      expected_output: output
    ).run!
  end

  def test_managed_runtime_policy_controls_headless_argv_and_child_environment
    with_tmp_dir do |dir|
      task = make_task(dir)
      policy = Hive::WorkflowPackage::RuntimePolicy.compile(
        {
          "tools" => %w[Read Bash], "deny" => [ "Write" ], "directories" => [],
          "commands" => [ "git status" ], "domains" => [], "credentials" => []
        },
        task_folder: task.folder,
        profile: Hive::AgentProfiles.lookup(:claude),
        policy_dir: File.join(dir, "policy")
      )
      agent = Hive::Agent.new(
        task: task, prompt: "test", max_budget_usd: 1, timeout_sec: 5,
        runtime_policy: policy
      )

      cmd = agent.send(:build_cmd)
      assert_equal "dontAsk", cmd[cmd.index("--permission-mode") + 1]
      assert_equal policy.allowed_tools.join(","), cmd[cmd.index("--allowedTools") + 1]
      assert_equal policy.settings_path, cmd[cmd.index("--settings") + 1]
      assert_equal "", cmd[cmd.index("--setting-sources") + 1]
      assert_equal policy.environment, agent.child_environment.reject { |key, _| key == "HIVE_SCREENOTE_BASE_URL" }
      assert_nil agent.child_environment.fetch("HIVE_SCREENOTE_BASE_URL")
      assert_equal policy.directories, agent.add_dirs
    end
  end

  def test_writes_marker_and_log_on_success
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task.state_file
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n<!-- WAITING -->\n"

      agent = Hive::Agent.new(task: task, prompt: "test", max_budget_usd: 1, timeout_sec: 5)
      result = agent.run!

      assert_equal 0, result[:exit_code]
      assert_equal :waiting, result[:status]
      assert_equal :waiting, Hive::Markers.current(task.state_file).name
      assert File.exist?(result[:log_file])
      assert_equal 0o600, File.stat(result[:log_file]).mode & 0o777
      assert_instance_of Hive::AgentRuntime::ObservableResult, agent.observable_result
      assert_equal :waiting, agent.observable_result.status
      assert_equal result[:exit_code], agent.observable_result.exit_code
    end
  end

  def test_log_omits_prompt_bearing_argv_and_redacts_whole_and_split_credentials
    with_tmp_dir do |dir|
      task = make_task(dir)
      prompt_secret = "prompt-only-#{'q' * 32}"
      token = "ghp_#{'A' * 36}"
      split_token = "ghp_#{'B' * 36}"
      split_bin = File.join(dir, "split-stream-agent")
      File.write(split_bin, <<~SH)
        #!/bin/sh
        printf '%s\n' 'whole=#{token}'
        printf 'split=ghp_'
        printf '#{'B' * 18}' >&2
        printf '%s\n' '#{'B' * 18}'
      SH
      File.chmod(0o755, split_bin)
      ENV["HIVE_CLAUDE_BIN"] = split_bin

      result = Hive::Agent.new(
        task: task, prompt: prompt_secret, max_budget_usd: 1,
        timeout_sec: 5, status_mode: :exit_code_only
      ).run!
      log = File.read(result.fetch(:log_file))

      refute_includes log, prompt_secret
      refute_includes log, token
      refute_includes log, split_token
      assert_includes log, "[REDACTED:github_token]"
      assert_includes log, "profile=claude"
      refute_includes log, "cmd=["
      assert_equal 0o600, File.stat(result[:log_file]).mode & 0o777
    end
  end

  def test_log_and_start_event_record_typed_model_and_effective_effort_without_serializing_argv
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task.state_file
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n<!-- WAITING -->\n"
      profile = Hive::AgentProfiles.lookup(:claude)
      launch_arguments = profile.identity_arguments(model: "claude-opus-4-8", effort: "high")

      result = Hive::Agent.new(
        task: task, prompt: "do not log this prompt", max_budget_usd: 1, timeout_sec: 5,
        profile: profile, launch_arguments: launch_arguments
      ).run!

      log = File.read(result.fetch(:log_file))
      start_event = File.readlines(File.join(task.folder, "events.jsonl"), chomp: true)
                        .map { |line| JSON.parse(line) }
                        .find { |event| event.fetch("event_type") == "agent_start" }
      [ log, start_event.fetch("message") ].each do |receipt|
        assert_includes receipt, "model=claude-opus-4-8"
        assert_includes receipt, "requested_effort=high"
        assert_includes receipt, "effective_effort=high"
        assert_includes receipt, "model_pinned=true"
        assert_includes receipt, "effort_supported=true"
        refute_includes receipt, "--model"
        refute_includes receipt, "do not log this prompt"
      end
    end
  end

  def test_launch_arguments_reject_invalid_types_and_conflicting_native_argv
    with_tmp_dir do |dir|
      task = make_task(dir)
      profile = Hive::AgentProfiles.lookup(:claude)
      launch_arguments = profile.identity_arguments(model: "claude-opus-4-8", effort: "high")

      error = assert_raises(ArgumentError) do
        Hive::Agent.new(
          task: task, prompt: "test", max_budget_usd: 1, timeout_sec: 5,
          profile: profile, launch_arguments: {}
        )
      end
      assert_includes error.message, "LaunchArguments"

      error = assert_raises(ArgumentError) do
        Hive::Agent.new(
          task: task, prompt: "test", max_budget_usd: 1, timeout_sec: 5,
          profile: profile, launch_arguments: launch_arguments,
          identity_arguments: [ "--model", "different-model" ]
        )
      end
      assert_includes error.message, "different native argv"
    end
  end

  def test_private_log_open_refuses_symlinks
    with_tmp_dir do |dir|
      target = File.join(dir, "outside.log")
      link = File.join(dir, "agent.log")
      File.write(target, "preserve\n")
      File.symlink(target, link)
      agent = Hive::Agent.new(
        task: make_task(dir), prompt: "safe", max_budget_usd: 1,
        timeout_sec: 5, status_mode: :exit_code_only
      )

      assert_raises(SystemCallError) do
        agent.send(:open_private_log, link) { |log| log.write("tampered\n") }
      end
      assert_equal "preserve\n", File.read(target)
    end
  end

  def test_can_disable_raw_stream_retention_for_confidential_agent_runs
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      secret = "ghp_#{'s' * 36}"
      ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = JSON.generate("type" => "result", "result" => secret)
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task.state_file
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n<!-- WAITING -->\n"

      result = Hive::Agent.new(
        task: task, prompt: "test", max_budget_usd: 1, timeout_sec: 5,
        log_stream: false
      ).run!

      refute_includes File.read(result.fetch(:log_file)), secret
      refute_includes File.read(result.fetch(:log_file)), "[stream]"
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

  def test_grok_terminal_structured_output_replaces_streaming_text
    with_tmp_dir do |dir|
      task = make_task(dir)
      bin = File.join(dir, "fake-grok")
      File.write(bin, <<~SH)
        #!/bin/sh
        printf '%s\n' '{"type":"text","data":"review prose"}'
        printf '%s\n' '{"type":"end","stopReason":"EndTurn","structuredOutput":{"files":{"reviews/adversarial-01.md":"Verdict: ready\\n"}}}'
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
      log = File.read(result.fetch(:log_file))

      assert_equal(
        JSON.generate("files" => { "reviews/adversarial-01.md" => "Verdict: ready\n" }),
        result[:final_message]
      )
      assert_equal :structured, result[:final_message_source]
      refute_includes log, "review prose"
      refute_includes log, "Verdict: ready"
      assert_includes log, "[structured message omitted type=end]"
    end
  end

  def test_grok_malformed_terminal_structured_output_never_persists_to_log
    {
      "string" => '"sensitive malformed output"',
      "array" => '["sensitive malformed output"]',
      "null" => "null"
    }.each do |name, value|
      with_tmp_dir do |dir|
        task = make_task(dir)
        bin = File.join(dir, "fake-grok")
        File.write(bin, <<~SH)
          #!/bin/sh
          printf '%s\n' '{"type":"text","data":"review prose"}'
          printf '%s\n' '{"type":"end","stopReason":"EndTurn","structuredOutput":#{value}}'
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
        log = File.read(result.fetch(:log_file))

        assert_equal "review prose", result[:final_message], name
        refute_includes log, '"structuredOutput":', name
        refute_includes log, "sensitive malformed output", name
        assert_includes log, "[structured message omitted type=end]", name
      end
    end
  end

  def test_structured_message_chunks_never_persist_to_the_agent_log
    with_tmp_dir do |dir|
      task = make_task(dir)
      first = "ghp_#{'C' * 18}"
      second = "#{'C' * 18}"
      bin = File.join(dir, "structured-message-agent")
      File.write(bin, <<~SH)
        #!/bin/sh
        printf '%s\n' '{"type":"text","data":"#{first}"}'
        printf '%s\n' '{"type":"text","data":"#{second}"}'
        printf '%s\n' '{"type":"end","stopReason":"end_turn"}'
      SH
      File.chmod(0o755, bin)
      profile = Hive::AgentProfile.new(
        name: :grok, bin_default: bin, headless_flag: "-p",
        prompt_style: :headless_flag_value, version_flag: "--version",
        skill_syntax_format: "/%{skill}", status_detection_mode: :exit_code_only
      )

      result = Hive::Agent.new(
        task: task, prompt: "test", max_budget_usd: 1, timeout_sec: 5, profile: profile
      ).run!
      log = File.read(result.fetch(:log_file))

      assert_equal "#{first}#{second}", result.fetch(:final_message)
      refute_includes log, first
      refute_includes log, second
      refute_includes log, "#{first}#{second}"
      assert_equal 2, log.scan("[structured message omitted type=text]").length
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

  def test_fake_agent_condition_barrier_announces_readiness_and_waits_for_release
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      ready = File.join(dir, "barrier", "ready")
      release = File.join(dir, "barrier", "release")
      ENV["HIVE_FAKE_CLAUDE_READY_FILE"] = ready
      ENV["HIVE_FAKE_CLAUDE_RELEASE_FILE"] = release
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task.state_file
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n<!-- WAITING -->\n"

      worker = Thread.new do
        Hive::Agent.new(task: task, prompt: "test", max_budget_usd: 1, timeout_sec: 5).run!
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      sleep 0.01 until File.exist?(ready) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      assert File.exist?(ready), "fake agent must publish its readiness condition"
      assert worker.alive?, "fake agent must remain live until the release condition exists"

      FileUtils.mkdir_p(File.dirname(release))
      File.write(release, "go\n")
      result = worker.value

      assert_equal :waiting, result[:status]
      assert_equal :waiting, Hive::Markers.current(task.state_file).name
    ensure
      if worker&.alive? && release
        FileUtils.mkdir_p(File.dirname(release))
        FileUtils.touch(release)
        worker.join(2)
      end
      worker&.kill if worker&.alive?
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

  def test_typed_identity_flags_reach_codex_as_discrete_arguments
    with_tmp_dir do |dir|
      profile = Hive::AgentProfiles.lookup(:codex)
      identity = profile.identity_arguments(model: "gpt-5.6-terra", effort: "medium")
      agent = Hive::Agent.new(task: make_task(dir), prompt: "test",
                              max_budget_usd: 1, timeout_sec: 5,
                              profile: profile,
                              identity_arguments: identity.native_arguments)

      cmd = agent.send(:build_cmd)
      profile.permission_flags.each { |argument| assert_includes cmd, argument }
      assert_equal %w[--model gpt-5.6-terra], cmd.each_cons(2).find { |a, _| a == "--model" }
      assert_equal [ "-c", "model_reasoning_effort=medium" ],
                   cmd.each_cons(2).find { |a, _| a == "-c" }
    end
  end

  def test_rejects_untyped_claude_cli_flags_for_non_claude_profiles
    with_tmp_dir do |dir|
      agent = Hive::Agent.new(
        task: make_task(dir), prompt: "test", max_budget_usd: 1, timeout_sec: 5,
        profile: Hive::AgentProfiles.lookup(:codex), cli_flags: [ "--model", "unsafe" ]
      )

      error = assert_raises(Hive::AgentRuntime::UnsupportedCapability) { agent.send(:build_cmd) }
      assert_equal :raw_cli_arguments, error.evidence.capability
      assert_equal false, error.evidence.supported
    end
  end

  def test_managed_runtime_policy_can_supply_trusted_non_claude_argv
    with_tmp_dir do |dir|
      task = make_task(dir)
      package = File.join(dir, "package")
      FileUtils.mkdir_p(package)
      output = File.join(task.folder, "result.md")
      policy = with_env("HIVE_CODEX_BIN" => "/bin/true") do
        Hive::WorkflowPackage::RuntimePolicy.compile_actor(
          {
            "preset" => "scoped",
            "tools" => [ "Read", "Edit(./result.md)" ]
          },
          task_folder: task.folder,
          package_root: package,
          profile: Hive::AgentProfiles.lookup(:codex),
          managed_outputs: [ output ]
        )
      end
      agent = Hive::Agent.new(
        task: task,
        prompt: "test",
        max_budget_usd: 1,
        timeout_sec: 5,
        profile: Hive::AgentProfiles.lookup(:codex),
        runtime_policy: policy
      )

      cmd = agent.send(:build_cmd)
      assert_equal File.realpath("/bin/true"), cmd.first
      assert_includes cmd, "default_permissions=\"hive-managed\""
      assert_includes cmd, "--output-schema"
      assert_includes cmd, "--ephemeral"
      assert_includes cmd, "--ignore-user-config"
      assert_includes cmd, "--ignore-rules"
      refute_includes cmd, "--dangerously-bypass-approvals-and-sandbox"
    ensure
      policy&.cleanup!
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

  def test_claude_headless_carries_path_qualified_rules_in_dont_ask_mode
    with_tmp_dir do |dir|
      agent = Hive::Agent.new(
        task: make_task(dir),
        prompt: "test",
        max_budget_usd: 1,
        timeout_sec: 5,
        permission_mode: "dontAsk",
        allowed_tools: [ "Read", "Edit(//tmp/task/inspect.md)", "Edit(//tmp/project/docs/**)" ],
        disallowed_tools: %w[Bash]
      )

      cmd = agent.send(:build_cmd)

      assert_equal %w[--permission-mode dontAsk],
                   cmd.each_cons(2).find { |arg, _| arg == "--permission-mode" }
      assert_equal [ "--allowedTools", "Read,Edit(//tmp/task/inspect.md),Edit(//tmp/project/docs/**)" ],
                   cmd.each_cons(2).find { |arg, _| arg == "--allowedTools" }
      assert_equal %w[--disallowedTools Bash],
                   cmd.each_cons(2).find { |arg, _| arg == "--disallowedTools" }
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
      refute result[:final_message_truncated]
      assert_equal :waiting, result[:status]
    end
  end

  def test_classifies_structured_claude_max_budget_result_without_result_text
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = JSON.generate(
        "type" => "result",
        "subtype" => "error_max_budget_usd",
        "is_error" => true,
        "total_cost_usd" => 1.047936,
        "errors" => [ "Reached maximum budget ($1)" ]
      )
      ENV["HIVE_FAKE_CLAUDE_EXIT"] = "1"

      result = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1.0, timeout_sec: 5
      ).run!

      assert_equal :error, result.fetch(:status)
      assert_equal "budget_exhausted", result.fetch(:failure_origin)
      assert_equal(
        {
          provider: "claude",
          subtype: "error_max_budget_usd",
          configured_cap_usd: 1.0,
          observed_cost_usd: 1.047936,
          diagnostic: "Reached maximum budget ($1)",
          remedy: "raise_stage_budget"
        },
        result.fetch(:failure_details)
      )
      marker = Hive::Markers.current(task.state_file)
      assert_equal "budget_exhausted", marker.attrs.fetch("reason")
      assert_equal "claude", marker.attrs.fetch("provider")
      assert_equal "error_max_budget_usd", marker.attrs.fetch("subtype")
      assert_equal "1.0", marker.attrs.fetch("max_budget_usd")
      assert_equal "1.047936", marker.attrs.fetch("observed_cost_usd")
      assert_equal "raise_stage_budget", marker.attrs.fetch("remedy")
      refute Hive::AgentLimit.held?(marker.name, marker.attrs)
    end
  end

  def test_successful_structured_result_that_mentions_budget_is_not_budget_exhaustion
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = JSON.generate(
        "type" => "result",
        "subtype" => "success",
        "result" => "The project budget is documented."
      )
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task.state_file
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n### Q1. Scope?\n### A1.\n<!-- WAITING -->\n"

      result = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1.0, timeout_sec: 5
      ).run!

      assert_equal :waiting, result.fetch(:status)
      refute result.key?(:failure_origin)
      assert_equal :waiting, Hive::Markers.current(task.state_file).name
    end
  end

  def test_current_terminal_marker_wins_over_trailing_structured_budget_diagnostic
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = JSON.generate(
        "type" => "result",
        "subtype" => "error_max_budget_usd",
        "is_error" => true,
        "total_cost_usd" => 1.047936,
        "errors" => [ "Reached maximum budget ($1)" ]
      )
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task.state_file
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n### Q1. Scope?\n### A1.\n<!-- WAITING -->\n"
      ENV["HIVE_FAKE_CLAUDE_EXIT"] = "1"

      result = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1.0, timeout_sec: 5
      ).run!

      assert_equal :waiting, result.fetch(:status)
      assert_equal "budget_exhausted", result.fetch(:failure_origin)
      assert_equal :waiting, Hive::Markers.current(task.state_file).name
    end
  end

  def test_oversized_structured_result_is_reported_without_a_corrupt_prefix
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = JSON.generate(
        "type" => "result",
        "subtype" => "success",
        "result" => "x" * (Hive::Agent::FINAL_MESSAGE_TAIL_BYTES + 1)
      )
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task.state_file
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n<!-- WAITING -->\n"

      result = Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5).run!

      assert_nil result[:final_message]
      assert_equal :structured_truncated, result[:final_message_source]
      assert result[:final_message_truncated]
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

  def test_terminates_running_agent_when_streamed_tokens_reach_per_launch_limit
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = [
        JSON.generate(
          "type" => "stream_event",
          "event" => {
            "type" => "message_start",
            "message" => {
              "id" => "msg-1",
              "usage" => {
                "input_tokens" => 40,
                "output_tokens" => 1,
                "cache_read_input_tokens" => 30
              }
            }
          }
        ),
        JSON.generate(
          "type" => "stream_event",
          "event" => {
            "type" => "message_delta",
            "usage" => { "output_tokens" => 20 }
          }
        )
      ].join("\n")
      ENV["HIVE_FAKE_CLAUDE_HANG"] = "10"

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Hive::Agent.new(
        task: task,
        prompt: "x",
        max_budget_usd: 1,
        max_tokens: 60,
        timeout_sec: 8,
        status_mode: :exit_code_only
      ).run!
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator elapsed, :<, 5, "streamed token guard must stop the process before timeout"
      assert_equal :error, result[:status]
      assert_equal "token_limit", result.dig(:resource_exhaustion, :reason)
      assert_equal 60, result.dig(:resource_exhaustion, :limit)
      assert_operator result.dig(:resource_exhaustion, :observed), :>=, 60
      assert_match(/in-flight token limit/, result[:error_message])
      refute result[:timed_out]
    end
  end

  def test_force_kills_term_resistant_agent_after_streamed_token_limit
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = JSON.generate(
        "type" => "stream_event",
        "event" => {
          "type" => "message_start",
          "message" => { "usage" => { "input_tokens" => 80 } }
        }
      )
      ENV["HIVE_FAKE_CLAUDE_IGNORE_TERM"] = "1"
      ENV["HIVE_FAKE_CLAUDE_HANG"] = "20"

      original_grace = Hive::Agent::TERMINATION_GRACE_SECONDS
      Hive::Agent.send(:remove_const, :TERMINATION_GRACE_SECONDS)
      Hive::Agent.const_set(:TERMINATION_GRACE_SECONDS, 0)
      begin
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = Hive::Agent.new(
          task: task, prompt: "x", max_budget_usd: 1, max_tokens: 80,
          timeout_sec: 15, status_mode: :exit_code_only
        ).run!
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      ensure
        Hive::Agent.send(:remove_const, :TERMINATION_GRACE_SECONDS)
        Hive::Agent.const_set(:TERMINATION_GRACE_SECONDS, original_grace)
      end

      assert_operator elapsed, :<, 8, "token guard must escalate TERM before the wall-clock timeout"
      assert_equal :error, result[:status]
      assert_equal "token_limit", result.dig(:resource_exhaustion, :reason)
      refute result[:timed_out]
    end
  end

  def test_terminates_claude_after_the_configured_completed_turns
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = 3.times.map do |index|
        JSON.generate(
          "type" => "stream_event",
          "event" => {
            "type" => "message_delta",
            "usage" => { "output_tokens" => index + 1 }
          }
        )
      end.join("\n")
      ENV["HIVE_FAKE_CLAUDE_HANG"] = "10"

      result = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1, max_turns: 3,
        timeout_sec: 8, status_mode: :exit_code_only
      ).run!

      assert_equal :error, result.fetch(:status)
      assert_equal "turn_limit", result.dig(:resource_exhaustion, :reason)
      assert_equal 3, result.dig(:resource_exhaustion, :observed)
      assert_match(/in-flight turn limit/, result.fetch(:error_message))
      refute result.fetch(:timed_out)
    end
  end

  def test_turn_limit_accepts_a_completed_output_artifact
    with_tmp_dir do |dir|
      task = make_task(dir)
      output = File.join(dir, "findings.json")
      File.write(output, "{\"findings\":[]}\n")
      agent = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1, max_turns: 3,
        timeout_sec: 5, status_mode: :output_file_exists,
        expected_output: output
      )
      result = {
        resource_exhaustion: { reason: "turn_limit", observed: 3, limit: 3 }
      }

      agent.handle_exit(result)

      assert_equal :ok, result.fetch(:status)
      refute result.key?(:error_message)
    end
  end

  def test_token_limit_accepts_a_completed_output_artifact_without_another_turn
    with_tmp_dir do |dir|
      task = make_task(dir)
      output = File.join(dir, "findings.json")
      File.write(output, "{\"findings\":[]}\n")
      agent = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1, max_tokens: 40,
        timeout_sec: 5, status_mode: :output_file_exists,
        expected_output: output
      )
      result = {
        resource_exhaustion: { reason: "token_limit", observed: 41, limit: 40 }
      }

      agent.handle_exit(result)

      assert_equal :ok, result.fetch(:status)
      refute result.key?(:error_message)
    end
  end

  def test_completed_output_is_a_terminal_signal_on_the_write_result_event
    with_tmp_dir do |dir|
      task = make_task(dir)
      output = File.join(dir, "findings.json")
      File.write(output, "{\"findings\":[]}\n")
      agent = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1, max_turns: 3,
        timeout_sec: 5, status_mode: :output_file_exists,
        expected_output: output
      )
      write_result = { "type" => "user", "tool_use_result" => { "type" => "create" } }

      assert agent.send(:output_completed_event?, write_result)

      result = { output_completed: true }
      agent.handle_exit(result)
      assert_equal :ok, result.fetch(:status)
    end
  end

  def test_completed_output_stops_a_running_agent_on_the_next_structured_event
    with_tmp_dir do |dir|
      task = make_task(dir)
      output = File.join(dir, "findings.json")
      ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = JSON.generate(
        "type" => "stream_event",
        "event" => {
          "type" => "content_block_start",
          "content_block" => { "type" => "tool_use", "name" => "Write" }
        }
      )
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = output
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "{\"findings\":[]}\n"
      ENV["HIVE_FAKE_CLAUDE_OUTPUT_AFTER_WRITE"] = JSON.generate(
        "type" => "user", "tool_use_result" => { "type" => "create" }
      )
      ENV["HIVE_FAKE_CLAUDE_DELAY_AFTER_WRITE_OUTPUT"] = "1"
      ENV["HIVE_FAKE_CLAUDE_FINAL_OUTPUT"] = JSON.generate(
        "type" => "stream_event",
        "event" => {
          "type" => "message_delta",
          "usage" => {
            "input_tokens" => 27,
            "cache_read_input_tokens" => 15_554,
            "output_tokens" => 4_439
          }
        }
      )
      ENV["HIVE_FAKE_CLAUDE_HANG"] = "10"

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1, max_turns: 3,
        timeout_sec: 8, status_mode: :output_file_exists,
        expected_output: output
      ).run!
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator elapsed, :<, 4
      assert_equal :ok, result.fetch(:status)
      assert result.fetch(:output_completed)
      assert_nil result.fetch(:resource_exhaustion)
      assert_equal({ input: 27, output: 4_439, cached: 15_554, model: nil }, result.fetch(:usage))
    end
  end

  def test_turn_limit_allows_a_generated_write_to_finish_when_delta_arrives_first
    with_tmp_dir do |dir|
      result = run_delta_before_write(dir, max_turns: 1)

      assert_equal :ok, result.fetch(:status)
      assert result.fetch(:output_completed)
      assert_equal "turn_limit", result.dig(:resource_exhaustion, :reason)
    end
  end

  def test_token_limit_allows_a_generated_write_to_finish_when_delta_arrives_first
    with_tmp_dir do |dir|
      result = run_delta_before_write(dir, max_tokens: 10)

      assert_equal :ok, result.fetch(:status)
      assert result.fetch(:output_completed)
      assert_equal "token_limit", result.dig(:resource_exhaustion, :reason)
    end
  end

  def test_completed_output_does_not_wait_forever_for_a_missing_usage_delta
    with_tmp_dir do |dir|
      task = make_task(dir)
      output = File.join(dir, "findings.json")
      ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = JSON.generate(
        "type" => "stream_event",
        "event" => {
          "type" => "content_block_start",
          "content_block" => { "type" => "tool_use", "name" => "Write" }
        }
      )
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = output
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "{\"findings\":[]}\n"
      ENV["HIVE_FAKE_CLAUDE_OUTPUT_AFTER_WRITE"] = JSON.generate(
        "type" => "user", "tool_use_result" => { "type" => "create" }
      )
      ENV["HIVE_FAKE_CLAUDE_HANG"] = "10"

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1, max_turns: 3,
        timeout_sec: 8, status_mode: :output_file_exists,
        expected_output: output
      ).run!
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator elapsed, :>=, Hive::Agent::COMPLETION_EVENT_GRACE_SECONDS - 0.5
      assert_operator elapsed, :<, 7
      assert_equal :ok, result.fetch(:status)
      assert result.fetch(:output_completed)
    end
  end

  def test_completed_output_stops_before_a_new_model_turn_when_usage_delta_is_missing
    with_tmp_dir do |dir|
      task = make_task(dir)
      output = File.join(dir, "findings.json")
      ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = JSON.generate(
        "type" => "stream_event",
        "event" => {
          "type" => "content_block_start",
          "content_block" => { "type" => "tool_use", "name" => "Write" }
        }
      )
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = output
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "{\"findings\":[]}\n"
      ENV["HIVE_FAKE_CLAUDE_OUTPUT_AFTER_WRITE"] = JSON.generate(
        "type" => "user", "tool_use_result" => { "type" => "create" }
      )
      ENV["HIVE_FAKE_CLAUDE_DELAY_AFTER_WRITE_OUTPUT"] = "0.2"
      ENV["HIVE_FAKE_CLAUDE_FINAL_OUTPUT"] = JSON.generate(
        "type" => "stream_event",
        "event" => { "type" => "message_start", "message" => { "usage" => {} } }
      )
      ENV["HIVE_FAKE_CLAUDE_HANG"] = "10"

      result = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1, max_turns: 3,
        timeout_sec: 8, status_mode: :output_file_exists,
        expected_output: output
      ).run!

      assert_equal :ok, result.fetch(:status)
      assert result.fetch(:output_completed)
      assert_equal 0, result.dig(:usage, :output)
    end
  end

  def test_stream_token_meter_sums_claude_turns_without_double_counting_deltas
    meter = Hive::Agent::StreamTokenMeter.new(:claude)
    first_start = {
      "type" => "stream_event",
      "event" => { "type" => "message_start" }
    }
    delta = {
      "type" => "stream_event",
      "event" => { "type" => "message_delta" }
    }

    assert_equal 41, meter.observe(
      first_start, { input: 40, output: 1, cached: 30, model: "claude-test" }
    )
    assert_equal 60, meter.observe(delta, { input: 0, output: 20, cached: 0 })
    assert_equal 60, meter.observe(delta, { input: 0, output: 19, cached: 0 })
    assert_equal 70, meter.observe(
      first_start, { input: 10, output: 0, cached: 5, model: "claude-test" }
    )
    assert_equal({ input: 50, output: 20, cached: 35, model: "claude-test" }, meter.usage)
  end

  def test_stream_token_meter_keeps_observed_usage_when_terminal_total_regresses
    meter = Hive::Agent::StreamTokenMeter.new(:claude)
    stream = {
      "type" => "stream_event",
      "event" => { "type" => "message_start" }
    }

    meter.observe(stream, { input: 80, output: 20, cached: 0, model: "claude-test" })
    assert_equal 100, meter.observe(
      { "type" => "result" }, { input: 70, output: 20, cached: 0, model: "claude-test" }
    )
    assert_equal 120, meter.observe(
      { "type" => "result" }, { input: 90, output: 30, cached: 10, model: "claude-test" }
    )
    assert_equal({ input: 90, output: 30, cached: 10, model: "claude-test" }, meter.usage)
  end

  def test_stream_token_meter_accumulates_non_claude_usage_events
    meter = Hive::Agent::StreamTokenMeter.new(:codex)

    assert_equal 0, meter.observe({ "type" => "item.completed" }, nil)
    assert_equal 3, meter.observe(
      { "type" => "item.completed" },
      { input: 1, output: 2, cached: 3, model: "codex-test" }
    )
    assert_equal 6, meter.observe(
      { "type" => "item.completed" },
      { input: 0, output: 3, cached: 0 }
    )
    assert_equal({ input: 1, output: 5, cached: 3, model: "codex-test" }, meter.usage)
  end

  def test_rejects_invalid_in_flight_token_limit
    with_tmp_dir do |dir|
      error = assert_raises(ArgumentError) do
        Hive::Agent.new(
          task: make_task(dir), prompt: "x", max_budget_usd: 1,
          max_tokens: 0, timeout_sec: 5
        )
      end

      assert_equal "max_tokens must be a positive integer", error.message
    end
  end

  def test_rejects_invalid_in_flight_turn_limit
    with_tmp_dir do |dir|
      error = assert_raises(ArgumentError) do
        Hive::Agent.new(
          task: make_task(dir), prompt: "x", max_budget_usd: 1,
          max_turns: 0, timeout_sec: 5
        )
      end

      assert_equal "max_turns must be a positive integer", error.message
    end
  end

  def test_token_limit_sets_structured_error_marker_for_state_file_agents
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      agent = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1,
        max_tokens: 80, timeout_sec: 5
      )
      result = {
        resource_exhaustion: { reason: "token_limit", observed: 90, limit: 80 }
      }

      agent.handle_exit(result)

      marker = Hive::Markers.current(task.state_file)
      assert_equal :error, result[:status]
      assert_equal :error, marker.name
      assert_equal "token_limit", marker.attrs["reason"]
      assert_equal "90", marker.attrs["observed_tokens"]
      assert_equal "80", marker.attrs["max_tokens"]
    end
  end

  def test_turn_limit_sets_structured_error_marker_for_state_file_agents
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      agent = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1,
        max_turns: 3, timeout_sec: 5
      )
      result = {
        resource_exhaustion: { reason: "turn_limit", observed: 3, limit: 3 }
      }

      agent.handle_exit(result)

      marker = Hive::Markers.current(task.state_file)
      assert_equal :error, result.fetch(:status)
      assert_equal "turn_limit", marker.attrs.fetch("reason")
      assert_equal "3", marker.attrs.fetch("observed_turns")
      assert_equal "3", marker.attrs.fetch("max_turns")
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

  def test_limit_marker_uses_dated_reset_from_captured_limit_text
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      agent = Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5)
      result = {
        timed_out: false,
        exit_code: 1,
        final_message: "",
        limit_text: "You've hit your usage limit.\nTry again at Jul 18th, 2026 7:50 AM."
      }

      now = Time.utc(2026, 7, 12, 20, 0, 0)
      with_env("TZ" => "Europe/London") do
        with_replaced_singleton_method(Time, :now, -> { now }) do
          agent.handle_exit(result)
        end
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal "2026-07-18T06:51:00Z", marker.attrs.fetch("retry_after")
    end
  end

  def test_exit_code_mode_preserves_multiline_fallback_limit_text
    with_tmp_dir do |dir|
      task = make_task(dir)
      agent = Hive::Agent.new(
        task: task,
        prompt: "x",
        max_budget_usd: 1,
        timeout_sec: 5,
        status_mode: :exit_code_only
      )
      final_message = "You've hit your usage limit.\nTry again at Jul 18th, 2026 7:50 AM."
      result = { timed_out: false, exit_code: 1, final_message: final_message, limit_text: nil }

      agent.handle_exit(result)

      assert_equal :error, result.fetch(:status)
      assert_equal final_message, result.fetch(:limit_text)
      assert_equal "limits reached for claude: You've hit your usage limit.", result.fetch(:error_message)
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

  def test_claude_write_tool_event_recognizes_completed_assistant_tool_use
    with_tmp_dir do |dir|
      agent = Hive::Agent.new(task: make_task(dir), prompt: "x", max_budget_usd: 1, timeout_sec: 5)
      event = {
        "type" => "assistant",
        "message" => {
          "content" => [ { "type" => "tool_use", "name" => "Write" } ]
        }
      }

      assert agent.send(:claude_write_tool_event?, event)
    end
  end

  def test_event_stage_falls_back_to_parent_folder_for_synthetic_task_without_stage_name
    task = Struct.new(:folder).new("/tmp/project/.hive-state/stages/6-review/synthetic")
    agent = Hive::Agent.allocate
    agent.instance_variable_set(:@task, task)

    assert_equal "6-review", agent.send(:event_stage)
  end

  def test_state_file_completion_fails_closed_when_the_artifact_cannot_be_statted
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      agent = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5,
        status_mode: :state_file_marker
      )
      original = File.method(:size)

      with_replaced_singleton_method(File, :size, lambda { |path|
        raise Errno::EACCES if path == task.state_file

        original.call(path)
      }) do
        refute agent.send(:completed_state_file_artifact?)
      end
    end
  end
end
