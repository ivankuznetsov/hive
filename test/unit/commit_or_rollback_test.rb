require "test_helper"
require "hive/commit_or_rollback"

class CommitOrRollbackTest < Minitest::Test
  # On undo success with a TYPED original error, the helper re-raises
  # the original so its exit code (e.g. GitError → 70) is preserved.
  def test_typed_original_error_is_re_raised_after_successful_undo
    original = Hive::GitError.new("commit failed")
    undo_calls = 0

    err = assert_raises(Hive::GitError) do
      Hive::CommitOrRollback.attempt!(
        original,
        on_undo: -> { undo_calls += 1 },
        rolled_back_message: ->(_) { "should not be used; typed re-raise" },
        rollback_failed_message: ->(_, _) { "should not be used; rollback succeeded" }
      )
    end

    assert_equal 1, undo_calls, "undo must run exactly once"
    assert_same original, err, "typed Hive::Error must be re-raised by identity"
  end

  # On undo success with a NON-TYPED original (e.g. SystemCallError),
  # the helper wraps in a generic Hive::Error with the rolled-back
  # message so callers always see a Hive::Error.
  def test_non_typed_original_error_is_wrapped_after_successful_undo
    original = Errno::ENOSPC.new("disk full")

    err = assert_raises(Hive::Error) do
      Hive::CommitOrRollback.attempt!(
        original,
        on_undo: -> { },
        rolled_back_message: ->(e) { "wrapped: #{e.class}: #{e.message}" },
        rollback_failed_message: ->(_, _) { "should not be used; rollback succeeded" }
      )
    end

    refute_kind_of Hive::RollbackFailed, err, "rollback succeeded; not RollbackFailed"
    assert_kind_of Hive::Error, err
    assert_includes err.message, "wrapped:"
    assert_includes err.message, "Errno::ENOSPC"
  end

  # On undo FAILURE, the helper raises Hive::RollbackFailed with the
  # combined message from both errors. Distinct exception class so the
  # JSON envelope can surface error_kind: "rollback_failed".
  def test_undo_failure_raises_rollback_failed
    original = Hive::GitError.new("commit failed")

    err = assert_raises(Hive::RollbackFailed) do
      Hive::CommitOrRollback.attempt!(
        original,
        on_undo: -> { raise Errno::EACCES, "denied" },
        rolled_back_message: ->(_) { "should not be used; rollback failed" },
        rollback_failed_message: ->(orig, rb) { "BOTH: #{orig.class}/#{rb.class}" }
      )
    end

    assert_equal Hive::ExitCodes::GENERIC, err.exit_code
    assert_includes err.message, "GitError"
    assert_includes err.message, "Errno::EACCES"
  end
end
