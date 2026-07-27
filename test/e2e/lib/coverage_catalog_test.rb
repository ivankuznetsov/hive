require_relative "../../test_helper"
require "tmpdir"
require_relative "coverage_catalog"
require_relative "scenario_parser"

class E2ECoverageCatalogTest < Minitest::Test
  def with_fixture(primary: "test.valid", pending: false, catalog_id: "test.valid",
                   maturity: "required", profiles: [ "release" ], docs: [ "wiki/e2e.md" ])
    Dir.mktmpdir("e2e-coverage") do |dir|
      scenario_path = File.join(dir, "scenario.yml")
      incident = if pending
                   <<~YAML
                     tags: [incident-regression]
                     incident_id: synthetic-pending
                     sibling_task_id: "#1234"
                     pending: true
                   YAML
                 else
                   "tags: [synthetic]\n"
                 end
      File.write(scenario_path, <<~YAML)
        name: synthetic_scenario
        description: Synthetic catalog fixture.
        #{incident}
        coverage:
          primary: #{primary}
          supporting: []
        steps:
          - kind: cli
            args: [version]
      YAML
      catalog_path = File.join(dir, "coverage.yml")
      File.write(catalog_path, <<~YAML)
        schema_version: 1
        profiles:
          release:
            description: Synthetic release proof.
        coverage:
          - id: #{catalog_id}
            title: Synthetic proof
            description: Synthetic proof description.
            maturity: #{maturity}
            profiles: #{profiles.inspect}
            constraints:
              platforms: [linux]
              providers: [codex]
            docs: #{docs.inspect}
            code: [test/e2e/lib/runner.rb]
      YAML
      yield scenario_path, catalog_path
    end
  end

  def scenarios
    Dir[File.expand_path("../scenarios/*.yml", __dir__)]
      .reject { |path| File.basename(path).start_with?("_") }
      .sort
      .map { |path| Hive::E2E::ScenarioParser.parse(path) }
  end

  def catalog
    Hive::E2E::CoverageCatalog.load(scenarios: scenarios)
  end

  def test_checked_in_catalog_maps_every_scenario_once_and_release_profile_is_runnable
    assert_equal 20, catalog.entries.size
    assert_equal scenarios.map(&:name).sort, catalog.primary_scenarios.map(&:name).sort

    selection = catalog.select_profile("release")
    assert_equal 16, selection.fetch("coverage_ids").size
    assert_equal 16, selection.fetch("scenarios").size
    assert_equal 4, selection.fetch("planned").size
  end

  def test_validation_is_idempotent
    checked = catalog

    assert_same checked, checked.validate!
    assert_equal scenarios.map(&:name).sort, checked.primary_scenarios.map(&:name).sort
    assert_equal 16, checked.select_profile("release").fetch("scenarios").size
  end

  def test_exact_id_wins_and_substring_results_are_lexical
    exact = catalog.search("recovery.provider_limit")
    assert_equal [ "recovery.provider_limit" ], exact.map { |match| match.fetch("id") }
    assert_nil exact.first.fetch("runnable_command")

    ids = catalog.search("update").map { |match| match.fetch("id") }
    assert_equal ids.sort, ids
    assert_operator ids.size, :>, 1
  end

  def test_searches_scenario_tags_steps_references_platforms_and_providers
    assert_includes catalog.search("provider retry").map { |match| match.fetch("id") },
                    "recovery.provider_limit"
    assert_includes catalog.search("error-envelope").map { |match| match.fetch("id") },
                    "runtime.error_envelope"
    assert_includes catalog.search("tui_expect").map { |match| match.fetch("id") },
                    "tui.navigation"
    assert_includes catalog.search("wiki/e2e.md").map { |match| match.fetch("id") },
                    "workflow.full_pipeline"
    assert_includes catalog.search("linux").map { |match| match.fetch("id") },
                    "attempt.terminal_replay"
    assert_includes catalog.search("codex").map { |match| match.fetch("id") },
                    "recovery.provider_limit"
  end

  def test_active_primary_has_one_safe_command_while_supporting_and_pending_are_discovery_only
    match = catalog.search("workflow.full_pipeline").first
    assert_equal "bin/hive-e2e run --coverage workflow.full_pipeline",
                 match.fetch("runnable_command")
    assert_equal "full_pipeline_happy_path", match.dig("primary_scenario", "name")
    assert_empty match.fetch("supporting_scenarios")

    pending = catalog.search("recovery.provider_limit").first
    assert_equal true, pending.dig("primary_scenario", "pending")
    assert_nil pending.fetch("runnable_command")
  end

  def test_unknown_mapping_and_duplicate_primary_owner_are_rejected
    with_fixture(primary: "test.unknown") do |scenario_path, catalog_path|
      error = assert_raises(Hive::E2E::CoverageCatalog::InvalidCatalog) do
        Hive::E2E::CoverageCatalog.load(
          scenarios: [ Hive::E2E::ScenarioParser.parse(scenario_path) ],
          path: catalog_path
        )
      end
      assert_includes error.message, "unknown coverage ID"
    end

    with_fixture do |scenario_path, catalog_path|
      scenario = Hive::E2E::ScenarioParser.parse(scenario_path)
      unknown_support = scenario.coverage.with(supporting: [ "test.unknown" ])
      scenario = scenario.with(coverage: unknown_support)
      error = assert_raises(Hive::E2E::CoverageCatalog::InvalidCatalog) do
        Hive::E2E::CoverageCatalog.load(scenarios: [ scenario ], path: catalog_path)
      end
      assert_includes error.message, "unknown coverage ID"
    end

    with_fixture do |scenario_path, catalog_path|
      scenario = Hive::E2E::ScenarioParser.parse(scenario_path)
      duplicate = scenario.with(name: "second_scenario", path: "#{scenario_path}.second")
      error = assert_raises(Hive::E2E::CoverageCatalog::InvalidCatalog) do
        Hive::E2E::CoverageCatalog.load(scenarios: [ scenario, duplicate ], path: catalog_path)
      end
      assert_includes error.message, "duplicate primary owner"
    end
  end

  def test_invalid_maturity_profile_and_reference_are_rejected
    [
      { maturity: "eventually", message: "maturity" },
      { profiles: [ "nightly" ], message: "unknown profile" },
      { docs: [ "../outside.md" ], message: "reference" }
    ].each do |overrides|
      message = overrides.delete(:message)
      with_fixture(**overrides) do |scenario_path, catalog_path|
        error = assert_raises(Hive::E2E::CoverageCatalog::InvalidCatalog) do
          Hive::E2E::CoverageCatalog.load(
            scenarios: [ Hive::E2E::ScenarioParser.parse(scenario_path) ],
            path: catalog_path
          )
        end
        assert_includes error.message, message
      end
    end
  end

  def test_release_required_pending_owner_fails_profile_preflight
    with_fixture(pending: true) do |scenario_path, catalog_path|
      fixture_catalog = Hive::E2E::CoverageCatalog.load(
        scenarios: [ Hive::E2E::ScenarioParser.parse(scenario_path) ],
        path: catalog_path
      )

      error = assert_raises(Hive::E2E::CoverageCatalog::InvalidCatalog) do
        fixture_catalog.select_profile("release")
      end
      assert_includes error.message, "required coverage"
      assert_includes error.message, "no active primary"
    end
  end
end
