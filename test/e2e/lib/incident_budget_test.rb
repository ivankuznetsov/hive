require_relative "../../test_helper"
require_relative "incident_budget"

class E2EIncidentBudgetTest < Minitest::Test
  def report(metadata:, scenarios:)
    { "scenario_metadata" => metadata, "scenarios" => scenarios }
  end

  def metadata(name, pending: false)
    { "name" => name, "tags" => [ "incident-regression" ], "pending" => pending }
  end

  def result(name, duration)
    { "name" => name, "status" => "passed", "duration_seconds" => duration }
  end

  def test_pending_incidents_are_visible_but_do_not_consume_the_budget
    checked = Hive::E2E::IncidentBudget.check(
      report(metadata: [ metadata("waiting", pending: true) ], scenarios: [])
    )

    assert checked.ok?
    assert_empty checked.durations
    assert_equal 0, checked.total_seconds
  end

  def test_enabled_incident_must_be_below_ten_seconds
    checked = Hive::E2E::IncidentBudget.check(
      report(metadata: [ metadata("slow") ], scenarios: [ result("slow", 10.0) ])
    )

    refute checked.ok?
    assert_equal [ "slow took 10.000s (must be below 10.000s)" ], checked.violations
  end

  def test_hosted_runner_variance_above_five_seconds_stays_within_budget
    checked = Hive::E2E::IncidentBudget.check(
      report(metadata: [ metadata("variable") ], scenarios: [ result("variable", 5.010) ])
    )

    assert checked.ok?
  end

  def test_enabled_incident_group_must_be_below_thirty_seconds
    checked = Hive::E2E::IncidentBudget.check(
      report(
        metadata: [ metadata("one"), metadata("two") ],
        scenarios: [ result("one", 16.0), result("two", 14.0) ]
      ),
      per_scenario_limit: 20.0
    )

    refute checked.ok?
    assert_equal [ "incident group took 30.000s (must be below 30.000s)" ], checked.violations
  end

  def test_enabled_incident_without_a_result_fails_closed
    checked = Hive::E2E::IncidentBudget.check(
      report(metadata: [ metadata("missing") ], scenarios: [])
    )

    refute checked.ok?
    assert_equal [ "enabled incident \"missing\" has no scenario result" ], checked.violations
  end

  def test_duplicate_incident_names_fail_instead_of_undercounting_the_group
    checked = Hive::E2E::IncidentBudget.check(
      report(
        metadata: [ metadata("duplicate"), metadata("duplicate") ],
        scenarios: [ result("duplicate", 20.0), result("duplicate", 20.0) ]
      )
    )

    refute checked.ok?
    assert_includes checked.violations, 'enabled incident metadata contains duplicate name "duplicate"'
    assert_includes checked.violations, 'scenario results contain duplicate name "duplicate"'
  end
end
