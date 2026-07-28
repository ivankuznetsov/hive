require "test_helper"
require "hive/modules/migration/report"
require "hive/modules/migration/shadow_comparator"

class ModulesMigrationShadowComparatorTest < Minitest::Test
  include HiveTestHelper

  START = Time.utc(2026, 7, 1)

  def test_normalizes_representation_fields_and_is_idempotent
    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      trigger = { "id" => "tick-1" }
      capture = capture_for(
        "patrol", trigger,
        { "status" => "due", "owner" => "legacy", "duration_ms" => 10 }
      )
      record = comparator.record!(
        module_name: "patrol", trigger: trigger, legacy_capture: capture,
        module_decision: { "status" => "due", "engine" => "module" },
        configuration_digest: "a" * 64, occurred_at: START, comparable: false
      )
      repeated = comparator.record!(
        module_name: "patrol", trigger: trigger, legacy_capture: capture,
        module_decision: { "status" => "due", "engine" => "module" },
        configuration_digest: "a" * 64, occurred_at: START, comparable: false
      )

      assert_empty record.fetch("unexplained_differences")
      refute record.fetch("comparable"), "explicitly noncomparable evidence must not count toward cutover"
      assert_equal "legacy_mutator_capture", record.fetch("evidence_source")
      assert_equal record, repeated
      assert_equal 1, comparator.records("patrol").length
    end
  end

  def test_report_requires_real_window_counts_parity_no_duplicates_and_review
    with_tmp_dir do |root|
      captured_at = START
      comparator = Hive::Modules::Migration::ShadowComparator.new(
        root: root, clock: -> { captured_at }
      )
      10.times do |index|
        captured_at = START + (index * 24 * 60 * 60)
        %w[patrol architecture-patrol].each do |module_name|
          trigger = { "id" => "#{module_name}-#{index}", "snapshot" => index }
          decision = { "status" => "due", "reason" => "matched" }
          capture = capture_for(module_name, trigger, decision)
          comparator.record!(
            module_name: module_name,
            trigger: trigger,
            legacy_capture: capture,
            module_decision: decision,
            configuration_digest: "#{module_name == 'patrol' ? 'a' : 'b'}" * 64,
            occurred_at: START + (index * 24 * 60 * 60),
            legacy_effects: [
              receipt_for(capture, "effect-#{index}", authority: "legacy")
            ]
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

      captured_at = reviewed_at
      trigger = { "id" => "mismatch" }
      capture = capture_for("patrol", trigger, { "status" => "due" })
      comparator.record!(
        module_name: "patrol", trigger: trigger,
        legacy_capture: capture, module_decision: { "status" => "skip" },
        configuration_digest: "a" * 64, occurred_at: reviewed_at,
        module_effects: [
          receipt_for(capture, "unexpected-pr", authority: "shadow", status: "denied")
        ]
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

  def test_shadow_identity_time_and_conflicting_replay_fail_closed
    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      trigger = { "id" => "same" }
      capture = capture_for(
        "patrol", trigger,
        { "rows" => [ "due", { "value" => 1 } ] }
      )
      legacy_receipt = receipt_for(capture, "legacy", authority: "legacy")
      module_receipt = receipt_for(
        capture, "module", authority: "shadow", status: "denied"
      )
      attributes = {
        module_name: "patrol", trigger: trigger, legacy_capture: capture,
        module_decision: { "rows" => [ :skip, { "value" => 2 } ] },
        configuration_digest: "a" * 64, occurred_at: START,
        explained_paths: [ "$.rows[0]" ],
        legacy_effects: [ legacy_receipt, legacy_receipt ],
        module_effects: [ module_receipt ]
      }
      record = comparator.record!(**attributes)
      assert_equal [ "$.rows[0]" ], record.fetch("explained_differences").map { |row| row.fetch("path") }
      assert_equal [ "$.rows[1].value" ], record.fetch("unexplained_differences").map { |row| row.fetch("path") }
      assert_equal 2, record.fetch("duplicate_effects").size

      assert_raises(Hive::ConfigError) do
        comparator.record!(**attributes.merge(module_name: "unknown"))
      end
      assert_raises(Hive::ConfigError) do
        comparator.record!(**attributes.merge(configuration_digest: "short"))
      end
      assert_raises(Hive::ConfigError) do
        comparator.record!(**attributes.merge(occurred_at: "not-a-time"))
      end
      assert_raises(Hive::ConfigError) do
        comparator.record!(**attributes.merge(module_decision: { "rows" => [] }))
      end
      assert_raises(Hive::ConfigError) do
        comparator.record!(**attributes.merge(legacy_capture: {}))
      end
    end
  end

  def test_shadow_reader_rejects_malformed_or_noncanonical_evidence
    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      module_root = File.join(root, "patrol")
      FileUtils.mkdir_p(module_root)
      File.write(File.join(module_root, "bad.json"), "{bad")
      assert_raises(Hive::ConfigError) { comparator.records("patrol") }

      File.write(File.join(module_root, "bad.json"), JSON.generate(
        "schema" => "wrong", "schema_version" => 1, "module" => "patrol"
      ))
      assert_raises(Hive::ConfigError) { comparator.records("patrol") }
    end
  end

  def test_report_loading_and_time_validation_are_strict
    with_tmp_dir do |root|
      missing = File.join(root, "missing.json")
      assert_raises(Hive::ConfigError) { Hive::Modules::Migration::Report.load(missing) }

      malformed = File.join(root, "malformed.json")
      File.write(malformed, Hive::Modules::Migration::Report.canonical(
        "schema" => "hive-module-migration-report", "schema_version" => 1,
        "eligible" => false, "modules" => nil, "blockers" => []
      ))
      assert_raises(Hive::ConfigError) { Hive::Modules::Migration::Report.load(malformed) }

      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::Report.build(
          records: [], reviewer: "operator", reviewed_at: "not-a-time"
        )
      end

      report = Hive::Modules::Migration::Report.build(
        records: [], reviewer: "", reviewed_at: START, generated_at: START
      )
      path = File.join(root, "report.json")
      report.write(path)
      loaded = Hive::Modules::Migration::Report.load(path)
      refute loaded.eligible?
      assert_includes loaded.blockers, "reviewer_signoff_missing"
      assert_equal report.configuration_digests, loaded.configuration_digests

      payload = JSON.parse(File.binread(path))
      File.write(path, JSON.pretty_generate(payload))
      assert_raises(Hive::ConfigError) { Hive::Modules::Migration::Report.load(path) }
    end
  end

  def test_report_shape_guard_handles_hash_like_objects_that_break_mid_validation
    liar = Object.new
    liar.define_singleton_method(:is_a?) { |klass| klass == Hash || super(klass) }
    payload = {
      "schema" => "hive-module-migration-report", "schema_version" => 1,
      "eligible" => false, "modules" => liar, "blockers" => []
    }

    refute Hive::Modules::Migration::Report.valid_payload?(payload)
  end

  private

  def capture_for(module_name, trigger, decision)
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: module_name,
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: trigger,
      reservation: {
        "kind" => module_name == "patrol" ? "ordinary" : "architecture",
        "id" => trigger.fetch("id")
      },
      owner: "legacy",
      owner_epoch: 1,
      decision_class: decision.fetch("status", "due"),
      decision: decision,
      occurred_at: START,
      recorded_at: START
    )
  end

  def receipt_for(capture, id, authority:, status: "committed")
    intent = Hive::Modules::Migration::EffectIntent.build(
      module_name: capture.module_name,
      occurrence_id: capture.occurrence_id,
      authority: authority,
      owner_epoch: capture.owner_epoch,
      sink: "state",
      target: id,
      idempotency_key: id,
      capability: "filesystem_write",
      created_at: START
    )
    Hive::Modules::Migration::EffectReceipt.build(
      intent: intent,
      status: status,
      outcome: { "attempted" => true },
      recorded_at: START
    )
  end
end
