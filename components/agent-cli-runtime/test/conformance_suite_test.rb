require_relative "test_helper"

class AgentCliRuntimeConformanceSuiteTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  VERIFIER = File.join(ROOT, "bin", "verify-candidate")

  def test_provider_inventory_is_one_internal_decision_matching_the_package
    assert_equal AgentCliRuntime::Profiles.names,
                 AgentCliRuntime::Conformance::PROVIDER_NAMES
  end

  def test_opencode_capability_inventory_matches_the_shipped_probe_contract
    assert_equal AgentCliRuntime::OpenCode::Probe::REQUIRED_RUN_FLAGS.sort,
                 AgentCliRuntime::Conformance::OPENCODE_RUN_FLAGS.sort
    assert_equal %w[--sanitize],
                 AgentCliRuntime::Conformance::OPENCODE_EXPORT_FLAGS
  end

  def test_stub_help_payloads_advertise_exactly_the_required_inventory
    run_help = AgentCliRuntime::Conformance.opencode_run_help
    export_help = AgentCliRuntime::Conformance.opencode_export_help

    assert_equal AgentCliRuntime::Conformance::OPENCODE_RUN_FLAGS,
                 run_help.split
    assert_equal AgentCliRuntime::Conformance::OPENCODE_EXPORT_FLAGS,
                 export_help.split
  end

  def test_verifier_consumes_the_shared_suite_instead_of_its_own_copies
    source = File.read(VERIFIER)

    assert_includes source,
                    'require_relative "../test/support/conformance"'
    refute_match(/%i\[claude/, source)
    refute_match(/puts "--(?:pure|model|variant|format|dir|sanitize)/, source)
  end

  def test_no_consumer_keeps_its_own_copy_of_the_decisions
    consumers = Dir.glob(File.join(ROOT, "test", "*_test.rb")) +
                [ VERIFIER ]

    consumers.each do |path|
      source = File.read(path)
      refute_match(
        /%[iwi]\[claude codex pi grok opencode\]/, source, path
      )
      refute_match(
        /--(?:model --variant|pure --model)[^"\n]*--auto/, source, path
      )
    end
  end
end
