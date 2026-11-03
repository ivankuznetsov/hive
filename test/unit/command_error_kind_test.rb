require "test_helper"
require "hive/command_error_kind"
require "hive/commands/new"
require "hive/task_capabilities/admission"

class CommandErrorKindTest < Minitest::Test
  def test_shared_command_kinds_include_typed_capability_blockers
    Hive::TaskCapabilities::Admission::REASONS.each do |reason|
      error = Hive::TaskCapabilities::Admission::Error.new("blocked", reason: reason)
      assert_includes Hive::CommandErrorKind::ALL, reason
      assert_equal reason, Hive::CommandErrorKind.typed(error)
      assert_equal reason, Hive::Commands::New.new("demo", "text").envelope_error_kind(error)
    end
    assert_equal "command_conflict", Hive::CommandErrorKind.typed(Hive::CommandConflict.new)
    assert_equal "command_capacity_exhausted", Hive::CommandErrorKind.typed(Hive::CommandCapacityError.new("capacity", reason: "command_capacity_exhausted", scope: "host"))
    assert_equal "command_intake_disabled", Hive::CommandErrorKind.typed(Hive::CommandIntakeDisabled.new("disabled"))
    assert_nil Hive::CommandErrorKind.typed(RuntimeError.new("other"))
  end
end
