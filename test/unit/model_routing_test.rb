require "test_helper"
require "hive/model_routing"

class ModelRoutingTest < Minitest::Test
  include HiveTestHelper

  PUBLIC_KEYS = %w[
    brainstorm
    plan
    execute
    execute_implementation
    rebase
    diagnose
    babysitter
    review
    review_ci
    review_reviewers
    review_triage
    review_fix
    review_browser
    patrol
    patrol_review
    patrol_fix
    open_pr
    artifacts
    finalize
  ].freeze

  FAMILY_PARENTS = {
    "execute_implementation" => "execute",
    "rebase" => "execute",
    "diagnose" => "execute",
    "babysitter" => "execute",
    "review_ci" => "review",
    "review_reviewers" => "review",
    "review_triage" => "review",
    "review_fix" => "review",
    "review_browser" => "review",
    "patrol_review" => "patrol",
    "patrol_fix" => "patrol"
  }.freeze

  def test_registry_is_the_closed_immutable_vocabulary
    assert_equal PUBLIC_KEYS, Hive::ModelRouting.keys
    assert_equal PUBLIC_KEYS, Hive::ModelRouting.entries.map(&:key)
    assert_equal FAMILY_PARENTS,
                 Hive::ModelRouting.entries.filter_map { |entry|
                   [ entry.key, entry.parent ] if entry.parent
                 }.to_h

    assert Hive::ModelRouting.entries.frozen?
    assert Hive::ModelRouting.entries.all?(&:frozen?)
  end

  def test_structural_parser_accepts_every_key_and_preserves_field_absence
    Hive::ModelRouting.entries.each do |entry|
      parsed = Hive::ModelRouting.parse(
        { entry.key => { "model" => " model-#{entry.key} " } },
        source: "/tmp/config.yml"
      )

      assert_equal({ "model" => "model-#{entry.key}" }, parsed.fetch(entry.key))
      refute parsed.fetch(entry.key).key?("effort")
    end

    parsed = Hive::ModelRouting.parse(
      {
        "plan" => { "effort" => "xhigh" },
        "review" => { "model" => "opus", "effort" => "max" }
      },
      source: "/tmp/config.yml"
    )

    assert_equal({ "effort" => "xhigh" }, parsed.fetch("plan"))
    assert_equal({ "model" => "opus", "effort" => "max" }, parsed.fetch("review"))
  end

  def test_structural_parser_rejects_malformed_roots_entries_fields_and_values
    [ nil, [], "plan", 7 ].each do |root|
      error = assert_raises(Hive::ConfigError) do
        Hive::ModelRouting.parse(root, source: "/tmp/project.yml")
      end
      assert_match(/models.*mapping/i, error.message)
      assert_includes error.message, "/tmp/project.yml"
    end

    invalid_entries = {
      "plan" => nil,
      "review" => [],
      "execute" => "gpt-5.6-sol",
      "patrol" => {}
    }
    invalid_entries.each do |key, value|
      error = assert_raises(Hive::ConfigError) do
        Hive::ModelRouting.parse({ key => value }, source: "/tmp/project.yml")
      end
      assert_match(/models\.#{Regexp.escape(key)}.*non-empty mapping/i, error.message)
    end

    {
      { "plan" => { "agent" => "codex" } } => /unknown field.*agent/i,
      { "plan" => { "model" => nil } } => /models\.plan\.model.*non-blank scalar/i,
      { "plan" => { "model" => [] } } => /models\.plan\.model.*non-blank scalar/i,
      { "plan" => { "model" => {} } } => /models\.plan\.model.*non-blank scalar/i,
      { "plan" => { "model" => "  " } } => /models\.plan\.model.*non-blank scalar/i,
      { "plan" => { "effort" => "turbo" } } => /models\.plan\.effort.*one of/i,
      { "plan" => { "effort" => 7 } } => /models\.plan\.effort.*one of/i,
      { "plan" => { "effort" => " " } } => /models\.plan\.effort.*one of/i
    }.each do |raw, pattern|
      error = assert_raises(Hive::ConfigError) do
        Hive::ModelRouting.parse(raw, source: "/tmp/project.yml")
      end
      assert_match pattern, error.message
    end
  end

  def test_structural_parser_rejects_keys_that_collide_after_normalization
    stage_error = assert_raises(Hive::ConfigError) do
      Hive::ModelRouting.parse(
        {
          "plan" => { "model" => "first" },
          plan: { "model" => "second" }
        },
        source: "/tmp/project.yml"
      )
    end
    assert_match(/models\.plan.*defined more than once/i, stage_error.message)

    field_error = assert_raises(Hive::ConfigError) do
      Hive::ModelRouting.parse(
        {
          "plan" => {
            "model" => "first",
            model: "second"
          }
        },
        source: "/tmp/project.yml"
      )
    end
    assert_match(/models\.plan\.model.*defined more than once/i, field_error.message)
  end

  def test_structural_parser_rejects_removed_and_unknown_stages
    removed_error = assert_raises(Hive::ConfigError) do
      Hive::ModelRouting.parse(
        { "digest" => { "model" => "gpt-5.6-sol" } },
        source: "/tmp/project.yml"
      )
    end
    assert_match(/models\.digest.*unknown/i, removed_error.message)

    unknown_error = assert_raises(Hive::ConfigError) do
      Hive::ModelRouting.parse(
        { "surprise" => { "model" => "gpt-5.6-sol" } },
        source: "/tmp/project.yml"
      )
    end
    assert_match(/models\.surprise.*unknown/i, unknown_error.message)
  end

  def test_resolver_inherits_model_and_effort_independently_with_provenance
    result = Hive::ModelRouting.resolve(
      models: {
        "review" => { "effort" => "high" },
        "review_fix" => { "model" => "gpt-5.6-sol" }
      },
      stage: :review_fix,
      provider: :codex,
      current: { model: "current-model", effort: "medium" },
      legacy: { model: "legacy-model", effort: "low" }
    )

    assert_equal :codex, result.provider
    assert_equal "gpt-5.6-sol", result.model
    assert_equal "high", result.effort
    assert result.active?
    assert_provenance result, :model, :exact, "review_fix"
    assert_provenance result, :effort, :coarse, "review"

    inverse = Hive::ModelRouting.resolve(
      models: {
        "review" => { "model" => "opus" },
        "review_fix" => { "effort" => "xhigh" }
      },
      stage: "review_fix",
      current: { model: "current-model", effort: "medium" },
      legacy: { model: "legacy-model", effort: "low" }
    )

    assert_equal "opus", inverse.model
    assert_equal "xhigh", inverse.effort
    assert_provenance inverse, :model, :coarse, "review"
    assert_provenance inverse, :effort, :exact, "review_fix"
  end

  def test_every_family_edge_prefers_exact_fields_over_its_registered_parent
    FAMILY_PARENTS.each do |exact, parent|
      result = Hive::ModelRouting.resolve(
        models: {
          parent => { "model" => "coarse-model", "effort" => "low" },
          exact => { "model" => "exact-model", "effort" => "high" }
        },
        stage: exact,
        current: { model: "current-model", effort: "medium" },
        legacy: { model: "legacy-model", effort: "xhigh" }
      )

      assert_equal "exact-model", result.model, exact
      assert_equal "high", result.effort, exact
      assert_provenance result, :model, :exact, exact
      assert_provenance result, :effort, :exact, exact
    end
  end

  def test_explicit_sentinels_stop_inheritance_while_absent_fields_continue
    result = Hive::ModelRouting.resolve(
      models: {
        "execute" => { "model" => "coarse-model", "effort" => "high" },
        "diagnose" => { "model" => "inherit", "effort" => "default" }
      },
      stage: "diagnose",
      current: { model: "current-model", effort: "medium" },
      legacy: { model: "legacy-model", effort: "low" }
    )

    assert_equal "inherit", result.model
    assert_equal "default", result.effort
    assert_provenance result, :model, :exact, "diagnose"
    assert_provenance result, :effort, :exact, "diagnose"

    absent = Hive::ModelRouting.resolve(
      models: { "diagnose" => { "model" => "exact-model" } },
      stage: "diagnose",
      current: { effort: "medium" },
      legacy: { model: "legacy-model", effort: "low" }
    )
    assert_equal "exact-model", absent.model
    assert_equal "medium", absent.effort
    assert_provenance absent, :effort, :current, nil
  end

  def test_resolver_uses_current_then_legacy_per_field
    result = Hive::ModelRouting.resolve(
      models: { "review" => { "model" => "unrelated" } },
      stage: "plan",
      current: { "model" => "current-model" },
      legacy: { model: "legacy-model", effort: "legacy-effort" }
    )

    assert_equal "current-model", result.model
    assert_equal "legacy-effort", result.effort
    refute result.active?
    assert_provenance result, :model, :current, nil
    assert_provenance result, :effort, :legacy, nil

    empty = Hive::ModelRouting.resolve(models: {}, stage: "plan", current: {}, legacy: {})
    assert_nil empty.model
    assert_nil empty.effort
    assert_provenance empty, :model, :absent, nil
    assert_provenance empty, :effort, :absent, nil
  end

  def test_inactive_or_unscoped_resolution_bypasses_stage_routing
    provider = Object.new
    inactive = Hive::ModelRouting.resolve(
      models: {},
      stage: "not-a-public-stage",
      provider: provider,
      current: { model: " current ", effort: "legacy-shape" },
      legacy: { model: "ignored", effort: "ignored" }
    )
    assert_same provider, inactive.provider
    assert_equal " current ", inactive.model
    assert_equal "legacy-shape", inactive.effort
    refute inactive.active?

    unscoped = Hive::ModelRouting.resolve(
      models: { "plan" => { "model" => "routed", "effort" => "xhigh" } },
      stage: nil,
      current: { model: "unchanged", effort: "unchanged-effort" },
      legacy: { model: "legacy", effort: "low" }
    )
    assert_equal "unchanged", unscoped.model
    assert_equal "unchanged-effort", unscoped.effort
    refute unscoped.active?

    assert_raises(Hive::ConfigError) do
      Hive::ModelRouting.resolve(
        models: { "plan" => { "model" => "routed" } },
        stage: "not-a-public-stage",
        current: {},
        legacy: {}
      )
    end
  end

  def test_inactive_resolution_falls_back_to_legacy_fields_without_stage_validation
    result = Hive::ModelRouting.resolve(
      models: nil,
      stage: "legacy-only-stage",
      current: {},
      legacy: { model: "legacy-model", effort: "legacy-effort" }
    )

    assert_equal "legacy-model", result.model
    assert_equal "legacy-effort", result.effort
    assert_provenance result, :model, :legacy, nil
    assert_provenance result, :effort, :legacy, nil
    refute result.active?
  end

  def test_resolver_and_reachability_validator_reject_unparsed_shapes
    resolve_error = assert_raises(Hive::ConfigError) do
      Hive::ModelRouting.resolve(models: [ "plan" ], stage: "plan")
    end
    assert_match(/models must be a mapping/i, resolve_error.message)

    calls_error = assert_raises(ArgumentError) do
      Hive::ModelRouting.validate_effective!(
        models: { "plan" => { "model" => "gpt-5.6-sol" } },
        calls: [ "plan" ]
      )
    end
    assert_match(/reachable model-routing calls must be mappings/i, calls_error.message)
  end

  def test_effective_validation_skips_disabled_and_fully_shadowed_coarse_controls
    models = {
      "review" => { "effort" => "max" },
      "review_ci" => { "effort" => "low" },
      "review_reviewers" => { "effort" => "low" },
      "review_fix" => { "effort" => "low" },
      "review_browser" => { "effort" => "low" }
    }
    calls = %w[review_ci review_reviewers review_fix review_browser].map do |stage|
      { stage: stage, profile: :pi, provider: :pi }
    end
    calls << { stage: "review_triage", profile: :pi, provider: :pi, enabled: false }

    controls = Hive::ModelRouting.validate_effective!(models: models, calls: calls) do |control|
      raise Hive::ConfigError, "pi rejects max" if control.profile == :pi && control.value == "max"
    end

    assert_equal 4, controls.length
    assert controls.all? { |control| control.value == "low" && control.provenance.kind == :exact }

    calls.last[:enabled] = true
    error = assert_raises(Hive::ConfigError) do
      Hive::ModelRouting.validate_effective!(models: models, calls: calls) do |control|
        raise Hive::ConfigError, "pi rejects max" if control.profile == :pi && control.value == "max"
      end
    end
    assert_equal "pi rejects max", error.message
  end

  def test_effective_validation_is_field_wise_and_inactive_safe
    seen = []
    controls = Hive::ModelRouting.validate_effective!(
      models: {
        "execute" => { "model" => "coarse-model", "effort" => "max" },
        "diagnose" => { "model" => "exact-model" }
      },
      calls: [
        {
          stage: "diagnose",
          profile: :pi,
          provider: :pi,
          current: { effort: "legacy-effort" }
        }
      ]
    ) do |control|
      seen << [ control.field, control.value, control.provenance.kind ]
    end

    assert_equal [
      [ :model, "exact-model", :exact ],
      [ :effort, "max", :coarse ]
    ], seen
    assert_equal seen.length, controls.length

    invoked = false
    assert_empty Hive::ModelRouting.validate_effective!(
      models: {},
      calls: [ { stage: "unknown", profile: :pi } ]
    ) { invoked = true }
    refute invoked
  end

  private

  def assert_provenance(result, field, kind, key)
    provenance = result.provenance.fetch(field)
    assert_equal kind, provenance.kind
    key.nil? ? assert_nil(provenance.key) : assert_equal(key, provenance.key)
  end
end
