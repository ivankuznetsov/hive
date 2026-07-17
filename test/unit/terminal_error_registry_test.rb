require "test_helper"
require "hive/terminal_error_registry"

class TerminalErrorRegistryTest < Minitest::Test
  def test_every_entry_has_only_diagnostic_fields_and_coordinator_route
    Hive::TerminalErrorRegistry.codes.each do |code|
      entry = Hive::TerminalErrorRegistry.fetch(code)
      assert_equal code, entry.code
      assert_equal "coordinator", entry.route
      refute_empty entry.guidance
      assert_operator entry.extract("message" => "failure").length, :<=,
                      Hive::DiagnosticEvidence::RETRY_EVIDENCE_MAX_ENTRIES
    end
  end

  def test_unknown_and_auth_input_normalize_without_changing_policy
    unknown = Hive::TerminalErrorRegistry.diagnose(
      code: "future_external_code", payload: { "message" => "safe context" }
    )
    auth = Hive::TerminalErrorRegistry.diagnose(
      code: "implementer_failed",
      payload: { "provider" => "codex", "tool" => "honeycomb", "message" => "401 missing bearer auth" }
    )

    assert_equal "unknown", unknown.fetch("code")
    assert_equal "codex_auth", auth.fetch("code")
    assert_equal "coordinator", unknown.fetch("route")
    assert auth.fetch("evidence").any? { |item| item["value"].include?("honeycomb") }
  end

  def test_invalid_or_policy_bearing_declarations_are_rejected
    valid = {
      code: "sample", extractor: ->(_payload) { [] },
      guidance: "Repair it.", route: "coordinator"
    }
    assert Hive::TerminalErrorRegistry.validate_declaration!(valid)

    %i[code extractor guidance].each do |field|
      declaration = valid.dup
      declaration.delete(field)
      assert_raises(Hive::TerminalErrorRegistry::InvalidDeclaration) do
        Hive::TerminalErrorRegistry.validate_declaration!(declaration)
      end
    end
    assert_raises(Hive::TerminalErrorRegistry::InvalidDeclaration) do
      Hive::TerminalErrorRegistry.validate_declaration!(valid.merge(route: "direct"))
    end
    %i[retryable schedule max_retries provider_override dispatch quarantine].each do |field|
      assert_raises(Hive::TerminalErrorRegistry::InvalidDeclaration) do
        Hive::TerminalErrorRegistry.validate_declaration!(valid.merge(field => true))
      end
    end
  end

  def test_static_terminal_producer_reasons_are_declared
    roots = %w[
      lib/hive/stages lib/hive/agent.rb lib/hive/claude_launcher.rb
      lib/hive/reviewers/agent.rb lib/hive/daemon/stale_agent_healer.rb
      lib/hive/daemon/recoverable_error_healer.rb
    ]
    files = roots.flat_map { |root| File.directory?(root) ? Dir[File.join(root, "**/*.rb")] : [ root ] }
    emitted = files.flat_map do |path|
      File.read(path).scan(/reason:\s*"([a-z0-9_]+)"/).flatten
    end.uniq

    missing = emitted - Hive::TerminalErrorRegistry.codes
    assert_empty missing, "terminal producer reasons missing registry declarations: #{missing.sort.join(', ')}"
  end
end
