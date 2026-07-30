require "test_helper"
require "json_schemer"
require "hive/modules/migration/shadow_comparator"

class ModulesMigrationShadowComparatorTest < Minitest::Test
  include HiveTestHelper

  START = Time.utc(2026, 7, 1)

  def test_normalizes_representation_fields_and_is_idempotent
    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      trigger = direct_trigger("tick-1")
      capture = capture_for(
        "patrol", trigger,
        { "status" => "due", "owner" => "legacy", "duration_ms" => 10 }
      )
      record = comparator.record!(
        module_name: "patrol", trigger: trigger, legacy_capture: capture,
        module_projection: projection_for("patrol", trigger, "due"),
        configuration_digest: "a" * 64, occurred_at: START, comparable: false
      )
      repeated = comparator.record!(
        module_name: "patrol", trigger: trigger, legacy_capture: capture,
        module_projection: projection_for("patrol", trigger, "due"),
        configuration_digest: "a" * 64, occurred_at: START, comparable: false
      )

      assert_empty record.fetch("unexplained_differences")
      refute record.fetch("comparable"), "explicitly noncomparable evidence must not count toward cutover"
      assert_equal "legacy_mutator_capture", record.fetch("evidence_source")
      assert_equal record, repeated
      assert_equal 1, comparator.each_record("patrol").count
    end
  end

  def test_published_schema_enforces_exact_capture_and_projection_shapes
    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      trigger = direct_trigger("tick-1")
      capture = capture_for(
        "patrol", trigger, { "status" => "due" }
      )
      record = comparator.record!(
        module_name: "patrol",
        trigger: trigger,
        legacy_capture: capture,
        module_projection: projection_for("patrol", trigger, "due"),
        configuration_digest: "a" * 64,
        occurred_at: START
      )
      schema = JSONSchemer.schema(
        JSON.parse(
          File.read(
            File.join(
              Hive::Schemas.schema_dir,
              "hive-module-shadow-decision.v2.json"
            )
          )
        )
      )

      assert schema.valid?(record), schema.validate(record).to_a.inspect
      malformed = [
        record.merge(
          "module_decision" =>
            record.fetch("module_decision").reject {
              |key, _value| key == "phase"
            }
        ),
        record.merge(
          "module_decision" =>
            record.fetch("module_decision").merge("extra" => true)
        ),
        record.merge(
          "legacy_capture" =>
            record.fetch("legacy_capture").merge("extra" => true)
        ),
        record.merge(
          "legacy_capture" =>
            record.fetch("legacy_capture").merge(
              "selection" =>
                record.dig("legacy_capture", "selection").merge(
                  "extra" => true
                )
            )
        )
      ]
      malformed.each do |value|
        refute schema.valid?(value), value.inspect
      end
    end
  end

  def test_shadow_identity_time_and_conflicting_replay_fail_closed
    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      trigger = direct_trigger("same")
      capture = capture_for(
        "patrol", trigger,
        { "status" => "due" }
      )
      legacy_receipt = receipt_for(capture, "legacy", authority: "legacy")
      module_receipt = receipt_for(
        capture, "module", authority: "shadow", status: "denied"
      )
      attributes = {
        module_name: "patrol", trigger: trigger, legacy_capture: capture,
        module_projection: projection_for("patrol", trigger, "not_due"),
        configuration_digest: "a" * 64, occurred_at: START,
        explained_paths: [ "$.rationale" ],
        legacy_effects: [ legacy_receipt, legacy_receipt ],
        module_effects: [ module_receipt ]
      }
      record = comparator.record!(**attributes)
      assert_equal [ "$.rationale" ],
                   record.fetch("explained_differences").map {
                     |row| row.fetch("path")
                   }
      assert_empty record.fetch("unexplained_differences")
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
        comparator.record!(
          **attributes.merge(module_projection: { "rows" => [] })
        )
      end
      assert_raises(Hive::ConfigError) do
        comparator.record!(**attributes.merge(legacy_capture: {}))
      end
    end
  end

  def test_shadow_projection_identity_and_symbolic_triggers_fail_closed_or_normalize
    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      trigger = {
        "kind" => :manual,
        "id" => "tick-1",
        "duration_ms" => 17
      }
      capture = capture_for(
        "patrol", direct_trigger("tick-1"), { "status" => "due" }
      )

      record = comparator.record!(
        module_name: "patrol", trigger: trigger, legacy_capture: capture,
        module_projection: projection_for("patrol", trigger, "due"),
        configuration_digest: "a" * 64, occurred_at: START
      )
      assert_equal direct_trigger("tick-1"), record.fetch("trigger")

      assert_raises(Hive::ConfigError) do
        comparator.record!(
          module_name: "patrol", trigger: direct_trigger("other"),
          module_projection:
            projection_for(
              "architecture-patrol", direct_trigger("other"), "due"
            ),
          configuration_digest: "a" * 64, occurred_at: START
        )
      end

      assert_raises(Hive::ConfigError) do
        comparator.record!(
          module_name: "patrol",
          trigger: direct_trigger("unknown").merge("metadata" => "symbolic"),
          module_projection:
            projection_for("patrol", direct_trigger("unknown"), "due"),
          configuration_digest: "a" * 64,
          occurred_at: START
        )
      end

      assert_raises(Hive::Modules::Migration::ShadowComparator::IdentityConflict) do
        comparator.record!(
          module_name: "patrol", trigger: trigger, legacy_capture: capture,
          module_projection: projection_for("patrol", trigger, "not_due"),
          configuration_digest: "a" * 64, occurred_at: START
        )
      end

      differing_trigger = direct_trigger("different")
      comparator.record!(
        module_name: "patrol", trigger: differing_trigger,
        legacy_capture: capture_for("patrol", differing_trigger, { "status" => "due" }),
        module_projection: projection_for("patrol", differing_trigger, "not_due"),
        configuration_digest: "a" * 64, occurred_at: START,
        explained_paths: [ "$.rationale" ]
      )
      assert_equal 2, comparator.each_record("patrol").count
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
      trigger = direct_trigger("tick-1")
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
          module_projection: projection_for("patrol", trigger, "due"),
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
          module_projection: projection_for("patrol", trigger, "due"),
          configuration_digest: "a" * 64,
          occurred_at: START,
          module_effects: [ foreign_effect ]
        )
      end

      comparator.record!(
        module_name: "patrol",
        trigger: trigger,
        legacy_capture: patrol_capture,
        module_projection: projection_for("patrol", trigger, "due"),
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
      trigger = direct_trigger("tick-1")
      capture = capture_for("patrol", trigger, { "status" => "due" })
      record = comparator.record!(
        module_name: "patrol",
        trigger: trigger,
        legacy_capture: capture,
        module_projection: projection_for("patrol", trigger, "due"),
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
      trigger = direct_trigger("tick-1")
      decision = { "status" => "due" }

      assert_raises(Hive::ConfigError) do
        comparator.record!(
          module_name: "patrol",
          trigger: trigger,
          legacy_capture: capture_for("patrol", trigger, decision),
          module_projection: projection_for("patrol", trigger, "due"),
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
        trigger = direct_trigger("tick-1")
        decision = { "status" => "due" }
        capture = capture_for("patrol", trigger, decision)
        record = comparator.record!(
          module_name: "patrol",
          trigger: trigger,
          legacy_capture: capture,
          module_projection: projection_for("patrol", trigger, "due"),
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
      trigger = direct_trigger("tick-1")
      decision = { "status" => "due" }
      capture = capture_for("patrol", trigger, decision)
      record = comparator.record!(
        module_name: "patrol",
        trigger: trigger,
        legacy_capture: capture,
        module_projection: projection_for("patrol", trigger, "due"),
        configuration_digest: "a" * 64,
        occurred_at: START
      )
      original = File.join(root, "patrol", "#{record.fetch('decision_id')}.json")
      File.rename(original, File.join(root, "patrol", "#{'f' * 64}.json"))

      assert_raises(Hive::ConfigError) { comparator.each_record("patrol").to_a }
    end
  end

  def test_history_pages_are_lexicographic_and_restart_portable
    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      3.times do |index|
        trigger = direct_trigger("tick-#{index}")
        decision = { "status" => "due", "index" => index }
        comparator.record!(
          module_name: "patrol",
          trigger: trigger,
          legacy_capture: capture_for("patrol", trigger, decision),
          module_projection: projection_for("patrol", trigger, "due"),
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
        trigger = direct_trigger("tick-#{index}")
        decision = { "status" => "due" }
        comparator.record!(
          module_name: module_name,
          trigger: trigger,
          legacy_capture: capture_for(module_name, trigger, decision),
          module_projection:
            projection_for(module_name, trigger, "due"),
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
    selection = projection_for(
      module_name,
      trigger,
      decision.fetch("status", "due") == "skip" ? "not_due" : "due"
    )
    selection_input = if module_name == "patrol"
      {
        "kind" => "operation",
        "operation" => "shadow-comparison"
      }
    else
      {
        "kind" => "candidate",
        "job_id" => trigger.fetch("id"),
        "phase" => "discovery"
      }
    end
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: module_name,
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: trigger,
      reservation:
        module_name == "patrol" ?
          {
            "kind" => "ordinary",
            "id" => trigger.fetch("id")
          } :
          {
            "kind" => "architecture",
            "id" => trigger.fetch("id"),
            "job_id" => trigger.fetch("id")
          },
      owner: "legacy",
      owner_epoch: 1,
      selection_input: selection_input,
      selection: selection,
      outcome_class: "completed",
      outcome: {
        "rationale" =>
          decision.fetch("reason", decision.fetch("status", "completed")).to_s
      },
      occurred_at: START,
      recorded_at: START
    )
  end

  def direct_trigger(id)
    {
      "kind" => "manual",
      "id" => id
    }
  end

  def projection_for(module_name, trigger, rationale)
    attributes = {
      module_name: module_name,
      rationale: rationale
    }
    if module_name == "architecture-patrol"
      attributes[:job_id] = trigger.fetch("id")
      attributes[:phase] = "discovery"
    end
    Hive::Modules::Migration::PatrolDecisionProjection.build(**attributes)
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
      outcome: { "transition_status" => "applied" },
      recorded_at: START
    )
  end
end
