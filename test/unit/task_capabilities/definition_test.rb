require "test_helper"
require "hive/task_capabilities/definition"

class TaskCapabilitiesDefinitionTest < Minitest::Test
  include HiveTestHelper
  Definition = Hive::TaskCapabilities::Definition

  def definition(value = {}, package_root: nil, **changes)
    Definition.new({ "id" => "links", "kind" => "verification", "stages" => [ "review" ] }.merge(value).merge(changes),
                   stages: Hive::Workflows::Coding::DESCRIPTOR.stages, source: "/tmp/project.yml", package_root: package_root)
  end

  def test_round_trip_preserves_identity_and_freezes_nested_values
    value = definition("actor" => { "profile" => "claude", "provider" => "anthropic", "model" => "model", "effort" => "high" },
                       "permissions" => "read-only", "budget_usd" => 2, "timeout_sec" => 3,
                       "checks" => [ { "id" => "links", "kind" => "behavior", "claim" => "Links work", "provider" => "ci" } ])
    assert_equal "/tmp/project.yml", value.source
    assert value.to_h.frozen?
    assert value.to_h.fetch("actor").frozen?
    assert_equal 64, value.fingerprint.length
    assert_equal value.fingerprint, definition(value.to_h).fingerprint
    assert_equal "links", value.id
  end

  def test_guidance_is_attached_in_stage_order_and_instruction_is_resolved
    value = definition("kind" => "guidance", "stages" => %w[execute plan], "skill" => "/design")
    assert_equal %w[plan execute], value.stages
    with_tmp_dir do |dir|
      path = File.join(dir, "guide.md")
      File.write(path, "Guide")
      value = definition({ "instruction" => path }, package_root: dir)
      assert_equal path, value.instruction_path
      assert_equal Digest::SHA256.hexdigest("Guide"), value.data.fetch("instruction_digest")
      refute value.data.fetch("instruction").start_with?("/")
      assert_raises(Hive::ConfigError) { definition(value.data.merge("instruction_digest" => "changed")) }
      assert_raises(Hive::ConfigError) { definition({ "instruction" => path }, package_root: File.join(dir, "other")) }
    end
    assert_raises(Hive::ConfigError) { definition("instruction" => "/missing-guide.md") }
  end

  def test_invalid_definition_shapes_are_rejected
    [ { "id" => "Bad" }, { "kind" => "stage" }, { "unknown" => true }, { "stages" => [] },
      { "stages" => "review" }, { "stages" => [ "review", "review" ] }, { "skill" => "" },
      { "instruction" => "x", "skill" => "/skill" }, { "timeout_sec" => 1.5 }, { "budget_usd" => Float::INFINITY },
      { "depends_on" => [ "Bad" ] }, { "targets" => [ "../outside" ] }, { "permissions" => "unsafe" },
      { "actor" => { "profile" => "missing", "provider" => "provider", "model" => "model" } },
      { "actor" => { "profile" => "claude", "provider" => "", "model" => "model" } },
      { "instruction_digest" => "orphaned" } ].each do |changes|
      assert_raises(Hive::ConfigError) { definition(changes) }
    end
    assert_raises(Hive::ConfigError) { Definition.new(nil, stages: [], source: "test") }
    assert_raises(Hive::ConfigError) { Definition.text("bad\0text", label: "test") }
    assert_raises(Hive::ConfigError) { Definition.identifier(nil, label: "test") }
    [ "/absolute", "~home", "foo\\bar", "https://external", "a//b", "a/*", "a;command", "a$(command)" ].each do |target|
      assert_raises(Hive::ConfigError) { definition("targets" => [ target ]) }
    end
  end

  def test_actor_requires_a_profile_able_to_pin_identity
    original = Hive::AgentProfiles.lookup(:pi)
    profile = Hive::AgentProfile.new(name: :pi, bin_default: "test", headless_flag: "-p", version_flag: "--version", skill_syntax_format: "/%{skill}")
    Hive::AgentProfiles.register(:pi, profile)
    assert_raises(Hive::ConfigError) do
      definition("actor" => { "profile" => "pi", "provider" => "test", "model" => "model" })
    end
  ensure
    Hive::AgentProfiles.register(:pi, original)
  end

  def test_bounded_permission_validation_reuses_the_actual_runtime_contract
    value = definition("actor" => { "profile" => "claude", "provider" => "anthropic", "model" => "model" },
                       "permissions" => { "tools" => [ "Read", "Bash" ], "commands" => [ "ruby check.rb" ], "domains" => [] })
    assert_equal [ "ruby check.rb" ], value.data.dig("permissions", "commands")
    assert definition("permissions" => { "tools" => [ "Read" ] })
    assert_raises(Hive::ConfigError) { definition("permissions" => { "tools" => [ "Bash" ], "commands" => [] }) }
    assert_raises(Hive::ConfigError) { definition("permissions" => { "tools" => [ "Read" ], "ignored" => true }) }
    assert_raises(Hive::ConfigError) { Hive::WorkflowPackage::RuntimePolicy.validate_spec!(nil) }
  end

  def test_checks_validate_reference_graph_kinds_and_behavior_claims
    check = { "id" => "links", "kind" => "behavior", "claim" => "Links work", "command" => "ruby check.rb" }
    valid = definition("checks" => [ check, check.merge("id" => "pages", "depends_on" => [ "links" ]) ])
    assert_equal [ "links" ], valid.checks.last.fetch("depends_on")
    [ "bad", [ check, check ], [ check.merge("kind" => "review") ], [ check.merge("claim" => nil) ],
      [ check.merge("depends_on" => [ "missing" ]) ], [ check.merge("depends_on" => [ "links" ]) ] ].each do |checks|
      assert_raises(Hive::ConfigError) { definition("checks" => checks) }
    end
    assert_raises(Hive::ConfigError) { definition("kind" => "guidance", "checks" => [ check ]) }
  end
end

class TaskCapabilitiesDefinitionTest
  def test_actor_account_and_binding_use_the_existing_provider_reference_vocabulary
    actor = { "profile" => "claude", "provider" => "anthropic", "model" => "approved", "provider_account" => "claude_primary", "launch_binding" => "approved_1" }
    assert_equal actor, Hive::TaskCapabilities::Definition.actor(actor, label: "fixture")
    assert_raises(Hive::ConfigError) { Hive::TaskCapabilities::Definition.actor(actor.merge("provider_account" => "../outside"), label: "fixture") }
  end
end
