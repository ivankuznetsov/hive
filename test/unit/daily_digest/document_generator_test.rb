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
      generator.define_singleton_method(:capture) do |invocation, _profile|
        captured = invocation.argv
        raise Hive::AgentError, "test stops before launch"
      end
      assert_raises(Hive::AgentError) { generator.generate({}) }
      assert_includes captured, "opencode-go/deepseek-v4.1-flash"
      assert_includes captured, "--model"
      assert_includes captured, "run"
    end
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
end
