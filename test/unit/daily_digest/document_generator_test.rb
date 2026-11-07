require "test_helper"
require "hive/daily_digest/document_generator"

class DailyDigestDocumentGeneratorTest < Minitest::Test
  include HiveTestHelper

  def test_global_digest_route_reaches_the_compiled_invocation
    with_tmp_global_config do
      Hive::Config.update_global_config! do |data|
        data["daily_digest"] = { "agent" => "opencode", "model" => "opencode-go/deepseek-v4.1-flash" }
      end
      captured = nil
      generator = Hive::DailyDigest::DocumentGenerator.new
      prompt = nil
      generator.define_singleton_method(:capture) do |invocation, _profile|
        captured = invocation.argv
        prompt = invocation.stdin_data.to_s + invocation.argv.join(" ")
        raise Hive::AgentError, "test stops before launch"
      end
      assert_raises(Hive::AgentError) { generator.generate({}) }
      assert_includes captured, "opencode-go/deepseek-v4.1-flash"
      assert_includes captured, "--model"
      assert_includes captured, "run"
      assert_includes prompt, "morning briefing"
      assert_includes prompt, "```mermaid"
      assert_includes prompt, "<prdigest_facts>"
    end
  end

  def test_fallback_agents_run_in_order_and_every_failure_is_reported
    config = Hive::Config::DEFAULTS.merge("daily_digest" => {
      "agent" => "opencode", "model" => "opencode-go/deepseek-v4.1-flash",
      "fallback_agents" => [ { "agent" => "codex", "model" => "gpt-6-astra", "effort" => "medium" },
                             { "agent" => "claude" } ]
    })
    generator = Hive::DailyDigest::DocumentGenerator.new(config_loader: -> { config })
    launches = []
    generator.define_singleton_method(:capture) do |invocation, profile|
      launches << [ profile.name.to_s, invocation.argv ]
      raise Hive::AgentError, "#{profile.name} down" unless profile.name.to_s == "claude"

      { type: "result", subtype: "success", is_error: false, result: "Fallback document" }.to_json
    end
    assert_equal "Fallback document", generator.generate({})
    assert_equal %w[opencode codex claude], launches.map(&:first)
    assert_includes launches[1].last, "gpt-6-astra"
    assert_includes launches[1].last, "model_reasoning_effort=medium"

    generator.define_singleton_method(:capture) { |_, profile| raise Hive::AgentError, "#{profile.name} down" }
    error = assert_raises(Hive::AgentError) { generator.generate({}) }
    assert_includes error.message, "opencode opencode-go/deepseek-v4.1-flash: opencode down"
    assert_includes error.message, "codex gpt-6-astra: codex down"
    assert_includes error.message, "claude: claude down"
  end

  def test_opencode_document_uses_structured_text_and_rejects_truncation
    profile = Hive::AgentProfiles.lookup("opencode", cfg: Hive::Config::DEFAULTS)
    generator = Hive::DailyDigest::DocumentGenerator.new
    events = [
      { type: "step_start", part: { type: "step-start" } },
      { type: "text", part: { type: "text", text: "Tasks now cancel cleanly." } },
      { type: "step_finish", part: { type: "step-finish", reason: "stop", cost: 0,
                                    tokens: { input: 10, output: 5, reasoning: 0, cache: { read: 0, write: 0 } } } }
    ]
    events.each_with_index do |event, index|
      event[:sessionID] = "digest-session"
      event[:part].merge!(sessionID: "digest-session", messageID: "digest-message", id: "part-#{index}")
    end
    output = events.map(&:to_json).join("\n")
    assert_equal "Tasks now cancel cleanly.", generator.send(:final_message, profile, output)
    events.last[:part][:reason] = "length"
    assert_nil generator.send(:final_message, profile, events.map(&:to_json).join("\n"))
  end

  def test_launcher_output_cannot_become_a_document
    profile = Hive::AgentProfiles.lookup("claude", cfg: Hive::Config::DEFAULTS)
    generator = Hive::DailyDigest::DocumentGenerator.new
    assert_nil generator.send(:final_message, profile, "mise tools: opencode@latest\n")
    message = { type: "result", subtype: "success", is_error: false, result: "The change now saves snapshots." }.to_json
    assert_equal "The change now saves snapshots.", generator.send(:final_message, profile, message)
  end
  def test_capture_supplies_stdin_and_preserves_the_complete_output
    with_tmp_global_config do
      invocation = Struct.new(:argv, :stdin_data).new(
        [ RbConfig.ruby, "-e", "print STDIN.read.upcase" ], "recent changes"
      )
      profile = Struct.new(:subscription_environment).new({})
      assert_equal "RECENT CHANGES", Hive::DailyDigest::DocumentGenerator.new.send(:capture, invocation, profile)
    end
  end

  def test_capture_reports_failed_process_and_bounds_its_diagnostic
    with_tmp_global_config do
      invocation = Struct.new(:argv, :stdin_data).new(
        [ RbConfig.ruby, "-e", 'STDERR.write("failure " * 500); exit 7' ], ""
      )
      profile = Struct.new(:subscription_environment).new({})
      error = assert_raises(Hive::AgentError) do
        Hive::DailyDigest::DocumentGenerator.new.send(:capture, invocation, profile)
      end
      assert_includes error.message, "exit 7"
      assert_operator error.message.length, :<=, 2_100
    end
  end

  def test_failed_opencode_run_reports_the_provider_error_not_the_event_shape
    with_tmp_global_config do
      event = {
        type: "error", sessionID: "ses_digest",
        error: { type: "provider.auth", message: "This API key has expired.", status: 401 }
      }.to_json
      invocation = Struct.new(:argv, :stdin_data).new(
        [ RbConfig.ruby, "-e", "STDERR.write('mise noise'); puts #{event.inspect}; exit 1" ], ""
      )
      profile = Hive::AgentProfiles.lookup("opencode", cfg: Hive::Config::DEFAULTS)
      error = assert_raises(Hive::AgentError) do
        Hive::DailyDigest::DocumentGenerator.new.send(:capture, invocation, profile)
      end
      assert_includes error.message, "exit 1"
      assert_includes error.message, "This API key has expired."
      refute_includes error.message, "mise noise"
    end
  end

  def test_capture_kills_an_agent_that_exceeds_its_deadline
    with_tmp_global_config do
      invocation = Struct.new(:argv, :stdin_data).new([ RbConfig.ruby, "-e", "sleep 60" ], "")
      profile = Struct.new(:subscription_environment).new({})
      error = assert_raises(Hive::AgentError) do
        Hive::DailyDigest::DocumentGenerator.new(timeout_sec: 0).send(:capture, invocation, profile)
      end
      assert_includes error.message, "time or output limit"
    end
  end
  def test_generated_document_redacts_secrets_and_rejects_blank_completion
    config = Hive::Config::DEFAULTS.merge("daily_digest" => { "agent" => "claude" })
    generator = Hive::DailyDigest::DocumentGenerator.new(config_loader: -> { config })
    token = "ghp_#{'u' * 36}"
    output = { type: "result", subtype: "success", is_error: false, result: "Changes: #{token}" }.to_json
    generator.define_singleton_method(:capture) { |*_args| output }
    assert_equal "Changes: [REDACTED:github_token]", generator.generate({})
    output = { type: "result", subtype: "success", is_error: false, result: " " }.to_json
    error = assert_raises(Hive::AgentError) { generator.generate({}) }
    assert_includes error.message, "complete document"
  end
  def test_timeout_cleanup_preserves_the_error_if_the_agent_already_exited
    with_tmp_global_config do
      invocation = Struct.new(:argv, :stdin_data).new([ RbConfig.ruby, "-e", "exit 0" ], "")
      profile = Struct.new(:subscription_environment).new({})
      wait = Process.method(:waitpid2)
      reaped = ->(pid, _flags) { wait.call(pid); nil }
      with_replaced_singleton_method(Process, :waitpid2, reaped) do
        error = assert_raises(Hive::AgentError) do
          Hive::DailyDigest::DocumentGenerator.new(timeout_sec: 0).send(:capture, invocation, profile)
        end
        assert_includes error.message, "time or output limit"
      end
    end
  end
end
