require_relative "test_helper"

class AgentCliRuntimeMuseProfileTest < Minitest::Test
  def muse
    AgentCliRuntime::Profiles.fetch(:muse)
  end

  def test_muse_is_the_last_built_in_provider
    assert_equal %i[claude codex pi grok opencode muse],
                 AgentCliRuntime::Profiles.names
  end

  def test_compile_uses_exec_with_prompt_file_stdin_and_json_stream
    invocation = AgentCliRuntime.compile(
      AgentCliRuntime::Request.new(
        profile: :muse, prompt: "implement it",
        model: "muse-fake-1", effort: "ultra"
      )
    )

    assert_equal(
      [
        "muse", "exec", "--prompt-file=/dev/stdin", "--yolo",
        "--model", "muse-fake-1",
        "--reasoning-effort", "ultra", "--json", "--disable-reminders",
        "--disable-request-user-input", "--no-session-log"
      ],
      invocation.argv
    )
    assert_equal "implement it", invocation.stdin_data
    assert_equal :muse, invocation.provider
  end

  def test_compile_scoped_permission_modes_keep_the_sandbox
    write = AgentCliRuntime.compile(
      AgentCliRuntime::Request.new(
        profile: :muse, prompt: "x", permission_mode: "workspace-write"
      )
    ).argv
    assert_includes write, "--trust-workspace"
    assert_equal "never", write[write.index("--approval-mode") + 1]
    refute_includes write, "--yolo"
    refute_includes write, "--disable-sandbox"

    read_only = AgentCliRuntime.compile(
      AgentCliRuntime::Request.new(
        profile: :muse, prompt: "x", permission_mode: "read-only"
      )
    ).argv
    assert_includes read_only, "--disable-write"
    assert_includes read_only, "--disable-shell"
  end

  def test_binary_override_keys
    assert_equal "/opt/muse", muse.bin(env: { "HIVE_MUSE_BIN" => "/opt/muse" })
    assert_equal "/opt/muse2",
                 muse.bin(env: { "AGENT_CLI_RUNTIME_MUSE_BIN" => "/opt/muse2" })
    assert_equal "muse", muse.bin(env: {})
  end

  def test_version_check_accepts_one_version_printed_in_two_forms
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "muse")
      write_executable(bin, <<~RUBY)
        #!/usr/bin/env ruby
        puts "Muse Code 1.4.14 (1.4.14-R7309.1)"
      RUBY
      profile = AgentCliRuntime::Profile.new(
        name: :muse, bin_default: bin, headless_flag: "exec",
        version_flag: "--version", min_version: "1.4.14"
      )

      assert_equal "1.4.14", profile.check_version!
    end
  end

  def test_version_check_still_rejects_distinct_numeric_cores
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "muse")
      profile = AgentCliRuntime::Profile.new(
        name: :muse, bin_default: bin, headless_flag: "exec",
        version_flag: "--version", min_version: "1.4.14"
      )

      write_executable(bin, "#!/bin/sh\necho 'Muse Code 1.4.14 (1.5.0-R1)'\n")
      error = assert_raises(AgentCliRuntime::VersionError) { profile.check_version! }
      assert_match(/ambiguous/, error.message)

      write_executable(bin, "#!/bin/sh\necho 'Muse Code 1.3.0 (1.3.0-R1)'\n")
      error = assert_raises(AgentCliRuntime::VersionError) { profile.check_version! }
      assert_match(/below minimum|1\.3\.0/, error.message)
    end
  end

  def test_configuration_directory_honors_xdg_config_home
    assert_equal "/xdg/muse",
                 muse.configuration_directory(env: { "XDG_CONFIG_HOME" => "/xdg" })
    assert_equal "/home/u/.config/muse",
                 muse.configuration_directory(home: "/home/u", env: {})
    error = assert_raises(ArgumentError) do
      muse.configuration_directory(env: { "XDG_CONFIG_HOME" => "relative" })
    end
    assert_match(/must be absolute/, error.message)
  end

  def test_data_directory_honors_xdg_data_home
    profiles = AgentCliRuntime::Profiles
    assert_equal "/data/muse",
                 profiles.muse_data_directory(
                   home: "/home/u", env: { "XDG_DATA_HOME" => "/data" }
                 )
    assert_equal "/home/u/.local/share/muse",
                 profiles.muse_data_directory(home: "/home/u", env: {})
    error = assert_raises(ArgumentError) do
      profiles.muse_data_directory(home: nil, env: { "XDG_DATA_HOME" => "rel" })
    end
    assert_match(/must be absolute/, error.message)
  end

  def test_auth_probe_accepts_env_key_and_xdg_auth_file
    assert_equal :configured,
                 muse.auth_configuration(env: { "META_API_KEY" => "k" }).status

    Dir.mktmpdir do |dir|
      auth_dir = File.join(dir, "muse")
      FileUtils.mkdir_p(auth_dir)
      env = { "XDG_CONFIG_HOME" => dir }

      assert_equal :missing, muse.auth_configuration(env:).status
      File.write(File.join(auth_dir, "auth.json"), '{"token":"configured"}')
      assert_equal :configured, muse.auth_configuration(env:).status
    end
  end

  def test_usage_extraction_sums_the_per_model_breakdown
    usage = AgentCliRuntime.extract_usage(
      :muse,
      {
        "payload_type" => "run.usage",
        "payload" => {
          "models" => [
            { "model" => "muse-a", "input_tokens" => 10, "output_tokens" => 4,
              "cached_tokens" => 3, "reasoning_tokens" => 2 },
            { "model" => "muse-a", "input_tokens" => 5, "output_tokens" => 6,
              "cached_tokens" => 1, "reasoning_tokens" => 0 }
          ]
        }
      }
    )

    assert_equal 15, usage[:input]
    assert_equal 10, usage[:output]
    assert_equal 4, usage[:cached]
    assert_equal 2, usage[:reasoning]
    assert_equal "muse-a", usage[:model]
    assert_nil usage[:input_includes_cache_read]
  end

  def test_usage_extraction_ignores_non_usage_events
    assert_nil AgentCliRuntime.extract_usage(
      :muse, { "payload_type" => "run.output.delta", "payload" => {} }
    )
  end

  def test_usage_extraction_edge_shapes
    usage = AgentCliRuntime.extract_usage(
      :muse,
      {
        "payload_type" => "run.usage",
        "payload" => {
          "models" => [
            { "model" => "muse-a", "input_tokens" => 1, "output_tokens" => 2 },
            { "model" => "muse-b", "input_tokens" => 3, "output_tokens" => 4 },
            "not-a-hash"
          ]
        }
      }
    )
    assert_equal 4, usage[:input]
    assert_equal 6, usage[:output]
    assert_nil usage[:cached], "absent breakdown keys stay unknown, not zero"
    assert_nil usage[:reasoning]
    assert_nil usage[:model], "several models have no single model name"

    [ { "models" => {} }, { "models" => [] }, { "models" => [ 1 ] }, "payload" ].each do |payload|
      assert_nil AgentCliRuntime.extract_usage(
        :muse, { "payload_type" => "run.usage", "payload" => payload }
      ), payload.inspect
    end
  end

  def test_error_extraction_uses_only_run_terminal_failures
    failure = AgentCliRuntime.extract_provider_error(
      :muse,
      {
        "payload_type" => "run.terminal.failed",
        "payload" => { "terminal" => "failed", "reason" => "429: rate limit" }
      }
    )
    assert_equal :rate_limited, failure[:kind]
    assert_equal 429, failure[:status_code]

    # The exact Muse subscription wall observed in the field must classify as
    # a provider limit, so Hive retries it hourly instead of parking it.
    quota = AgentCliRuntime.extract_provider_error(
      :muse,
      {
        "payload_type" => "run.terminal.failed",
        "payload" => {
          "terminal" => "failed",
          "reason" => "API error 429 [request_id=e02acc48-e483-46c6-8b33-23ab76b8c497]: " \
                      "Subscription quota exhausted. Your usage window resets at " \
                      "2026-11-16T00:00:00Z. (rate_limit_error)"
        }
      }
    )
    assert_equal :provider_limit, quota[:kind]
    assert_match(/Subscription quota exhausted/, quota[:message])

    assert_nil AgentCliRuntime.extract_provider_error(
      :muse,
      {
        "payload_type" => "run.terminal.completed",
        "payload" => { "terminal" => "completed", "text" => "done" }
      }
    )
    # Reminder child tasks fail on otherwise successful runs; they are not
    # provider errors.
    assert_nil AgentCliRuntime.extract_provider_error(
      :muse,
      {
        "payload_type" => "task.lifecycle.failed",
        "payload" => { "event" => { "reason" => "reminder failed" } }
      }
    )
  end
end
