require "test_helper"
require "hive/modules/event_ledger"

class ModulesEventLedgerTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 22, 10, 0, 0)

  def test_record_is_stable_across_restart_and_equivalent_redelivery
    with_tmp_dir do |root|
      ledger = Hive::Modules::EventLedger.new(root: root)
      first = ledger.record(**attributes, recorded_at: NOW)
      second = Hive::Modules::EventLedger.new(root: root).record(
        **attributes, recorded_at: NOW + 30
      )

      assert first.created?
      assert second.duplicate?
      assert_equal first.event, second.event
      assert_equal 1, ledger.all.size
      assert_equal first.event, ledger.fetch(first.event.fetch("event_id"))
    end
  end

  def test_conflicting_idempotency_and_corrupt_evidence_fail_closed
    with_tmp_dir do |root|
      ledger = Hive::Modules::EventLedger.new(root: root)
      event = ledger.record(**attributes, recorded_at: NOW).event

      assert_raises(Hive::Modules::ConflictingEvent) do
        ledger.record(**attributes.merge(payload: { "task_id" => "other" }), recorded_at: NOW + 1)
      end
      File.write(File.join(ledger.events_root, "#{event.fetch('event_id')}.json"), "{")
      assert_raises(Hive::Modules::EventLedgerError) { ledger.all }
    end
  end

  def test_only_schedule_and_three_named_events_are_accepted
    with_tmp_dir do |root|
      ledger = Hive::Modules::EventLedger.new(root: root)
      Hive::Modules::EventLedger::EVENT_NAMES.each_with_index do |name, index|
        result = ledger.record(
          **attributes.merge(event_name: name, idempotency_key: "key-#{index}"),
          recorded_at: NOW
        )
        assert_equal name, result.event.fetch("event_name")
      end
      assert_raises(Hive::Modules::EventLedgerError) do
        ledger.record(**attributes.merge(event_name: "issue.opened"), recorded_at: NOW)
      end
    end
  end

  def test_identity_timestamp_and_canonical_evidence_validation_is_strict
    with_tmp_dir do |root|
      ledger = Hive::Modules::EventLedger.new(root: root)
      assert_raises(Hive::Modules::EventLedgerError) do
        ledger.record(**attributes.merge(source: { type: "task" }), recorded_at: NOW)
      end
      assert_raises(Hive::Modules::EventLedgerError) do
        ledger.record(**attributes.merge(occurred_at: "not-a-time"), recorded_at: NOW)
      end
      assert_raises(Hive::Modules::EventLedgerError) { ledger.fetch("bad") }

      event = ledger.record(**attributes, recorded_at: NOW).event
      path = File.join(ledger.events_root, "#{event.fetch('event_id')}.json")
      File.write(path, JSON.pretty_generate(event))
      assert_raises(Hive::Modules::EventLedgerError) { ledger.fetch(event.fetch("event_id")) }

      malformed_time = event.merge("occurred_at" => "not-a-time")
      File.write(path, Hive::WorkflowPackage::CanonicalJSON.generate(malformed_time))
      assert_raises(Hive::Modules::EventLedgerError) { ledger.fetch(event.fetch("event_id")) }
    end
  end

  def test_filesystem_failures_are_typed_at_initialization_persistence_and_locking
    with_tmp_dir do |root|
      with_replaced_singleton_method(
        FileUtils, :mkdir_p, ->(*_args, **_options) { raise Errno::EACCES, "blocked" }
      ) do
        assert_raises(Hive::Modules::EventLedgerError) do
          Hive::Modules::EventLedger.new(root: File.join(root, "unavailable"))
        end
      end

      ledger = Hive::Modules::EventLedger.new(root: File.join(root, "ledger"))
      with_replaced_singleton_method(
        Hive::AtomicFile, :write, ->(*_args, **_options) { raise Errno::ENOSPC, "full" }
      ) do
        assert_raises(Hive::Modules::EventLedgerError) do
          ledger.record(**attributes, recorded_at: NOW)
        end
      end
      unlocked_ledger = Hive::Modules::EventLedger.new(root: File.join(root, "unlocked-ledger"))
      unlocked_ledger.define_singleton_method(:with_lock) { |**_options, &block| block.call }
      with_replaced_singleton_method(
        Hive::AtomicFile, :write, ->(*_args, **_options) { raise Errno::ENOSPC, "full" }
      ) do
        error = assert_raises(Hive::Modules::EventLedgerError) do
          unlocked_ledger.record(**attributes, recorded_at: NOW)
        end
        assert_match(/could not be persisted/, error.message)
      end
      with_replaced_singleton_method(
        File, :open, ->(*_args, **_options) { raise Errno::EACCES, "blocked" }
      ) do
        assert_raises(Hive::Modules::EventLedgerError) { ledger.all }
      end
    end
  end

  def test_cursor_and_schedule_index_rebuilds_are_strict_and_deterministic
    with_tmp_dir do |root|
      ledger = Hive::Modules::EventLedger.new(root: root)
      assert_raises(Hive::Modules::EventLedgerError) { ledger.events_after(-1) }
      assert_raises(Hive::Modules::EventLedgerError) { ledger.events_after("bad") }

      two_hours_ago = NOW - 7200
      one_hour_ago = NOW - 3600
      [ two_hours_ago, one_hour_ago ].each_with_index do |occurred_at, index|
        ledger.record(
          **attributes.merge(
            event_name: "schedule",
            occurred_at: occurred_at,
            idempotency_key: "schedule-#{index}",
            payload: { "schedule" => "0 * * * *" }
          ),
          recorded_at: NOW
        )
      end

      index_path = File.join(ledger.events_root, "index.json")
      File.write(index_path, "{")
      assert_equal 2, ledger.all.size
      assert_equal one_hour_ago, ledger.latest_schedule("0 * * * *")

      index = JSON.parse(File.binread(index_path))
      index["latest_schedules"]["0 * * * *"] = "not-a-time"
      File.binwrite(
        index_path, Hive::WorkflowPackage::CanonicalJSON.generate(index)
      )
      assert_raises(Hive::Modules::EventLedgerError) do
        ledger.latest_schedule("0 * * * *")
      end
    end
  end

  private

  def attributes
    {
      project_id: "project-1", project: "demo", event_name: "task.completed",
      occurred_at: NOW, source: { type: "task", id: "task-7" },
      idempotency_key: "task-7:generation-2:completed", payload: { "task_id" => "task-7" }
    }
  end
end
