require_relative "../../test_helper"
require_relative "paths"
require_relative "scenario_parser"

class E2EIncidentInventoryTest < Minitest::Test
  EXPECTED_INCIDENTS = {
    "accepted-attempt-caller-loss" => [ "incident_attempt_adoption_after_caller_loss.yml", "#9767" ],
    "generation-scoped-no-worktree-marker" => [ "incident_generation_scoped_no_worktree_marker.yml", "#9768" ],
    "finalize-pr-lifecycle-gate" => [ "incident_finalize_pr_lifecycle_gate.yml", "#9769" ],
    "plan-only-dependency-gate" => [ "incident_plan_only_dependency_gate.yml", "#9771" ],
    "repository-routing" => [ "incident_repository_routing.yml", "#9771" ],
    "provider-limit-retry" => [ "incident_provider_limit_retry.yml", "#9770" ]
  }.freeze

  def incident_scenarios
    Dir[File.join(Hive::E2E::Paths.scenarios_dir, "*.yml")]
      .map { |path| Hive::E2E::ScenarioParser.parse(path) }
      .select { |scenario| scenario.tags.include?("incident-regression") }
  end

  def documented_rows
    readme = File.join(Hive::E2E::Paths.scenarios_dir, "README.md")
    File.readlines(readme).filter_map do |line|
      next unless line.start_with?("| `")

      cells = line.split("|").map(&:strip)
      id = cells.fetch(1).delete("`")
      file = cells.fetch(2)[/\]\(([^)]+)\)/, 1]
      sibling = cells.fetch(3).delete("`")
      [ id, [ file, sibling ] ]
    end.to_h
  end

  def test_six_sibling_owned_incidents_are_unique_parseable_and_pending
    actual = incident_scenarios.to_h do |scenario|
      [ scenario.incident_id, [ File.basename(scenario.path), scenario.sibling_task_id ] ]
    end

    assert_equal 6, incident_scenarios.size
    assert_equal 6, incident_scenarios.map(&:incident_id).uniq.size
    assert incident_scenarios.all?(&:pending), "sibling-gated shells must stay pending until exact contracts land"
    assert_equal EXPECTED_INCIDENTS, actual
  end

  def test_readme_index_resolves_every_incident_once
    assert_equal EXPECTED_INCIDENTS, documented_rows
    documented_rows.each_value do |file, _sibling|
      assert File.file?(File.join(Hive::E2E::Paths.scenarios_dir, file)), "missing documented scenario #{file}"
    end
  end
end
