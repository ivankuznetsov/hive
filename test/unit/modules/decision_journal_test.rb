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

  def test_receipt_shape_identity_and_timestamp_errors_are_typed
    with_tmp_dir do |root|
      journal = Hive::Modules::DecisionJournal.new(root: root, id_generator: -> { "decision-1" })
      decision = journal.append(attributes)

      assert_raises(Hive::Modules::DecisionJournalError) do
        journal.send(:normalize, attributes.reject { |key, _value| key == "project_id" })
      end
      assert_raises(Hive::Modules::DecisionJournalError) do
        journal.send(:validate!, decision.merge("binding_digest" => "bad"))
      end
      assert_raises(Hive::Modules::DecisionJournalError) do
        journal.send(:validate!, decision.merge("artifacts" => [ "bad" ]))
      end
      assert_raises(Hive::Modules::DecisionJournalError) do
        journal.send(:validate!, decision.merge("evaluated_at" => "not-a-time"))
      end
      assert_raises(Hive::Modules::DecisionJournalError) do
        journal.send(:parse, JSON.pretty_generate(decision), expected_id: decision.fetch("decision_id"))
      end
      assert_raises(Hive::Modules::DecisionJournalError) do
        journal.send(:parse, "{bad", expected_id: decision.fetch("decision_id"))
      end
      assert_raises(Hive::Modules::DecisionJournalError) { journal.send(:decision_path, "bad") }
      assert_raises(Hive::Modules::DecisionJournalError) { journal.send(:timestamp, "not-a-time") }
    end
  end

  def test_filesystem_failures_are_bounded_at_initialization_append_and_lock
    with_tmp_dir do |root|
      with_replaced_singleton_method(
        FileUtils, :mkdir_p, ->(*_args, **_options) { raise Errno::EACCES, "blocked" }
      ) do
        assert_raises(Hive::Modules::DecisionJournalError) do
          Hive::Modules::DecisionJournal.new(root: File.join(root, "unavailable"))
        end
      end

      journal = Hive::Modules::DecisionJournal.new(
        root: File.join(root, "journal"), id_generator: -> { SecureRandom.uuid }
      )
      with_replaced_singleton_method(
        Hive::AtomicFile, :write, ->(*_args, **_options) { raise Errno::ENOSPC, "full" }
      ) do
        assert_raises(Hive::Modules::DecisionJournalError) { journal.append(attributes) }
      end
      unlocked_journal = Hive::Modules::DecisionJournal.new(
        root: File.join(root, "unlocked-journal"), id_generator: -> { SecureRandom.uuid }
      )
      unlocked_journal.define_singleton_method(:with_lock) { |**_options, &block| block.call }
      with_replaced_singleton_method(
        Hive::AtomicFile, :write, ->(*_args, **_options) { raise Errno::ENOSPC, "full" }
      ) do
        error = assert_raises(Hive::Modules::DecisionJournalError) { unlocked_journal.append(attributes) }
        assert_match(/could not be persisted/, error.message)
      end
      with_replaced_singleton_method(
        File, :open, ->(*_args, **_options) { raise Errno::EACCES, "blocked" }
      ) do
        assert_raises(Hive::Modules::DecisionJournalError) { journal.all }
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
