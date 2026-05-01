require "test_helper"

# Pin the closed-enum behaviour of Hive::Schemas::*Kind modules. The tests
# guard against drift in two ways:
#   1. The expected value count is locked — adding a new kind must update
#      this count deliberately, which surfaces in code review.
#   2. ALL is self-derived from the module's constants, so renaming a
#      constant without updating ALL is impossible.
#
# Producers (Hive::Commands::Run / Hive::Commands::Status) and the schema
# files (schemas/hive-run.v1.json / schemas/hive-status.v1.json) both
# reference these constants — a drift between any of those three surfaces
# fails this test or the schema-drift test in schema_files_test.rb.
class SchemasTest < Minitest::Test
  def test_run_error_kind_all_contains_twelve_values
    assert_equal 12, Hive::Schemas::RunErrorKind::ALL.length,
                 "RunErrorKind::ALL count is locked; adding a kind requires bumping this assertion deliberately"
  end

  def test_run_error_kind_all_values_match_known_kinds
    expected = %w[
      concurrent_run task_in_error wrong_stage stage config agent git
      worktree ambiguous_slug invalid_task_path internal error
    ].sort
    assert_equal expected, Hive::Schemas::RunErrorKind::ALL.sort
  end

  def test_run_error_kind_values_are_frozen_strings
    Hive::Schemas::RunErrorKind::ALL.each do |value|
      assert_kind_of String, value
      assert_predicate value, :frozen?, "RunErrorKind value #{value.inspect} must be frozen"
    end
  end

  def test_run_error_kind_all_is_self_derived_from_constants
    # Every constant in the module other than ALL itself must appear in ALL.
    declared = Hive::Schemas::RunErrorKind.constants.reject { |c| c == :ALL }
    declared_values = declared.map { |c| Hive::Schemas::RunErrorKind.const_get(c) }
    assert_equal declared_values.sort, Hive::Schemas::RunErrorKind::ALL.sort,
                 "RunErrorKind::ALL must be self-derived from the module's constants"
  end

  def test_status_error_kind_all_contains_three_values
    assert_equal 3, Hive::Schemas::StatusErrorKind::ALL.length,
                 "StatusErrorKind::ALL count is locked; adding a kind requires bumping this assertion deliberately"
  end

  def test_status_error_kind_all_values_match_known_kinds
    expected = %w[config internal error].sort
    assert_equal expected, Hive::Schemas::StatusErrorKind::ALL.sort
  end

  def test_status_error_kind_values_are_frozen_strings
    Hive::Schemas::StatusErrorKind::ALL.each do |value|
      assert_kind_of String, value
      assert_predicate value, :frozen?, "StatusErrorKind value #{value.inspect} must be frozen"
    end
  end

  def test_status_error_kind_all_is_self_derived_from_constants
    declared = Hive::Schemas::StatusErrorKind.constants.reject { |c| c == :ALL }
    declared_values = declared.map { |c| Hive::Schemas::StatusErrorKind.const_get(c) }
    assert_equal declared_values.sort, Hive::Schemas::StatusErrorKind::ALL.sort,
                 "StatusErrorKind::ALL must be self-derived from the module's constants"
  end
end
