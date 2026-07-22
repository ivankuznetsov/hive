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

  private

  def attributes
    {
      project_id: "project-1", project: "demo", event_name: "task.completed",
      occurred_at: NOW, source: { type: "task", id: "task-7" },
      idempotency_key: "task-7:generation-2:completed", payload: { "task_id" => "task-7" }
    }
  end
end
