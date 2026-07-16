require "test_helper"
require "hive/conditions/registry"

class ConditionsRegistryTest < Minitest::Test
  def test_default_registry_contains_all_condition_vocabulary_with_increment_one_activation
    registry = Hive::Conditions::Registry.default

    assert_equal %w[
      AgentHealthy ChangesPresent AwaitingHuman BranchPushed ArtifactCurrent BabysitterActive Merged
    ], registry.names
    assert registry.fetch("AgentHealthy").authoritative_for?("4-execute")
    assert registry.fetch("ChangesPresent").authoritative_for?("4-execute")
    assert registry.fetch("AwaitingHuman").authoritative_for?("4-execute")
    %w[BranchPushed ArtifactCurrent BabysitterActive Merged].each do |name|
      refute registry.fetch(name).authoritative_for?("4-execute")
    end
    assert_equal :inhibitor, registry.fetch("AwaitingHuman").gate_role
    assert_equal "execute_outcome", registry.fetch("ChangesPresent").supersession_family
    assert_equal "execute_outcome", registry.fetch("AwaitingHuman").supersession_family
  end

  def test_registry_rejects_duplicate_names_families_and_invalid_metadata
    registry = Hive::Conditions::Registry.new
    registry.register("One", family: "one", scope: :task,
                      allowed_evidence: [ :journal_event ], gate_role: :informational)
    assert_raises(Hive::Conditions::RegistryError) do
      registry.register("One", family: "two", scope: :task,
                        allowed_evidence: [ :journal_event ], gate_role: :informational)
    end
    assert_raises(Hive::Conditions::RegistryError) do
      registry.register("Two", family: "one", scope: :task,
                        allowed_evidence: [ :journal_event ], gate_role: :informational)
    end
    assert_raises(Hive::Conditions::RegistryError) do
      registry.register("Two", family: "two", scope: :unknown,
                        allowed_evidence: [ :journal_event ], gate_role: :informational)
    end
    assert_raises(Hive::Conditions::RegistryError) { registry.fetch("missing") }
  end

  def test_definition_round_trips_as_wire_metadata
    definition = Hive::Conditions::Registry.default.fetch("Merged")
    assert_equal "pull_request", definition.to_h.fetch("scope")
    assert_equal [ "pull_request", "journal_event" ], definition.to_h.fetch("allowed_evidence")
    assert_equal [ "finalize_to_archive" ], definition.to_h.fetch("default_transitions")
  end
end
