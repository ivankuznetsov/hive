module Hive
  # Helper that consolidates the dual-rescue rollback pattern shared by
  # `Hive::Commands::Approve#attempt_rollback!` and
  # `Hive::Commands::FindingToggle#rollback_review_change!`.
  #
  # Both call sites do the same thing: after a commit failure, attempt an
  # undo step. If the undo succeeds, re-raise the original typed error
  # (preserving its exit code) or wrap a non-typed error in a generic
  # `Hive::Error` with a "rolled back" message. If the undo ITSELF fails,
  # raise `Hive::RollbackFailed` carrying both the original cause and the
  # rollback failure so the operator has the full picture.
  #
  # Callers supply the undo block plus two message builders:
  #
  #   Hive::CommitOrRollback.attempt!(
  #     original_error,
  #     on_undo: -> { File.binwrite(path, original); ops.run_git!(...) },
  #     rolled_back_message: ->(e) { "X aborted; rolled back. underlying: #{e.class}: #{e.message}" },
  #     rollback_failed_message: ->(orig, rb) { "X aborted AND rollback failed. ..." }
  #   )
  #
  # Pre-conditions for the rollback (e.g., approve's "source path now
  # exists, can't roll back") stay in the caller — the helper only
  # handles the rescue + re-raise contract.
  module CommitOrRollback
    module_function

    def attempt!(original_error, on_undo:, rolled_back_message:, rollback_failed_message:)
      begin
        on_undo.call
      rescue StandardError => rollback_error
        raise Hive::RollbackFailed, rollback_failed_message.call(original_error, rollback_error)
      end

      # Rollback succeeded. Preserve the typed exit code when possible
      # (e.g. GitError → 70) instead of collapsing every rollback to 1.
      raise original_error if original_error.is_a?(Hive::Error)

      raise Hive::Error, rolled_back_message.call(original_error)
    end
  end
end
