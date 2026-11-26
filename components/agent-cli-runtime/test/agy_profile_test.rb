require_relative "test_helper"

class AgentCliRuntimeAgyProfileTest < Minitest::Test
  def agy
    AgentCliRuntime::Profiles.fetch(:agy)
  end

  def test_agy_is_the_last_built_in_provider
    assert_equal %i[claude codex pi grok opencode muse agy],
                 AgentCliRuntime::Profiles.names
  end

  def test_compile_uses_stdin_text_input_and_stream_json_output
    invocation = AgentCliRuntime.compile(
      AgentCliRuntime::Request.new(
        profile: :agy, prompt: "implement it",
        add_dirs: [ "/tmp/extra" ],
        model: "gemini-4-neon-xhigh", effort: "xhigh"
      )
    )

    assert_equal(
      [
        "agy", "--input-format=text", "--dangerously-skip-permissions",
        "--add-dir", "/tmp/extra",
        "--model", "gemini-4-neon-xhigh", "--effort", "xhigh",
        "--output-format", "stream-json"
      ],
      invocation.argv
    )
    assert_equal "implement it", invocation.stdin_data
    assert_equal :agy, invocation.provider
    assert_equal "antigravity-cli/v1", invocation.launcher_identity
  end

  def test_compile_rejects_unsupported_sandbox_permission_modes
    %w[workspace-write read-only].each do |mode|
      error = assert_raises(AgentCliRuntime::UnsupportedCapability) do
        AgentCliRuntime.compile(
          AgentCliRuntime::Request.new(
            profile: :agy, prompt: "x", permission_mode: mode
          )
        )
      end
      assert_equal :agy, error.evidence.provider
      refute error.evidence.supported
    end
  end

  def test_binary_override_keys
    assert_equal "/opt/agy", agy.bin(env: { "HIVE_AGY_BIN" => "/opt/agy" })
    assert_equal "/opt/agy2",
                 agy.bin(env: { "AGENT_CLI_RUNTIME_AGY_BIN" => "/opt/agy2" })
    assert_equal "agy", agy.bin(env: {})
  end

  def test_version_check_parses_plain_semver_and_enforces_minimum
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "agy")
      write_executable(bin, "#!/usr/bin/env ruby\nputs '1.5.17'\n")
      profile = AgentCliRuntime::Profile.new(
        name: :agy, bin_default: bin, headless_flag: "--input-format=text",
        version_flag: "--version", min_version: "1.5.17"
      )

      assert_equal "1.5.17", profile.check_version!

      write_executable(bin, "#!/usr/bin/env ruby\nputs '1.4.0'\n")
      assert_raises(AgentCliRuntime::VersionError) { profile.check_version! }
    end
  end

  def test_configuration_and_state_directories_follow_home
    assert_equal "/home/u/.gemini/config",
                 agy.configuration_directory(home: "/home/u", env: {})
    assert_equal "/home/u/.gemini/antigravity-cli",
                 AgentCliRuntime::Profiles.agy_state_directory(home: "/home/u", env: {})
    assert_equal "/home/u/.gemini/antigravity-cli/antigravity-oauth-token",
                 AgentCliRuntime::Profiles.agy_auth_path(home: "/home/u", env: {})
    assert_nil agy.configuration_environment_key
  end

  def test_auth_probe_accepts_env_keys_and_binary_or_text_oauth_token_file
    %w[GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_APPLICATION_CREDENTIALS].each do |key|
      assert_equal :configured,
                   agy.auth_configuration(env: { key => "configured" }).status, key
    end

    Dir.mktmpdir do |home|
      token_path = AgentCliRuntime::Profiles.agy_auth_path(home: home, env: {})
      FileUtils.mkdir_p(File.dirname(token_path))

      assert_equal :missing, agy.auth_configuration(home: home, env: {}).status

      File.write(token_path, "{}")
      assert_equal :missing, agy.auth_configuration(home: home, env: {}).status

      # OAuth fallback token files may contain raw binary bytes; probe must not
      # fail on non-UTF-8 content.
      File.binwrite(token_path, "\xFF\xFE\x00token-bytes".b)
      assert_equal :configured, agy.auth_configuration(home: home, env: {}).status
    end
  end

  def test_usage_extraction_reads_step_update_and_result_usage
    step_usage = AgentCliRuntime.extract_usage(
      :agy,
      {
        "event" => "step_update",
        "step_update" => {
          "state" => "DONE",
          "step_type" => "agent_response",
          "usage" => {
            "input_tokens" => 11813,
            "output_tokens" => 41,
            "thinking_tokens" => 39,
            "cache_read_tokens" => 100,
            "total_tokens" => 11854
          }
        }
      }
    )
    assert_equal 11813, step_usage[:input]
    assert_equal 41, step_usage[:output]
    assert_equal 39, step_usage[:reasoning]
    assert_equal 100, step_usage[:cache_read]
    assert_equal true, step_usage[:output_includes_reasoning]
    assert_nil step_usage[:input_includes_cache_read]
    assert_nil step_usage[:provider_reported_cost]

    result_usage = AgentCliRuntime.extract_usage(
      :agy,
      {
        "event" => "result",
        "result" => {
          "status" => "SUCCESS",
          "num_turns" => 1,
          "usage" => {
            "input_tokens" => 12630,
            "output_tokens" => 1,
            "thinking_tokens" => 0,
            "cache_read_tokens" => 0,
            "total_tokens" => 12631
          }
        }
      }
    )
    assert_equal 12630, result_usage[:input]
    assert_equal 1, result_usage[:output]
    assert_equal 0, result_usage[:reasoning]
    assert_equal 0, result_usage[:cache_read]
    assert_equal true, result_usage[:output_includes_reasoning]
  end

  def test_usage_extraction_ignores_init_and_zero_turn_error_results
    assert_nil AgentCliRuntime.extract_usage(
      :agy, { "event" => "init", "init" => { "model" => "gemini-4-neon-xhigh" } }
    )
    assert_nil AgentCliRuntime.extract_usage(
      :agy,
      {
        "event" => "result",
        "result" => {
          "status" => "ERROR",
          "error" => "empty prompt",
          "num_turns" => 0,
          "usage" => {
            "input_tokens" => 0, "output_tokens" => 0,
            "thinking_tokens" => 0, "cache_read_tokens" => 0, "total_tokens" => 0
          }
        }
      }
    )
  end

  def test_error_extraction_reads_non_success_result_envelopes
    failure = AgentCliRuntime.extract_provider_error(
      :agy,
      {
        "event" => "result",
        "result" => { "status" => "ERROR", "error" => "429: rate limit exceeded" }
      }
    )
    assert_equal :rate_limited, failure[:kind]
    assert_equal 429, failure[:status_code]

    canceled = AgentCliRuntime.extract_provider_error(
      :agy,
      {
        "event" => "result",
        "result" => { "status" => "CANCELED", "error" => "" }
      }
    )
    assert_equal :provider_error, canceled[:kind]
    assert_equal "agy run canceled", canceled[:message]

    assert_nil AgentCliRuntime.extract_provider_error(
      :agy,
      {
        "event" => "result",
        "result" => { "status" => "SUCCESS", "response" => "429: rate limit in prose" }
      }
    )
  end
end
