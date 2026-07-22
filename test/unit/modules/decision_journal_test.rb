require "test_helper"
require "hive/modules/decision_journal"

class ModulesDecisionJournalTest < Minitest::Test
  include HiveTestHelper

  def test_append_is_immutable_queryable_and_strict
    with_tmp_dir do |root|
      counter = 0
      journal = Hive::Modules::DecisionJournal.new(
        root: root, id_generator: -> { counter += 1; "decision-#{counter}" }
      )
      launch = journal.append(attributes)
      skip = journal.append(attributes.merge("outcome" => "skip", "reason" => "duplicate"))

      assert_match(/\Adec-[0-9a-f]{64}\z/, launch.fetch("decision_id"))
      assert journal.admitted?(module_name: "demo", hook_id: "task", event_id: event_id)
      assert_equal [ launch, skip ], journal.for_binding(
        module_name: "demo", hook_id: "task", event_id: event_id
      )
      assert_raises(Hive::Modules::DecisionJournalError) do
        journal.append(attributes.merge("reason" => "raw stderr token=secret"))
      end
    end
  end

  private

  def event_id = "evt-#{'a' * 64}"

  def attributes
    {
      "project_id" => "project-1", "project" => "demo", "module" => "demo",
      "hook" => "task", "event_id" => event_id, "event_name" => "task.completed",
      "evaluated_at" => Time.utc(2026, 7, 22), "outcome" => "launch", "reason" => "admitted",
      "binding_digest" => "b" * 64, "cursor_before" => nil, "cursor_after" => event_id,
      "module_generation" => "c" * 40, "configuration_digest" => "d" * 64,
      "grant_digest" => "e" * 64, "concurrency" => "drop", "attempt_id" => "attempt-1",
      "task_id" => nil, "artifacts" => [], "retry" => nil
    }
  end
end
