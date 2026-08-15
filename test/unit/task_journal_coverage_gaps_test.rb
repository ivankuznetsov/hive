require "test_helper"
require "hive/task_journal"

class TaskJournalCoverageGapsTest < Minitest::Test
  def test_binding_coercion_and_activity_identifiers_fail_closed
    validator = Hive::TaskJournal::Validator.new

    assert_raises(Hive::TaskJournal::AttemptMismatch) do
      validator.validate_binding!(
        task: { slug: "task" }, stage: "4-execute", attempt_id: "attempt",
        task_generation: Object.new
      )
    end

    invalid_kind = {
      "payload" => { "activity_kind" => "unknown" },
      "provenance" => { "source" => "command_service" }
    }
    assert_raises(Hive::TaskJournal::InvalidRecord) do
      validator.send(:validate_activity!, invalid_kind)
    end

    invalid_operation = {
      "payload" => { "activity_kind" => "answer_recorded", "operation_id" => "bad id" },
      "provenance" => { "source" => "command_service" }
    }
    assert_raises(Hive::TaskJournal::InvalidRecord) do
      validator.send(:validate_activity!, invalid_operation)
    end
  end
end
