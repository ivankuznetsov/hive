require_relative "../../test_helper"
require_relative "incident_budget"
require "json"
require "open3"
require "rbconfig"

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
    assert checked.ok?(:integrity)
    refute checked.ok?(:timing)
    assert_empty checked.integrity_violations
    assert_equal [ "slow took 10.000s (must be below 10.000s)" ], checked.violations
    assert_equal checked.violations, checked.timing_violations
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
    assert checked.ok?(:integrity)
    refute checked.ok?(:timing)
    assert_equal [ "incident group took 30.000s (must be below 30.000s)" ], checked.violations
  end

  def test_enabled_incident_without_a_result_fails_closed
    checked = Hive::E2E::IncidentBudget.check(
      report(metadata: [ metadata("missing") ], scenarios: [])
    )

    refute checked.ok?
    refute checked.ok?(:integrity)
    assert checked.ok?(:timing)
    assert_empty checked.timing_violations
    assert_equal [ "enabled incident \"missing\" has no scenario result" ], checked.violations
    assert_equal checked.violations, checked.integrity_violations
  end

  def test_duplicate_incident_names_fail_instead_of_undercounting_the_group
    checked = Hive::E2E::IncidentBudget.check(
      report(
        metadata: [ metadata("duplicate"), metadata("duplicate") ],
        scenarios: [ result("duplicate", 20.0), result("duplicate", 20.0) ]
      )
    )

    refute checked.ok?
    refute checked.ok?(:integrity)
    assert checked.ok?(:timing)
    assert_empty checked.timing_violations
    assert_includes checked.violations, 'enabled incident metadata contains duplicate name "duplicate"'
    assert_includes checked.violations, 'scenario results contain duplicate name "duplicate"'
  end

  def test_invalid_duration_is_an_integrity_failure
    checked = Hive::E2E::IncidentBudget.check(
      report(metadata: [ metadata("invalid") ], scenarios: [ result("invalid", "not-a-number") ])
    )

    refute checked.ok?(:integrity)
    assert checked.ok?(:timing)
    assert_empty checked.timing_violations
    assert_equal [ 'enabled incident "invalid" has an invalid duration' ], checked.integrity_violations
  end

  def test_cli_modes_enforce_integrity_and_timing_independently
    Dir.mktmpdir("incident-budget-cli") do |dir|
      slow_report = File.join(dir, "slow.json")
      missing_report = File.join(dir, "missing.json")
      File.write(
        slow_report,
        JSON.generate(report(metadata: [ metadata("slow") ], scenarios: [ result("slow", 10.0) ]))
      )
      File.write(
        missing_report,
        JSON.generate(report(metadata: [ metadata("missing") ], scenarios: []))
      )

      _, slow_integrity_error, slow_integrity = run_checker(slow_report, "--integrity-only")
      _, slow_timing_error, slow_timing = run_checker(slow_report, "--timing-only")
      _, missing_integrity_error, missing_integrity = run_checker(missing_report, "--integrity-only")
      _, missing_timing_error, missing_timing = run_checker(missing_report, "--timing-only")

      assert slow_integrity.success?, slow_integrity_error
      refute slow_timing.success?
      assert_includes slow_timing_error, "slow took 10.000s"
      refute missing_integrity.success?
      assert_includes missing_integrity_error, "has no scenario result"
      assert missing_timing.success?, missing_timing_error
    end
  end

  private

  def run_checker(report_path, mode)
    Open3.capture3(
      RbConfig.ruby,
      File.expand_path("../check_incident_budget.rb", __dir__),
      report_path,
      mode
    )
  end
end
