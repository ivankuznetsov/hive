require "test_helper"
require "hive/modules/migration/report"
require "hive/modules/migration/shadow_comparator"

class ModulesMigrationShadowComparatorTest < Minitest::Test
  include HiveTestHelper

  START = Time.utc(2026, 7, 1)

  def test_normalizes_representation_fields_and_is_idempotent
    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      record = comparator.record!(
        module_name: "patrol", trigger: { "id" => "tick-1" },
        legacy_decision: { status: :due, owner: "legacy", duration_ms: 10 },
        module_decision: { "status" => "due", "engine" => "module" },
        configuration_digest: "a" * 64, occurred_at: START
      )
      repeated = comparator.record!(
        module_name: "patrol", trigger: { "id" => "tick-1" },
        legacy_decision: { status: :due, owner: "legacy", duration_ms: 99 },
        module_decision: { "status" => "due", "engine" => "module" },
        configuration_digest: "a" * 64, occurred_at: START
      )

      assert_empty record.fetch("unexplained_differences")
      assert_equal record, repeated
      assert_equal 1, comparator.records("patrol").length
    end
  end

  def test_report_requires_real_window_counts_parity_no_duplicates_and_review
    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      %w[patrol architecture-patrol].each do |module_name|
        10.times do |index|
          comparator.record!(
            module_name: module_name,
            trigger: { "id" => "#{module_name}-#{index}", "snapshot" => index },
            legacy_decision: { "status" => "due", "reason" => "matched" },
            module_decision: { "status" => "due", "reason" => "matched" },
            configuration_digest: "#{module_name == 'patrol' ? 'a' : 'b'}" * 64,
            occurred_at: START + (index * 24 * 60 * 60),
            legacy_effects: [ "effect-#{index}" ]
          )
        end
      end
      reviewed_at = START + (10 * 24 * 60 * 60)
      report = Hive::Modules::Migration::Report.build(
        records: comparator.records, reviewer: "operator@example.com",
        reviewed_at: reviewed_at, generated_at: reviewed_at
      )

      assert report.eligible?, report.blockers.inspect
      assert_equal 10, report.payload.dig("modules", "patrol", "decision_count")
      assert_operator report.payload.dig("modules", "architecture-patrol", "elapsed_seconds"), :>=,
                      7 * 24 * 60 * 60

      comparator.record!(
        module_name: "patrol", trigger: { "id" => "mismatch" },
        legacy_decision: { "status" => "due" }, module_decision: { "status" => "skip" },
        configuration_digest: "a" * 64, occurred_at: reviewed_at,
        module_effects: [ "unexpected-pr" ]
      )
      blocked = Hive::Modules::Migration::Report.build(
        records: comparator.records, reviewer: "operator@example.com",
        reviewed_at: reviewed_at + 1, generated_at: reviewed_at + 1
      )
      refute blocked.eligible?
      assert_includes blocked.blockers, "patrol:unexplained_differences"
      assert_includes blocked.blockers, "patrol:duplicate_effects"
    end
  end
end
