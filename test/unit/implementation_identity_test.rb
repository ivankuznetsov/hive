require "test_helper"
require "hive/agent_profiles"
require "hive/implementation_identity"

class ImplementationIdentityTest < Minitest::Test
  include HiveTestHelper

  def test_native_arguments_reject_empty_or_multiline_values
    [ "", "safe\n--unsafe", "safe\r--unsafe", "safe\0unsafe" ].each do |value|
      assert_raises(Hive::ImplementationIdentity::InvalidIdentity) do
        Hive::ImplementationIdentity.validate_native_arguments([ value ])
      end
    end
  end

  def test_codex_native_default_reads_only_top_level_model
    with_tmp_dir do |home|
      FileUtils.mkdir_p(File.join(home, ".codex"))
      File.write(
        File.join(home, ".codex", "config.toml"),
        "# comment\nmodel = \"gpt-5.6-sol\" # selected\n[profile]\nmodel = \"ignored\"\n"
      )

      assert_equal "gpt-5.6-sol",
                   Hive::ImplementationIdentity::NativeDefaults.resolve(:codex, home: home)
      assert_equal "gpt-5.6-sol",
                   Hive::AgentProfiles.lookup(:codex).concrete_default_model(home: home)
    end
  end

  def test_native_default_rejects_unknown_provider_and_malformed_json
    assert_raises(Hive::ImplementationIdentity::ResolutionError) do
      Hive::ImplementationIdentity::NativeDefaults.resolve(:unknown, home: nil)
    end

    with_tmp_dir do |home|
      FileUtils.mkdir_p(File.join(home, ".claude"))
      File.write(File.join(home, ".claude", "settings.json"), "{")

      error = assert_raises(Hive::ImplementationIdentity::ResolutionError) do
        Hive::ImplementationIdentity::NativeDefaults.resolve(:claude, home: home)
      end
      assert_match(/could not inspect claude default model/, error.message)
    end
  end

  def test_pi_native_default_reports_absent_model
    with_tmp_dir do |home|
      FileUtils.mkdir_p(File.join(home, ".pi"))
      File.write(File.join(home, ".pi", "settings.json"), JSON.generate("provider" => "google"))

      assert_raises(Hive::ImplementationIdentity::ResolutionError) do
        Hive::ImplementationIdentity::NativeDefaults.resolve(:pi, home: home)
      end
    end
  end

  def test_routing_metadata_accepts_symbol_keys_and_reconstructs_resolution
    metadata = {
      stage: "review_fix",
      model: "gpt-5.6-sol",
      effort: "high",
      provenance: {
        model: { kind: "exact", key: "review_fix" },
        effort: { kind: "coarse", key: "review" }
      }
    }

    normalized = Hive::ImplementationIdentity.normalize_routing_metadata(metadata)
    resolution = Hive::ImplementationIdentity.routing_resolution_from_metadata(
      normalized, provider: "codex"
    )

    assert_equal "review_fix", normalized.fetch("stage")
    assert_equal :exact, resolution.provenance.fetch(:model).kind
    assert_equal :coarse, resolution.provenance.fetch(:effort).kind
    assert_equal "codex", resolution.provider
  end

  def test_routing_metadata_rejects_malformed_or_inconsistent_shapes
    valid = {
      "stage" => "review_fix",
      "model" => "gpt-5.6-sol",
      "effort" => "high",
      "provenance" => {
        "model" => { "kind" => "exact", "key" => "review_fix" },
        "effort" => { "kind" => "coarse", "key" => "review" }
      }
    }
    invalid = [
      "not-a-mapping",
      valid.merge("stage" => "unknown"),
      valid.merge("provenance" => []),
      valid.merge("provenance" => valid.fetch("provenance").except("model")),
      valid.merge(
        "provenance" => valid.fetch("provenance").merge(
          "model" => { "kind" => "invented" }
        )
      ),
      valid.merge(
        "provenance" => valid.fetch("provenance").merge(
          "model" => { "kind" => "exact", "key" => "review_ci" }
        )
      ),
      valid.merge(
        "provenance" => valid.fetch("provenance").merge(
          "model" => { "kind" => "current", "key" => "review_fix" }
        )
      ),
      valid.merge(
        "provenance" => {
          "model" => { "kind" => "current" },
          "effort" => { "kind" => "absent" }
        }
      )
    ]

    invalid.each do |metadata|
      assert_raises(Hive::ImplementationIdentity::InvalidIdentity) do
        Hive::ImplementationIdentity.normalize_routing_metadata(metadata)
      end
    end
  end

  def test_selection_requires_routing_values_to_match_durable_values
    metadata = {
      "stage" => "execute_implementation",
      "model" => "gpt-5.6-sol",
      "effort" => "xhigh",
      "provenance" => {
        "model" => { "kind" => "exact", "key" => "execute_implementation" },
        "effort" => { "kind" => "coarse", "key" => "execute" }
      }
    }

    assert_raises(Hive::ImplementationIdentity::InvalidIdentity) do
      selection(model: "gpt-5.6-terra", effort: "xhigh", routing: metadata)
    end
    assert_raises(Hive::ImplementationIdentity::InvalidIdentity) do
      selection(model: "gpt-5.6-sol", effort: "high", routing: metadata)
    end

    legacy = selection(model: "gpt-5.6-sol", effort: "xhigh")
    assert_nil legacy.routing_resolution
    assert_nil legacy.routing_arguments(Hive::AgentProfiles.lookup(:codex))
    refute_includes legacy.to_h, "routing"
    assert_nil Hive::ImplementationIdentity.routing_metadata(nil)
  end

  private

  def selection(model:, effort:, routing: nil)
    Hive::ImplementationIdentity::Selection.new(
      stage: "execute",
      provider: "codex",
      model: model,
      profile_name: "codex",
      launcher_identity: "codex-cli/v1",
      source: "persisted_execute",
      generation: 1,
      originating_attempt: "execute-1",
      requested_effort: effort,
      effective_effort: effort,
      effort_supported: true,
      model_pinned: true,
      native_arguments: [ "--model", model ],
      routing: routing
    )
  end
end
