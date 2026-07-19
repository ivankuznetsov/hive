require "test_helper"
require "hive/digest"
require "hive/workflow_package/configuration"

class WorkflowPackageConfigurationTest < Minitest::Test
  def test_contract_constants_reuse_workflow_and_manifest_authorities
    assert_same Hive::Workflow::MAPPING_ROLES,
                Hive::WorkflowPackage::Configuration::ROLES
    assert_same Hive::WorkflowPackage::Manifest::SHA256,
                Hive::WorkflowPackage::Configuration::SHA256
  end

  def test_builds_byte_stable_snapshot_and_overlays_every_actor
    configuration = build_configuration
    reloaded = Hive::WorkflowPackage::Configuration.load(configuration.bytes)

    assert_equal configuration.digest, reloaded.digest
    assert_equal configuration.bytes, reloaded.bytes
    mapped = reloaded.apply(workflow)
    assert_equal "codex", mapped.stage_named("draft").agent
    assert_equal "gpt-5.6-sol", mapped.stage_named("draft").model
    review = mapped.stage_named("review")
    assert_equal "claude", review.agent
    assert_equal "codex", review.reviewers.first.agent
    assert_equal "claude", review.council.revise.agent
  end

  def test_optional_inputs_are_isolated_to_authorized_slots_and_values_are_not_snapshotted
    secret = "secret-canary-#{Process.pid}"
    configuration = build_configuration(input_bindings: { "GSC_TOKEN" => "HIVE_TEST_GSC" })
    metadata = runtime_metadata

    refute_includes configuration.bytes, secret
    draft = configuration.input_environment_for(
      "stages.draft", runtime_metadata: metadata, environment: { "HIVE_TEST_GSC" => secret }
    )
    reviewer = configuration.input_environment_for(
      "stages.review.reviewers.security", runtime_metadata: metadata,
      environment: { "HIVE_TEST_GSC" => secret }
    )

    assert_equal({ "GSC_TOKEN" => secret }, draft)
    assert_empty reviewer
  end

  def test_unknown_slot_and_profile_drift_fail_closed
    assert_raises(Hive::ConfigError) do
      build_configuration(overrides: { "stages.missing" => { "agent" => "claude" } })
    end

    configuration = build_configuration
    drifted = { "agents" => { "codex" => { "bin" => "/tmp/different-codex" } } }
    error = assert_raises(Hive::ConfigError) { configuration.apply(workflow, cfg: drifted) }
    assert_match(/profile drifted/, error.message)
  end

  def test_explicit_pins_require_native_profile_support
    pinless = Hive::AgentProfile.new(
      name: :pi,
      bin_default: "pi",
      headless_flag: "-p",
      version_flag: "--version",
      skill_syntax_format: "/skill:%{skill}"
    )
    Hive::AgentProfiles.register(:pi, pinless)

    model_error = assert_raises(Hive::ConfigError) do
      build_configuration(overrides: {
        "stages.draft" => { "agent" => "pi", "model" => "provider/model-v1" }
      })
    end
    assert_match(/cannot pin model/, model_error.message)

    effort_error = assert_raises(Hive::ConfigError) do
      build_configuration(overrides: {
        "stages.draft" => { "agent" => "pi", "effort" => "high" }
      })
    end
    assert_match(/cannot pin effort/, effort_error.message)
  ensure
    Hive::AgentProfiles.register(:pi, Hive::AgentProfiles::PI)
  end

  def test_profile_defaults_do_not_create_unsupported_pins
    pinless = Hive::AgentProfile.new(
      name: :pi,
      bin_default: "pi",
      headless_flag: "-p",
      version_flag: "--version",
      skill_syntax_format: "/skill:%{skill}"
    )
    Hive::AgentProfiles.register(:pi, pinless)
    overrides = Hive::WorkflowPackage::Configuration.slots_for(workflow).to_h do |slot|
      [ slot.id, { "agent" => "pi" } ]
    end

    configuration = build_configuration(
      overrides: overrides,
      cfg: {
        "plan" => { "model" => "planning-model", "effort" => "medium" },
        "execute" => { "model" => "execution-model", "effort" => "high" }
      }
    )

    configuration.data.fetch("mappings").each_value do |mapping|
      assert_nil mapping.fetch("model")
      assert_nil mapping.fetch("effort")
    end
  ensure
    Hive::AgentProfiles.register(:pi, Hive::AgentProfiles::PI)
  end

  def test_supported_configuration_pins_translate_to_native_launch_arguments
    mapping = build_configuration.data.fetch("mappings").fetch("stages.draft")
    profile = Hive::AgentProfiles.lookup(mapping.fetch("agent"))

    arguments = profile.identity_arguments(
      model: mapping.fetch("model"), effort: mapping.fetch("effort")
    ).native_arguments

    assert_equal [ "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=high" ], arguments
  end

  def test_input_bindings_require_portable_environment_names_and_report_status
    error = assert_raises(Hive::ConfigError) do
      build_configuration(input_bindings: { "GSC_TOKEN" => "not portable" })
    end
    assert_match(/environment variable name/, error.message)

    configuration = build_configuration(input_bindings: { "GSC_TOKEN" => "GSC_RUNTIME_TOKEN" })
    assert_equal [
      { "name" => "GSC_TOKEN", "binding" => "GSC_RUNTIME_TOKEN", "available" => true }
    ], configuration.input_status_for(
      "stages.draft", runtime_metadata: runtime_metadata,
      environment: { "GSC_RUNTIME_TOKEN" => "secret" }
    )
    assert_empty configuration.input_status_for(
      "stages.review", runtime_metadata: runtime_metadata,
      environment: { "GSC_RUNTIME_TOKEN" => "secret" }
    )
  end

  def test_disclosure_rows_share_snapshot_semantics_without_exposing_values
    configuration = build_configuration(
      input_bindings: { "GSC_TOKEN" => "GSC_RUNTIME_TOKEN" }
    )
    secret = "secret-canary"
    inputs = configuration.input_rows(
      runtime_metadata: runtime_metadata,
      environment: { "GSC_RUNTIME_TOKEN" => secret }
    )

    assert_equal configuration.data.fetch("mappings").keys,
                 configuration.mapping_rows.map { |row| row.fetch("slot") }
    assert_equal [
      {
        "name" => "GSC_TOKEN",
        "authorized_slots" => [ "stages.draft" ],
        "binding" => "GSC_RUNTIME_TOKEN",
        "available" => true
      }
    ], inputs
    refute_includes JSON.generate(inputs), secret
  end

  def test_scoped_reviewer_suggestions_fall_back_to_an_enforceable_agent
    configuration = build_configuration(
      overrides: { "stages.draft" => { "agent" => "codex" } },
      cfg: { "review" => { "reviewers" => [ { "agent" => "codex" } ] } }
    )

    mapping = configuration.data.fetch("mappings").fetch("stages.review.reviewers.security")
    assert_equal "claude", mapping.fetch("agent")
  end

  def test_explicit_scoped_mapping_is_preserved_for_runtime_admission
    configuration = build_configuration(
      overrides: { "stages.review.reviewers.security" => { "agent" => "codex" } },
      cfg: {
        "execute" => { "agent" => "codex" },
        "review" => { "reviewers" => [ { "agent" => "codex" } ] }
      }
    )

    mappings = configuration.data.fetch("mappings")
    assert_equal "codex", mappings.fetch("stages.draft").fetch("agent")
    assert_equal "codex", mappings.fetch("stages.review.reviewers.security").fetch("agent")
  end

  def test_apply_rejects_mapping_contract_drift
    data = JSON.parse(build_configuration.bytes)
    data.fetch("mappings").fetch("stages.draft")["mapping_contract"] = "draft-v2"
    drifted = Hive::WorkflowPackage::Configuration.new(data)

    error = assert_raises(Hive::ConfigError) { drifted.apply(workflow, verify_profiles: false) }
    assert_match(/contract drifted/, error.message)
  end

  def test_snapshot_shape_validation_rejects_each_malformed_layer
    valid = JSON.parse(build_configuration.bytes)
    malformed = [
      valid.merge("schema_version" => 99),
      valid.merge("generation" => { "name" => "demo" }),
      valid.merge("mappings" => {}),
      valid.merge("mappings" => { "bad slot" => valid.fetch("mappings").values.first })
    ]

    malformed.each do |data|
      assert_raises(Hive::ConfigError) { Hive::WorkflowPackage::Configuration.new(data) }
    end
  end

  def test_symbol_keys_are_normalized_recursively_and_configuration_values_must_be_maps
    configuration = build_configuration
    data = JSON.parse(configuration.bytes)
    symbol_keyed = {
      schema_version: data.fetch("schema_version"),
      generation: data.fetch("generation").transform_keys(&:to_sym),
      mappings: data.fetch("mappings").transform_values { |mapping| mapping.transform_keys(&:to_sym) },
      input_bindings: data.fetch("input_bindings")
    }
    assert_equal data, Hive::WorkflowPackage::Configuration.new(symbol_keyed).data
    assert_predicate configuration.send(:deep_freeze, [ [ "value" ] ]), :frozen?

    assert_raises(Hive::ConfigError) do
      Hive::WorkflowPackage::Configuration.build(
        workflow,
        generation: {
          "name" => "demo", "source_commit" => "a" * 40, "manifest_digest" => "b" * 64
        },
        overrides: "invalid"
      )
    end
  end

  private

  def build_configuration(overrides: nil, input_bindings: {}, cfg: {})
    overrides ||= {
      "stages.draft" => { "agent" => "codex", "model" => "gpt-5.6-sol", "effort" => "high" },
      "stages.review.reviewers.security" => { "agent" => "codex" }
    }
    Hive::WorkflowPackage::Configuration.build(
      workflow,
      generation: {
        "name" => "demo", "source_commit" => "a" * 40, "manifest_digest" => "b" * 64
      },
      cfg: cfg, overrides: overrides, input_bindings: input_bindings,
      runtime_metadata: runtime_metadata
    )
  end

  def runtime_metadata
    {
      "tools" => [],
      "optional_inputs" => [
        { "name" => "GSC_TOKEN", "authorized_slots" => [ "stages.draft" ] }
      ]
    }
  end

  def workflow
    reviewer = Hive::Workflow::Reviewer.new(
      name: "security", instruction: "/tmp/security.md", permissions: "read-only",
      mapping_role: "reviewer", mapping_contract: "review-v1"
    )
    revise = Hive::Workflow::Revise.new(
      instruction: "/tmp/revise.md", permissions: "yolo",
      mapping_role: "development", mapping_contract: "revise-v1"
    )
    Hive::Workflow.new(
      id: :demo,
      stages: [
        Hive::Workflow::Stage.new(
          name: "draft", index: 1, state_file: "draft.md", kind: :agent,
          instruction: "/tmp/draft.md", permissions: "yolo",
          mapping_role: "development", mapping_contract: "draft-v1"
        ),
        Hive::Workflow::Stage.new(
          name: "review", index: 2, state_file: "review.md", kind: :council,
          permissions: "yolo", mapping_role: "planning", mapping_contract: "council-v1",
          reviewers: [ reviewer ],
          council: Hive::Workflow::Council.new(quorum: 1, max_rounds: 2, exit_rule: :consensus, revise: revise)
        )
      ]
    )
  end
end
