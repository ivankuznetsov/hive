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
      assert_equal 1, comparator.each_record("patrol").count
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
        record_source: comparator.each_record, reviewer: "operator@example.com",
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
        record_source: comparator.each_record, reviewer: "operator@example.com",
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
      assert_raises(Hive::ConfigError) { comparator.each_record("patrol").to_a }

      File.write(File.join(module_root, "bad.json"), JSON.generate(
        "schema" => "wrong", "schema_version" => 1, "module" => "patrol"
      ))
      assert_raises(Hive::ConfigError) { comparator.each_record("patrol").to_a }
    end
  end

  def test_shadow_binding_and_bounded_history_guards_fail_closed
    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      trigger = { "id" => "tick-1" }
      patrol_capture = capture_for(
        "patrol", trigger, { "status" => "due" }
      )
      foreign_capture = capture_for(
        "architecture-patrol", trigger, { "status" => "due" }
      )
      assert_raises(Hive::ConfigError) do
        comparator.record!(
          module_name: "patrol",
          trigger: trigger,
          legacy_capture: foreign_capture,
          module_decision: { "status" => "due" },
          configuration_digest: "a" * 64,
          occurred_at: START
        )
      end

      foreign_effect = receipt_for(
        foreign_capture, "foreign", authority: "shadow"
      )
      assert_raises(Hive::ConfigError) do
        comparator.record!(
          module_name: "patrol",
          trigger: trigger,
          legacy_capture: patrol_capture,
          module_decision: { "status" => "due" },
          configuration_digest: "a" * 64,
          occurred_at: START,
          module_effects: [ foreign_effect ]
        )
      end

      comparator.record!(
        module_name: "patrol",
        trigger: trigger,
        legacy_capture: patrol_capture,
        module_decision: { "status" => "due" },
        configuration_digest: "a" * 64,
        occurred_at: START
      )
      with_constant(
        Hive::Modules::Migration::ShadowComparator,
        :MAX_RECORDS,
        0
      ) do
        assert_raises(Hive::ConfigError) do
          comparator.each_record("patrol").to_a
        end
      end

      hostile_key = Object.new
      hostile_key.define_singleton_method(:to_s) do
        raise TypeError, "not a string key"
      end
      assert_raises(Hive::ConfigError) do
        comparator.validate_record!({ hostile_key => true })
      end
      hostile = Object.new
      hostile.define_singleton_method(:[]) do |_key|
        raise NoMethodError, "corrupt mapping"
      end
      refute comparator.send(:valid_record?, hostile)
    end
  end

  def test_shadow_reader_detects_link_inode_size_and_byte_races
    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      path = File.join(root, "patrol", "#{'a' * 64}.json")
      FileUtils.mkdir_p(File.dirname(path))
      target = File.join(root, "target")
      File.write(target, "{}")
      File.symlink(target, path)
      assert_raises(Hive::ConfigError) do
        comparator.send(:read, path)
      end
    end

    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      trigger = { "id" => "tick-1" }
      capture = capture_for("patrol", trigger, { "status" => "due" })
      record = comparator.record!(
        module_name: "patrol",
        trigger: trigger,
        legacy_capture: capture,
        module_decision: { "status" => "due" },
        configuration_digest: "a" * 64,
        occurred_at: START
      )
      path = File.join(
        root, "patrol", "#{record.fetch('decision_id')}.json"
      )
      File.write(path, JSON.pretty_generate(record))
      assert_raises(Hive::ConfigError) do
        comparator.send(:read, path)
      end

      missing = File.join(root, "patrol", "#{'f' * 64}.json")
      assert_raises(Hive::ConfigError) do
        comparator.send(:read, missing)
      end
      assert_raises(Hive::ConfigError) do
        comparator.send(:read, File.join(root, "unknown", "bad.json"))
      end
    end

    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      path = File.join(root, "patrol", "#{'a' * 64}.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{}")
      before = File.lstat(path)
      wrong_stat = File.stat(__FILE__)
      oversized = "x" * (
        Hive::Modules::Migration::ShadowComparator::MAX_RECORD_BYTES + 1
      )
      reads = [ [ wrong_stat, "{}" ], [ before, oversized ] ]
      original = File.method(:open)
      replacement = lambda do |candidate, *args, **kwargs, &block|
        unless candidate == path
          next original.call(
            candidate, *args, **kwargs, &block
          )
        end

        stat, bytes = reads.shift
        proxy = Object.new
        proxy.define_singleton_method(:stat) { stat }
        proxy.define_singleton_method(:read) { |_limit| bytes }
        block.call(proxy)
      end
      with_replaced_singleton_method(
        File, :open, replacement
      ) do
        2.times do
          assert_raises(Hive::ConfigError) do
            comparator.send(:read, path)
          end
        end
      end
    end
  end

  def test_shadow_store_rejects_symlinked_module_directory
    with_tmp_dir do |root|
      outside = File.join(root, "outside")
      FileUtils.mkdir_p(outside)
      File.symlink(outside, File.join(root, "patrol"))
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      trigger = { "id" => "tick-1" }
      decision = { "status" => "due" }

      assert_raises(Hive::ConfigError) do
        comparator.record!(
          module_name: "patrol",
          trigger: trigger,
          legacy_capture: capture_for("patrol", trigger, decision),
          module_decision: decision,
          configuration_digest: "a" * 64,
          occurred_at: START
        )
      end
      assert_empty Dir.children(outside)
    end
  end

  def test_reader_recomputes_semantics_and_binds_filename
    %w[
      decision_id trigger_digest comparable explained_differences
      unexplained_differences duplicate_effects
    ].each do |field|
      with_tmp_dir do |root|
        comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
        trigger = { "id" => "tick-1" }
        decision = { "status" => "due" }
        capture = capture_for("patrol", trigger, decision)
        record = comparator.record!(
          module_name: "patrol",
          trigger: trigger,
          legacy_capture: capture,
          module_decision: decision,
          configuration_digest: "a" * 64,
          occurred_at: START
        )
        path = File.join(root, "patrol", "#{record.fetch('decision_id')}.json")
        changed = JSON.parse(File.binread(path))
        changed[field] = case field
        when "decision_id", "trigger_digest" then "f" * 64
        when "comparable" then false
        else [ { "forged" => true } ]
        end
        File.write(
          path,
          Hive::WorkflowPackage::CanonicalJSON.generate(changed)
        )

        assert_raises(Hive::ConfigError, field) do
          comparator.each_record("patrol").to_a
        end
      end
    end

    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      trigger = { "id" => "tick-1" }
      decision = { "status" => "due" }
      capture = capture_for("patrol", trigger, decision)
      record = comparator.record!(
        module_name: "patrol",
        trigger: trigger,
        legacy_capture: capture,
        module_decision: decision,
        configuration_digest: "a" * 64,
        occurred_at: START
      )
      original = File.join(root, "patrol", "#{record.fetch('decision_id')}.json")
      File.rename(original, File.join(root, "patrol", "#{'f' * 64}.json"))

      assert_raises(Hive::ConfigError) { comparator.each_record("patrol").to_a }
    end
  end

  def test_report_revalidates_raw_comparison_records
    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      trigger = { "id" => "tick-1" }
      decision = { "status" => "due" }
      capture = capture_for("patrol", trigger, decision)
      record = comparator.record!(
        module_name: "patrol",
        trigger: trigger,
        legacy_capture: capture,
        module_decision: decision,
        configuration_digest: "a" * 64,
        occurred_at: START
      )
      forged = record.merge("duplicate_effects" => [ "intent-forged" ])

      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::Report.build(
          record_source: [ forged ],
          reviewer: "operator@example.com",
          reviewed_at: START
        )
      end
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
      invalid_json = File.join(root, "invalid-json.json")
      File.write(invalid_json, "{bad")
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::Report.load(invalid_json)
      end

      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::Report.build(
          record_source: [], reviewer: "operator", reviewed_at: "not-a-time"
        )
      end

      report = Hive::Modules::Migration::Report.build(
        record_source: [], reviewer: "", reviewed_at: START, generated_at: START
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

  def test_report_bounds_external_streams_and_collapses_configuration_changes
    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      records = 2.times.map do |index|
        trigger = { "id" => "tick-#{index}" }
        decision = { "status" => "due" }
        comparator.record!(
          module_name: "patrol",
          trigger: trigger,
          legacy_capture: capture_for("patrol", trigger, decision),
          module_decision: decision,
          configuration_digest: (index.zero? ? "a" : "b") * 64,
          occurred_at: START + index
        )
      end
      report = Hive::Modules::Migration::Report.build(
        record_source: records,
        reviewer: "operator",
        reviewed_at: START + 10
      )
      assert_nil report.payload.dig(
        "modules", "patrol", "configuration_digest"
      )
      assert_includes report.blockers, "patrol:configuration_changed"

      with_constant(
        Hive::Modules::Migration::ShadowComparator,
        :MAX_RECORDS,
        1
      ) do
        assert_raises(Hive::ConfigError) do
          Hive::Modules::Migration::Report.build(
            record_source: records,
            reviewer: "operator",
            reviewed_at: START + 10
          )
        end
      end
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::Report.build(
          record_source: Object.new,
          reviewer: "operator",
          reviewed_at: START
        )
      end
    end
  end

  def test_history_pages_are_lexicographic_and_restart_portable
    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      3.times do |index|
        trigger = { "id" => "tick-#{index}" }
        decision = { "status" => "due", "index" => index }
        comparator.record!(
          module_name: "patrol",
          trigger: trigger,
          legacy_capture: capture_for("patrol", trigger, decision),
          module_decision: decision,
          configuration_digest: "a" * 64,
          occurred_at: START + index
        )
      end

      first = comparator.records_page(module_name: "patrol", limit: 1)
      assert_equal 1, first.records.size
      refute_nil first.next_cursor
      restarted = Hive::Modules::Migration::ShadowComparator.new(root: root)
      second = restarted.records_page(
        module_name: "patrol", limit: 2, cursor: first.next_cursor
      )
      assert_equal 2, second.records.size
      assert_nil second.next_cursor
      ids = (first.records + second.records).map { |record| record.fetch("decision_id") }
      assert_equal ids.sort, ids
      refute_respond_to comparator, :records
      assert_raises(Hive::ConfigError) do
        comparator.records_page(module_name: "unknown", limit: 1)
      end
      assert_raises(Hive::ConfigError) do
        comparator.records_page(module_name: "patrol", limit: 0)
      end
      assert_raises(Hive::ConfigError) do
        comparator.records_page(module_name: "patrol", limit: "many")
      end
    end
  end

  def test_history_rejects_excess_before_reading_record_bodies
    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      2.times do |index|
        module_name = index.zero? ? "patrol" : "architecture-patrol"
        trigger = { "id" => "tick-#{index}" }
        decision = { "status" => "due" }
        comparator.record!(
          module_name: module_name,
          trigger: trigger,
          legacy_capture: capture_for(module_name, trigger, decision),
          module_decision: decision,
          configuration_digest: "a" * 64,
          occurred_at: START + index
        )
      end
      reads = 0
      original = comparator.method(:read)
      comparator.define_singleton_method(:read) do |path|
        reads += 1
        original.call(path)
      end

      with_constant(
        Hive::Modules::Migration::ShadowComparator,
        :MAX_RECORDS,
        1
      ) do
        assert_raises(Hive::ConfigError) { comparator.each_record.to_a }
      end
      assert_equal 0, reads
    end
  end

  def test_report_consumes_an_each_only_source
    source = Object.new
    source.define_singleton_method(:each) { |&block| block && nil }
    source.define_singleton_method(:to_a) do
      raise "report materialized its source"
    end

    report = Hive::Modules::Migration::Report.build(
      record_source: source,
      reviewer: "operator",
      reviewed_at: START
    )
    refute report.eligible?
  end

  private

  def with_constant(owner, name, replacement)
    original = owner.const_get(name, false)
    owner.send(:remove_const, name)
    owner.const_set(name, replacement)
    yield
  ensure
    owner.send(:remove_const, name) if owner.const_defined?(name, false)
    owner.const_set(name, original)
  end

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
