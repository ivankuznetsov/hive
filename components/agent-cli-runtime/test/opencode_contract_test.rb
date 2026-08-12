require_relative "test_helper"

class AgentCliRuntimeOpenCodeContractTest < Minitest::Test
  FIXTURE_ROOT = File.expand_path("fixtures/opencode/v1.18.16", __dir__)
  VALID_RUN_FIXTURES = %w[
    run-one-step.jsonl
    run-multi-step.jsonl
    run-tool-and-unknown.jsonl
    run-auth-error.jsonl
    run-configuration-error.jsonl
  ].freeze

  def test_help_fixture_pins_required_non_interactive_capabilities
    help = fixture("run-help.txt")

    assert_includes help, "opencode run [message..]"
    %w[--pure --model --format --dir --variant --auto].each do |flag|
      assert_includes help, flag
    end
    assert_includes help, "provider/model"
    assert_includes fixture("export-help.txt"), "--sanitize"
  end

  def test_local_inventory_fixtures_are_sanitized_and_exact
    models = fixture("models.txt").lines(chomp: true)

    assert_includes models, "anthropic/claude-sonnet-4-5"
    assert_includes models, "opencode/deepseek-v4-flash-free"
    assert models.all? { |route| route.match?(%r{\A[^/\s]+/[^\s]+\z}) }
    assert_equal %w[anthropic opencode], fixture("auth-list.txt").lines(chomp: true)
  end

  def test_valid_jsonl_fixtures_pin_session_and_required_part_shapes
    VALID_RUN_FIXTURES.each do |name|
      events = jsonl(name)

      refute_empty events, name
      session_ids = events.filter_map { |event| event["sessionID"] }.uniq
      assert_equal 1, session_ids.length, name
      events.each { |event| validate_event!(event, fixture: name) }
    end
  end

  def test_multi_step_fixture_keeps_terminal_message_separate
    events = jsonl("run-multi-step.jsonl")
    finishes = events.select { |event| event["type"] == "step_finish" }
    texts = events.select { |event| event["type"] == "text" }

    assert_equal %w[msg_assistant_1 msg_assistant_2],
                 finishes.map { |event| event.dig("part", "messageID") }
    final_text = texts.filter_map do |event|
      event.dig("part", "text") if
        event.dig("part", "messageID") == "msg_assistant_2"
    end.join
    assert_equal "Final answer.", final_text
    refute finishes.last.dig("part").key?("providerID")
    refute finishes.last.dig("part").key?("modelID")
  end

  def test_usage_fixture_preserves_zero_values_and_cache_directions
    terminal = jsonl("run-one-step.jsonl").find do |event|
      event["type"] == "step_finish"
    end.fetch("part")

    assert_equal 0, terminal.dig("tokens", "reasoning")
    assert_equal 0, terminal.dig("tokens", "cache", "write")
    assert_equal 2, terminal.dig("tokens", "cache", "read")
    assert_equal 0.0, terminal.fetch("cost")
  end

  def test_sanitized_exports_pin_actual_route_and_message_correlation
    same = json("session-export-matching.json")
    fallback = json("session-export-fallback.json")

    assert_export(same, provider: "anthropic", model: "claude-sonnet-4-5")
    assert_export(fallback, provider: "openrouter", model: "anthropic/claude-sonnet-4")
    assert_match(/\A\[redacted:/, same.dig("info", "directory"))
    assert_match(/\A\[redacted:/,
                 same.dig("messages", 1, "parts", 1, "text"))
  end

  def test_intentionally_malformed_fixtures_fail_for_the_named_contract
    assert_raises(JSON::ParserError) { jsonl("run-malformed-json.jsonl") }

    terminal = jsonl("run-malformed-terminal.jsonl").last
    error = assert_raises(KeyError) do
      validate_event!(terminal, fixture: "run-malformed-terminal.jsonl")
    end
    assert_match(/tokens/, error.message)
  end

  def test_fixture_corpus_contains_no_machine_or_secret_material
    Dir.glob(File.join(FIXTURE_ROOT, "*"), File::FNM_DOTMATCH).each do |path|
      next unless File.file?(path)

      contents = File.binread(path)
      refute_includes contents, Dir.home, path
      refute_match(/(?:sk-[A-Za-z0-9]{16,}|api[_-]?key\s*[:=]\s*\S+)/i,
                   contents, path)
      refute_match(%r{/home/|/Users/}, contents, path)
    end
  end

  private

  def fixture(name)
    File.read(File.join(FIXTURE_ROOT, name))
  end

  def json(name)
    JSON.parse(fixture(name))
  end

  def jsonl(name)
    fixture(name).lines(chomp: true).reject(&:empty?).map do |line|
      JSON.parse(line)
    end
  end

  def validate_event!(event, fixture:)
    assert_kind_of Hash, event, fixture
    assert_kind_of String, event.fetch("type"), fixture
    assert_kind_of String, event.fetch("sessionID"), fixture
    return if event["type"] == "error"

    part = event.fetch("part")
    assert_kind_of Hash, part, fixture
    assert_equal event.fetch("sessionID"), part.fetch("sessionID"), fixture
    assert_kind_of String, part.fetch("messageID"), fixture

    case event["type"]
    when "text", "reasoning"
      assert_kind_of String, part.fetch("text"), fixture
      assert part.dig("time", "end"), fixture
    when "step_finish"
      assert_kind_of String, part.fetch("reason"), fixture
      assert_kind_of Numeric, part.fetch("cost"), fixture
      tokens = part.fetch("tokens")
      %w[input output reasoning].each do |key|
        assert_kind_of Numeric, tokens.fetch(key), "#{fixture}: tokens.#{key}"
      end
      %w[read write].each do |key|
        assert_kind_of Numeric, tokens.fetch("cache").fetch(key),
                       "#{fixture}: tokens.cache.#{key}"
      end
    when "step_start", "tool_use"
      # Their required identity fields were asserted above. Detailed tool
      # payloads are deliberately opaque to the runtime parser.
    else
      # Additive event types are accepted by the contract and summarized by
      # the strict parser rather than interpreted.
    end
  end

  def assert_export(export, provider:, model:)
    assistant = export.fetch("messages").find do |message|
      message.dig("info", "id") == "msg_assistant_final"
    end

    refute_nil assistant
    assert_equal export.dig("info", "id"), assistant.dig("info", "sessionID")
    assert_equal "assistant", assistant.dig("info", "role")
    assert_equal provider, assistant.dig("info", "providerID")
    assert_equal model, assistant.dig("info", "modelID")
    assert assistant.dig("info", "tokens").key?("input")
    assert assistant.dig("info", "tokens", "cache").key?("read")
    assert assistant.dig("info", "tokens", "cache").key?("write")
    assert assistant.dig("parts").any? do |part|
      part["type"] == "step-finish" &&
        part["messageID"] == "msg_assistant_final"
    end
  end
end
