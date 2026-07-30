require "test_helper"
require "hive/modules/migration/report"

class ModulesMigrationReportTest < Minitest::Test
  include HiveTestHelper

  START = Time.utc(2026, 7, 1)
  DAY = 24 * 60 * 60
  FIXTURE_PATH = File.expand_path(
    "../../../fixtures/module_migration/report-v1.json",
    __dir__
  )
  REPORT_FIELDS = %w[
    blockers eligible generated_at modules reviewed_at reviewer schema
    schema_version window
  ].freeze
  SUMMARY_FIELDS = %w[
    blockers configuration_digest decision_count duplicate_effect_count
    elapsed_seconds ended_at started_at unexplained_difference_count
  ].freeze

  def test_loads_the_exact_canonical_v1_one_off_migration_input
    bytes = File.binread(FIXTURE_PATH)
    payload = JSON.parse(bytes)

    assert_equal bytes, Hive::Modules::Migration::Report.canonical(payload)
    assert_equal REPORT_FIELDS, payload.keys
    assert_equal %w[architecture-patrol patrol], payload.fetch("modules").keys
    payload.fetch("modules").each_value do |summary|
      assert_equal SUMMARY_FIELDS, summary.keys
    end
    assert_equal %w[ended_at started_at], payload.fetch("window").keys

    loaded = Hive::Modules::Migration::Report.load(FIXTURE_PATH)
    assert_equal payload, loaded.payload
    assert loaded.payload.frozen?
    assert loaded.eligible?
    assert_empty loaded.blockers
    assert_equal(
      {
        "architecture-patrol" => "b" * 64,
        "patrol" => "a" * 64
      },
      loaded.configuration_digests
    )
  end

  def test_characterizes_legacy_v1_accepting_timestamp_spread_same_class_decisions
    with_tmp_dir do |root|
      recorded_at = START
      comparator = Hive::Modules::Migration::ShadowComparator.new(
        root: root,
        clock: -> { recorded_at }
      )
      10.times do |index|
        recorded_at = START + (index * DAY)
        Hive::Modules::Migration::ShadowComparator::MODULES.each do |module_name|
          record_due_decision(
            comparator,
            module_name: module_name,
            index: index,
            occurred_at: recorded_at
          )
        end
      end

      records = comparator.each_record.to_a
      assert_equal(
        [ "due" ],
        records.map { |record| record.dig("module_decision", "rationale") }.uniq
      )

      report = Hive::Modules::Migration::Report.build(
        record_source: records,
        reviewer: "operator@example.com",
        reviewed_at: START + (10 * DAY),
        generated_at: START + (10 * DAY)
      )

      assert report.eligible?,
             "characterization: legacy v1 counts timestamp spread without decision-class diversity"
      report.payload.fetch("modules").each_value do |summary|
        assert_equal 10, summary.fetch("decision_count")
        assert_equal 9 * DAY, summary.fetch("elapsed_seconds")
      end
    end
  end

  private

  def record_due_decision(comparator, module_name:, index:, occurred_at:)
    architecture = module_name == "architecture-patrol"
    trigger = {
      "kind" => "manual",
      "id" => "#{module_name}-#{index}"
    }
    projection = Hive::Modules::Migration::PatrolDecisionProjection.build(
      module_name: module_name,
      rationale: "due",
      job_id: architecture ? trigger.fetch("id") : nil,
      phase: architecture ? "discovery" : nil
    )
    capture = Hive::Modules::Migration::PatrolCapture.build(
      module_name: module_name,
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: trigger,
      reservation:
        architecture ?
          {
            "kind" => "architecture",
            "id" => trigger.fetch("id"),
            "job_id" => trigger.fetch("id")
          } :
          {
            "kind" => "ordinary",
            "id" => trigger.fetch("id")
          },
      owner: "legacy",
      owner_epoch: 1,
      selection_input:
        architecture ?
          {
            "kind" => "candidate",
            "job_id" => trigger.fetch("id"),
            "phase" => "discovery"
          } :
          {
            "kind" => "operation",
            "operation" => "shadow-comparison"
          },
      selection: projection,
      outcome_class: "completed",
      outcome: { "rationale" => "due" },
      occurred_at: occurred_at,
      recorded_at: occurred_at
    )
    comparator.record!(
      module_name: module_name,
      trigger: trigger,
      legacy_capture: capture,
      module_projection: projection,
      configuration_digest: (architecture ? "b" : "a") * 64,
      occurred_at: occurred_at
    )
  end
end
